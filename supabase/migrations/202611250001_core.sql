begin;

create table public.apex_spaces (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id),
  title text not null check (length(btrim(title)) between 1 and 100),
  unique (owner_id, id)
);

create table public.apex_projects (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id),
  space_id uuid not null,
  title text not null check (length(btrim(title)) between 1 and 100),
  status text not null default 'active' check (status in ('active', 'paused', 'inactive', 'completed', 'archived')),
  foreign key (owner_id, space_id) references public.apex_spaces(owner_id, id),
  unique (owner_id, id)
);

create table public.apex_tasks (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id),
  project_id uuid,
  title text not null check (length(btrim(title)) between 1 and 200),
  deadline timestamptz,
  completion numeric(7,4) not null default 0 check (completion between 0 and 100),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (owner_id, project_id) references public.apex_projects(owner_id, id),
  unique (owner_id, id)
);

create table public.apex_momentum (
  id bigint generated always as identity primary key,
  owner_id uuid not null references auth.users(id),
  project_id uuid,
  task_id uuid,
  occurred_at timestamptz not null default now(),
  kind text not null check (kind in ('base', 'delay', 'correction', 'manual')),
  component text not null check (component in ('base', 'delay', 'manual')),
  value numeric not null check (value <> 0 and value <> 'NaN'::numeric),
  reason text not null check (length(btrim(reason)) between 1 and 240),
  snapshot jsonb,
  foreign key (owner_id, project_id) references public.apex_projects(owner_id, id),
  foreign key (owner_id, task_id) references public.apex_tasks(owner_id, id)
);

create index apex_tasks_owner_deadline on public.apex_tasks(owner_id, deadline);
create index apex_momentum_owner_time on public.apex_momentum(owner_id, occurred_at, id);
create index apex_momentum_task on public.apex_momentum(task_id);

alter table public.apex_spaces enable row level security;
alter table public.apex_projects enable row level security;
alter table public.apex_tasks enable row level security;
alter table public.apex_momentum enable row level security;

revoke all on public.apex_spaces, public.apex_projects, public.apex_tasks, public.apex_momentum from anon, authenticated;
grant select on public.apex_spaces, public.apex_projects, public.apex_tasks, public.apex_momentum to authenticated;
grant insert (title) on public.apex_spaces to authenticated;
grant insert (title, space_id) on public.apex_projects to authenticated;
grant insert (title, project_id, deadline), update (completion) on public.apex_tasks to authenticated;

create policy apex_spaces_owner on public.apex_spaces to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy apex_projects_owner on public.apex_projects to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy apex_tasks_owner on public.apex_tasks to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy apex_momentum_owner on public.apex_momentum for select to authenticated using (owner_id = auth.uid());

create function public.apex_reject_ledger_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'Momentum history is append-only';
end;
$$;

create trigger apex_momentum_append_only before update or delete on public.apex_momentum
for each row execute function public.apex_reject_ledger_mutation();

create function public.apex_score_task(task public.apex_tasks, evaluated_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare
  expected_base numeric;
  expected_delay numeric;
  prior_base numeric;
  prior_delay numeric;
  past_due boolean := coalesce(task.deadline <= evaluated_at, false);
begin
  if task.completion < 100 and not past_due then return; end if;
  expected_base := case when task.completion = 100 then 1 else (task.completion - 100) / 100 end;
  expected_delay := case when past_due then
    round(-0.05 * greatest(0, extract(epoch from (coalesce(task.completed_at, evaluated_at) - task.deadline))) / 3600, 6)
    else 0 end;
  select coalesce(sum(value) filter (where component = 'base'), 0),
         coalesce(sum(value) filter (where component = 'delay'), 0)
    into prior_base, prior_delay from public.apex_momentum where task_id = task.id;
  if expected_base <> prior_base then
    insert into public.apex_momentum(owner_id, project_id, task_id, occurred_at, kind, component, value, reason, snapshot)
    values (task.owner_id, task.project_id, task.id, evaluated_at,
      case when prior_base = 0 then 'base' else 'correction' end, 'base', expected_base - prior_base,
      case when task.completion = 100 then task.title || ' completed' else task.title || ' at ' || trim_scale(task.completion) || '%' end,
      to_jsonb(task));
  end if;
  if expected_delay <> prior_delay then
    insert into public.apex_momentum(owner_id, project_id, task_id, occurred_at, kind, component, value, reason, snapshot)
    values (task.owner_id, task.project_id, task.id, evaluated_at,
      case when expected_delay < prior_delay then 'delay' else 'correction' end, 'delay', expected_delay - prior_delay,
      task.title || ' overdue', to_jsonb(task));
  end if;
end;
$$;

create function public.apex_capture_completion() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.completion = new.completion then return new; end if;
  if old.completion < 100 and old.deadline <= statement_timestamp() then
    perform public.apex_score_task(old, statement_timestamp());
  end if;
  new.completed_at := case when new.completion = 100 then statement_timestamp() else null end;
  return new;
end;
$$;

create function public.apex_score_completion() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.completion is distinct from new.completion then
    if new.completion < 100 and (new.deadline is null or new.deadline > statement_timestamp()) then
      insert into public.apex_momentum(owner_id, project_id, task_id, kind, component, value, reason, snapshot)
      select new.owner_id, new.project_id, new.id, 'correction', 'base', -sum(value), new.title || ' reopened', to_jsonb(new)
      from public.apex_momentum where task_id = new.id and component = 'base'
      having sum(value) <> 0;
    else
      perform public.apex_score_task(new, statement_timestamp());
    end if;
  end if;
  return new;
end;
$$;

create trigger apex_capture_completion before update of completion on public.apex_tasks
for each row execute function public.apex_capture_completion();
create trigger apex_score_completion after update of completion on public.apex_tasks
for each row execute function public.apex_score_completion();

create function public.apex_evaluate_deadlines() returns void
language plpgsql security definer set search_path = '' as $$
declare
  task public.apex_tasks;
  evaluated_at timestamptz := statement_timestamp();
begin
  for task in
    select t.* from public.apex_tasks t
    where t.deadline <= evaluated_at and t.completion < 100
    order by t.id for update of t skip locked
  loop
    perform public.apex_score_task(task, evaluated_at);
  end loop;
end;
$$;

revoke all on function public.apex_score_task(public.apex_tasks, timestamptz),
  public.apex_capture_completion(), public.apex_score_completion(),
  public.apex_evaluate_deadlines(), public.apex_reject_ledger_mutation()
  from public, anon, authenticated;

create extension if not exists pg_cron;
select cron.schedule('apex-evaluate-deadlines', '*/5 * * * *', 'select public.apex_evaluate_deadlines()');

commit;
