-- Run in the ODR Supabase SQL Editor AFTER odr-enhancements.sql.
-- Existing targets, subscribers and point adjustments are preserved.

alter table public.sales_transactions
  add column if not exists source_tabs text;

-- For existing rows, the previous importer used ENTERBY. The next CSV upload
-- will replace source_tabs with the authoritative INFO_USERNAME field.
update public.sales_transactions
set source_tabs=tabs
where source_tabs is null;

alter table public.sales_transactions
  alter column source_tabs set not null;

create table if not exists public.sales_assignment_overrides (
  month date not null,
  subno text not null,
  tabs text not null references public.agent_directory(tabs),
  updated_by uuid not null default auth.uid(),
  updated_at timestamptz not null default now(),
  primary key(month,subno)
);

create index if not exists sales_transactions_month_tabs_idx
  on public.sales_transactions(month,tabs);

alter table public.sales_assignment_overrides enable row level security;
-- Only the administrator may see or edit the reassignment ledger. Agents see
-- only the effective assigned TABS on sales_transactions via the existing RLS.
create policy "Only admins manage sale assignments"
  on public.sales_assignment_overrides for all to authenticated
  using ((select auth.jwt()->'app_metadata'->>'role')='admin')
  with check ((select auth.jwt()->'app_metadata'->>'role')='admin');

grant select,insert,update,delete on public.sales_assignment_overrides to authenticated;

-- Atomic admin-only change. Passing null restores the report INFO_USERNAME.
create or replace function public.reassign_odr_sale(
  p_month date,p_subno text,p_tabs text default null
) returns text language plpgsql security invoker set search_path=public as $$
declare v_source text; v_next text;
begin
  if (select auth.jwt()->'app_metadata'->>'role') is distinct from 'admin' then
    raise exception 'Administrator access required';
  end if;
  select source_tabs into v_source from public.sales_transactions
    where month=p_month and subno=p_subno for update;
  if not found then raise exception 'Subscriber not found in selected month'; end if;
  v_next:=coalesce(nullif(upper(trim(p_tabs)),''),v_source);
  if not exists(select 1 from public.agent_directory where tabs=v_next and not is_team_leader) then
    raise exception 'Unknown or ineligible agent TABS: %',v_next;
  end if;
  if v_next=v_source then
    delete from public.sales_assignment_overrides where month=p_month and subno=p_subno;
  else
    insert into public.sales_assignment_overrides(month,subno,tabs,updated_by,updated_at)
      values(p_month,p_subno,v_next,auth.uid(),now())
      on conflict(month,subno) do update set
        tabs=excluded.tabs,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
  end if;
  update public.sales_transactions set tabs=v_next where month=p_month and subno=p_subno;
  return v_next;
end $$;

revoke all on function public.reassign_odr_sale(date,text,text) from public,anon;
grant execute on function public.reassign_odr_sale(date,text,text) to authenticated;

-- Monthly imports apply retained manual assignments when present, but always
-- keep the new source username for auditing and resetting the assignment.
create or replace function public.replace_odr_sales(p_month date,p_rows jsonb)
returns integer language plpgsql security invoker set search_path=public as $$
declare n integer;
begin
  if (select auth.jwt()->'app_metadata'->>'role') is distinct from 'admin' then
    raise exception 'Administrator access required';
  end if;
  if p_month<>date_trunc('month',p_month)::date or jsonb_typeof(p_rows)<>'array' then
    raise exception 'Invalid report month or payload';
  end if;
  if jsonb_array_length(p_rows)=0 or jsonb_array_length(p_rows)>200000 then
    raise exception 'Invalid report row count';
  end if;
  delete from public.sales_transactions where month=p_month;
  insert into public.sales_transactions
    (month,subno,tabs,source_tabs,package,segment,info_channel,transaction_date,base_points)
  select p_month,x.subno,coalesce(a.tabs,x.tabs),x.tabs,x.package,x.segment,
    coalesce(nullif(x.info_channel,''),'Unspecified'),x.transaction_date,coalesce(r.points,0)
  from jsonb_to_recordset(p_rows) as x(
    subno text,tabs text,package text,segment text,info_channel text,transaction_date date
  )
  left join public.sales_assignment_overrides a on a.month=p_month and a.subno=x.subno
  left join public.campaign_rules r on r.package=x.package and r.active=true;
  get diagnostics n=row_count;
  insert into public.report_snapshots(month,last_transaction_date,imported_rows,updated_at)
  select p_month,max(transaction_date),n,now() from public.sales_transactions where month=p_month
  on conflict(month) do update set
    last_transaction_date=excluded.last_transaction_date,
    imported_rows=excluded.imported_rows,
    updated_at=excluded.updated_at;
  return n;
end $$;
