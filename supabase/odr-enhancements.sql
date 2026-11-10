-- Run once in the ODR project's SQL Editor after the initial schema.
-- Existing monthly targets, actuals, and user accounts are preserved.

alter table public.agent_directory
  add column if not exists is_team_leader boolean not null default false;

create table if not exists public.campaign_rules (
  package text primary key,
  points numeric(10,2) not null check (points >= 0),
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.sales_transactions (
  month date not null,
  subno text not null,
  tabs text not null references public.agent_directory(tabs),
  package text not null,
  segment text not null check (segment in ('postpaid','mbb','bb')),
  info_channel text not null default 'Unspecified',
  transaction_date date not null,
  base_points numeric(10,2) not null default 0 check (base_points >= 0),
  primary key(month,subno)
);

create table if not exists public.sales_point_overrides (
  month date not null,
  subno text not null,
  points numeric(10,2) not null check (points >= 0),
  updated_by uuid not null default auth.uid(),
  updated_at timestamptz not null default now(),
  primary key(month,subno)
);

create table if not exists public.report_snapshots (
  month date primary key,
  last_transaction_date date not null,
  imported_rows integer not null,
  updated_at timestamptz not null default now()
);

alter table public.campaign_rules enable row level security;
alter table public.sales_transactions enable row level security;
alter table public.sales_point_overrides enable row level security;
alter table public.report_snapshots enable row level security;

create policy "Authenticated users read reporting dates"
  on public.report_snapshots for select to authenticated using (true);
create policy "Only admins set reporting dates"
  on public.report_snapshots for all to authenticated
  using (auth.jwt()->'app_metadata'->>'role'='admin')
  with check (auth.jwt()->'app_metadata'->>'role'='admin');

create policy "Anyone signed in can read campaign rules"
  on public.campaign_rules for select to authenticated using (true);
create policy "Only admins modify campaign rules"
  on public.campaign_rules for all to authenticated
  using (auth.jwt()->'app_metadata'->>'role'='admin')
  with check (auth.jwt()->'app_metadata'->>'role'='admin');

create policy "Admin or owner sees sales transactions"
  on public.sales_transactions for select to authenticated
  using (tabs=auth.jwt()->'app_metadata'->>'tabs' or auth.jwt()->'app_metadata'->>'role'='admin');
create policy "Only admins modify sales transactions"
  on public.sales_transactions for all to authenticated
  using (auth.jwt()->'app_metadata'->>'role'='admin')
  with check (auth.jwt()->'app_metadata'->>'role'='admin');

create policy "Admin or owner sees points overrides"
  on public.sales_point_overrides for select to authenticated
  using (auth.jwt()->'app_metadata'->>'role'='admin'
    or exists(select 1 from public.sales_transactions s
      where s.month=sales_point_overrides.month and s.subno=sales_point_overrides.subno
      and s.tabs=auth.jwt()->'app_metadata'->>'tabs'));
create policy "Only admins modify points overrides"
  on public.sales_point_overrides for all to authenticated
  using (auth.jwt()->'app_metadata'->>'role'='admin')
  with check (auth.jwt()->'app_metadata'->>'role'='admin');

grant select,insert,update,delete on public.campaign_rules,public.sales_transactions,public.sales_point_overrides to authenticated;
grant select,insert,update,delete on public.report_snapshots to authenticated;

-- Treat the latest supplied package mapping as the active rules. This does not
-- delete any existing rules and does not replace a future admin's point edits.
insert into public.campaign_rules(package,points) values
('5GHBB14',1),('5GHBB17',1),('5GHBB20GBS',1),
('FPLNMAIN1',1),('FPLNMAIN2',1),('FPLNMAIN4',1),('FPLNMAIN5',1),
('FTTHBASICU',1),('FTTHEXTRA',1),('FTTHGAMER',1),('FTTHULTIMT',1),
('MBBPKG10M',1),('MBBPKG12M',1),('MBBPKG15M',1),('MBBPKG20M',1),
('POSTPLAN0',1),('POSTPLAN1',1),('POSTPLAN2',1),('POSTPLAN3',1),
('POSTPLAN4',1.5),('POSTPLAN5',2),('TM5GHBB20S',1)
on conflict(package) do nothing;

-- An import is one atomic transaction. Per-subscriber overrides remain intact
-- for any subscription still present in the replacement report.
create or replace function public.replace_odr_sales(p_month date,p_rows jsonb)
returns integer language plpgsql security invoker set search_path=public as $$
declare n integer;
begin
  if auth.jwt()->'app_metadata'->>'role' is distinct from 'admin' then
    raise exception 'Administrator access required';
  end if;
  if p_month<>date_trunc('month',p_month)::date or jsonb_typeof(p_rows)<>'array' then
    raise exception 'Invalid report month or payload';
  end if;
  if jsonb_array_length(p_rows)=0 or jsonb_array_length(p_rows)>200000 then
    raise exception 'Invalid report row count';
  end if;
  delete from public.sales_transactions where month=p_month;
  insert into public.sales_transactions(month,subno,tabs,package,segment,info_channel,transaction_date,base_points)
  select p_month,x.subno,x.tabs,x.package,x.segment,coalesce(nullif(x.info_channel,''),'Unspecified'),x.transaction_date,coalesce(r.points,0)
  from jsonb_to_recordset(p_rows) as x(subno text,tabs text,package text,segment text,info_channel text,transaction_date date)
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
revoke all on function public.replace_odr_sales(date,jsonb) from public,anon;
grant execute on function public.replace_odr_sales(date,jsonb) to authenticated;
