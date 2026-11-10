-- Run in a dedicated ODR Supabase project, not the existing Target Update project.
-- The admin is the only account with app_metadata.role = 'admin'.
create table if not exists public.agent_directory (
  tabs text primary key check (tabs ~ '^[A-Z0-9]{4,20}$'),
  full_name text not null,
  team_leader text,
  updated_at timestamptz not null default now()
);
create table if not exists public.monthly_targets (
  month date not null,
  tabs text not null references public.agent_directory(tabs),
  segment text not null check (segment in ('postpaid','mbb','bb')),
  target numeric(12,2) not null check (target>=0),
  primary key(month,tabs,segment)
);
create table if not exists public.monthly_actuals (
  month date not null,
  tabs text not null references public.agent_directory(tabs),
  segment text not null check (segment in ('postpaid','mbb','bb')),
  actual integer not null check (actual>=0),
  last_transaction_date date not null,
  primary key(month,tabs,segment)
);
create table if not exists public.import_audit (
  id bigint generated always as identity primary key,
  kind text not null check(kind in ('sales','targets')),
  month date not null,
  rows_processed integer not null,
  imported_by uuid not null default auth.uid(),
  imported_at timestamptz not null default now()
);

alter table public.agent_directory enable row level security;
alter table public.monthly_targets enable row level security;
alter table public.monthly_actuals enable row level security;
alter table public.import_audit enable row level security;

-- Authorization relies only on server-controlled app_metadata, never user_metadata.
create policy "directory read by owner or admin" on public.agent_directory for select to authenticated
  using (tabs=(auth.jwt()->'app_metadata'->>'tabs') or auth.jwt()->'app_metadata'->>'role'='admin');
create policy "directory write by admin" on public.agent_directory for all to authenticated
  using (auth.jwt()->'app_metadata'->>'role'='admin') with check (auth.jwt()->'app_metadata'->>'role'='admin');
create policy "targets read by owner or admin" on public.monthly_targets for select to authenticated
  using (tabs=(auth.jwt()->'app_metadata'->>'tabs') or auth.jwt()->'app_metadata'->>'role'='admin');
create policy "targets write by admin" on public.monthly_targets for all to authenticated
  using (auth.jwt()->'app_metadata'->>'role'='admin') with check (auth.jwt()->'app_metadata'->>'role'='admin');
create policy "actuals read by owner or admin" on public.monthly_actuals for select to authenticated
  using (tabs=(auth.jwt()->'app_metadata'->>'tabs') or auth.jwt()->'app_metadata'->>'role'='admin');
create policy "actuals write by admin" on public.monthly_actuals for all to authenticated
  using (auth.jwt()->'app_metadata'->>'role'='admin') with check (auth.jwt()->'app_metadata'->>'role'='admin');
create policy "audit read by admin" on public.import_audit for select to authenticated
  using (auth.jwt()->'app_metadata'->>'role'='admin');
create policy "audit insert by admin" on public.import_audit for insert to authenticated
  with check (auth.jwt()->'app_metadata'->>'role'='admin');

grant select,insert,update,delete on public.agent_directory,public.monthly_targets,public.monthly_actuals to authenticated;
grant select,insert on public.import_audit to authenticated;
grant usage,select on sequence public.import_audit_id_seq to authenticated;
