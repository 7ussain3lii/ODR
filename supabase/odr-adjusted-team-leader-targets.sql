-- Run in the dedicated ODR Supabase project after odr-monthly-roster.sql.
-- This script does not modify previously imported targets or sales.

create table if not exists public.monthly_team_leader_targets (
  month date not null,
  leader text not null,
  segment text not null check (segment in ('postpaid','mbb','bb')),
  target numeric(12,3) not null check (target >= 0),
  primary key(month,leader,segment)
);

alter table public.monthly_team_leader_targets enable row level security;

create policy "Admins read team leader targets"
  on public.monthly_team_leader_targets for select to authenticated
  using ((select auth.jwt()->'app_metadata'->>'role')='admin');
create policy "Admins manage team leader targets"
  on public.monthly_team_leader_targets for all to authenticated
  using ((select auth.jwt()->'app_metadata'->>'role')='admin')
  with check ((select auth.jwt()->'app_metadata'->>'role')='admin');

grant select,insert,update,delete on public.monthly_team_leader_targets to authenticated;

-- Transactionally replace this month's agent targets and explicit adjusted TL
-- targets. TL targets are never calculated by summing individual agent targets.
create or replace function public.replace_odr_targets(
  p_month date,p_agents jsonb,p_targets jsonb,p_leaders jsonb
) returns integer language plpgsql security invoker set search_path=public as $$
declare n integer; n_leaders integer;
begin
  if (select auth.jwt()->'app_metadata'->>'role') is distinct from 'admin' then
    raise exception 'Administrator access required';
  end if;
  if p_month<>date_trunc('month',p_month)::date
     or jsonb_typeof(p_agents)<>'array' or jsonb_typeof(p_targets)<>'array'
     or jsonb_typeof(p_leaders)<>'array' then
    raise exception 'Invalid target payload';
  end if;
  if jsonb_array_length(p_agents)=0 or jsonb_array_length(p_agents)>10000
     or jsonb_array_length(p_targets)<>jsonb_array_length(p_agents)*3
     or jsonb_array_length(p_leaders)>1000
     or mod(jsonb_array_length(p_leaders),3)<>0 then
    raise exception 'Invalid monthly agent or leader target count';
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
  ) where x.month=p_month;
  get diagnostics n=row_count;
  if n<>jsonb_array_length(p_targets) then
    raise exception 'Invalid agent target month or duplicate rows';
  end if;

  delete from public.monthly_team_leader_targets where month=p_month;
  insert into public.monthly_team_leader_targets(month,leader,segment,target)
  select p_month,trim(x.leader),x.segment,x.target
  from jsonb_to_recordset(p_leaders) as x(
    month date,leader text,segment text,target numeric
  ) where x.month=p_month and trim(x.leader)<>'';
  get diagnostics n_leaders=row_count;
  if n_leaders<>jsonb_array_length(p_leaders) then
    raise exception 'Invalid Team Leader target month or duplicate rows';
  end if;
  return n/3;
end $$;

revoke all on function public.replace_odr_targets(date,jsonb,jsonb,jsonb) from public,anon;
grant execute on function public.replace_odr_targets(date,jsonb,jsonb,jsonb) to authenticated;
