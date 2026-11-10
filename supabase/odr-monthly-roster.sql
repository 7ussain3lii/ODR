-- Run in the dedicated ODR Supabase SQL Editor after odr-sale-assignment.sql.
-- Monthly targets determine the active roster; historic targets and sales stay intact.

create index if not exists monthly_targets_month_tabs_idx
  on public.monthly_targets(month,tabs);

-- Replacing the current month's target upload removes stale monthly memberships
-- without deleting the permanent directory or any previous month's records.
create or replace function public.replace_odr_targets(
  p_month date,p_agents jsonb,p_targets jsonb
) returns integer language plpgsql security invoker set search_path=public as $$
declare n integer;
begin
  if (select auth.jwt()->'app_metadata'->>'role') is distinct from 'admin' then
    raise exception 'Administrator access required';
  end if;
  if p_month<>date_trunc('month',p_month)::date
     or jsonb_typeof(p_agents)<>'array' or jsonb_typeof(p_targets)<>'array' then
    raise exception 'Invalid target payload';
  end if;
  if jsonb_array_length(p_agents)=0 or jsonb_array_length(p_agents)>10000
     or jsonb_array_length(p_targets)<>jsonb_array_length(p_agents)*3 then
    raise exception 'Invalid monthly agent and target rows';
  end if;

  insert into public.agent_directory(tabs,full_name,team_leader,is_team_leader,updated_at)
  select x.tabs,x.full_name,x.team_leader,x.is_team_leader,now()
  from jsonb_to_recordset(p_agents) as x(
    tabs text,full_name text,team_leader text,is_team_leader boolean
  )
  on conflict(tabs) do update set full_name=excluded.full_name,
    team_leader=excluded.team_leader,is_team_leader=excluded.is_team_leader,
    updated_at=excluded.updated_at;

  delete from public.monthly_targets where month=p_month;
  insert into public.monthly_targets(month,tabs,segment,target)
  select p_month,x.tabs,x.segment,x.target
  from jsonb_to_recordset(p_targets) as x(
    month date,tabs text,segment text,target numeric
  )
  where x.month=p_month;
  get diagnostics n=row_count;
  if n<>jsonb_array_length(p_targets) then
    raise exception 'Invalid target month or duplicate rows';
  end if;
  return n/3;
end $$;

revoke all on function public.replace_odr_targets(date,jsonb,jsonb) from public,anon;
grant execute on function public.replace_odr_targets(date,jsonb,jsonb) to authenticated;

-- Enforce the active monthly roster on the server, not only in the UI.
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
  if v_next<>v_source and not exists(
    select 1 from public.agent_directory a
    join public.monthly_targets t on t.tabs=a.tabs
    where t.month=p_month and a.tabs=v_next and not a.is_team_leader
  ) then raise exception 'The selected TABS is not active in this month'; end if;
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

-- An INFO_USERNAME does not need to be in this month's roster to be retained.
-- Unknown report usernames are directory placeholders without monthly targets.
-- The UI holds those sales for review and excludes their points from totals.
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
  -- Placeholders allow unmatched INFO_USERNAME entries to be reviewed without
  -- creating false monthly targets for those agents.
  insert into public.agent_directory(tabs,full_name,is_team_leader)
  select distinct upper(trim(x.tabs)),upper(trim(x.tabs)),false
  from jsonb_to_recordset(p_rows) as x(tabs text)
  where x.tabs is not null and trim(x.tabs)<>''
  on conflict(tabs) do nothing;

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
