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
  cancelled_at timestamptz,
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

create table public.apex_project_pauses (
  id bigint generated always as identity primary key,
  owner_id uuid not null,
  project_id uuid not null,
  began_at timestamptz not null,
  ended_at timestamptz,
  foreign key (owner_id, project_id) references public.apex_projects(owner_id, id)
);
create unique index apex_project_open_pause on public.apex_project_pauses(project_id) where ended_at is null;
create index apex_project_pause_history on public.apex_project_pauses(project_id, began_at);

create table public.apex_task_dependencies (
  owner_id uuid not null default auth.uid(),
  task_id uuid not null,
  prerequisite_id uuid not null check (prerequisite_id <> task_id),
  primary key (task_id, prerequisite_id),
  foreign key (owner_id, task_id) references public.apex_tasks(owner_id, id),
  foreign key (owner_id, prerequisite_id) references public.apex_tasks(owner_id, id)
);

create index apex_tasks_owner_deadline on public.apex_tasks(owner_id, deadline);
create index apex_momentum_owner_time on public.apex_momentum(owner_id, occurred_at, id);
create index apex_momentum_task on public.apex_momentum(task_id);

alter table public.apex_spaces enable row level security;
alter table public.apex_projects enable row level security;
alter table public.apex_tasks enable row level security;
alter table public.apex_momentum enable row level security;
alter table public.apex_project_pauses enable row level security;
alter table public.apex_task_dependencies enable row level security;
revoke all on public.apex_project_pauses, public.apex_task_dependencies from anon, authenticated;
grant select on public.apex_project_pauses, public.apex_task_dependencies to authenticated;
grant insert (task_id, prerequisite_id), delete on public.apex_task_dependencies to authenticated;
create policy apex_pauses_owner on public.apex_project_pauses for select to authenticated using (owner_id = auth.uid());
create policy apex_dependencies_owner on public.apex_task_dependencies to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

revoke all on public.apex_spaces, public.apex_projects, public.apex_tasks, public.apex_momentum from anon, authenticated;
grant select on public.apex_spaces, public.apex_projects, public.apex_tasks, public.apex_momentum to authenticated;
grant insert (title) on public.apex_spaces to authenticated;
grant insert (title, space_id), update (status) on public.apex_projects to authenticated;
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
  scoring_end timestamptz := coalesce(task.completed_at, evaluated_at);
  elapsed_seconds numeric;
  paused_seconds numeric;
  past_due boolean := coalesce(task.deadline <= evaluated_at, false);
begin
  if task.cancelled_at is not null or (task.completion < 100 and not past_due) then return; end if;
  expected_base := case when task.completion = 100 then 1 else (task.completion - 100) / 100 end;
  expected_delay := 0;
  if past_due and scoring_end > task.deadline then
    elapsed_seconds := extract(epoch from (scoring_end - task.deadline));
    select coalesce(sum(extract(epoch from
      least(coalesce(ended_at, scoring_end), scoring_end) - greatest(began_at, task.deadline)
    )), 0) into paused_seconds from public.apex_project_pauses
    where project_id = task.project_id and began_at < scoring_end
      and coalesce(ended_at, scoring_end) > task.deadline;
    expected_delay := round(-0.05 * greatest(0, elapsed_seconds - paused_seconds) / 3600, 6);
  end if;
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
  if old.cancelled_at is not null then raise exception 'This task is cancelled.'; end if;
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
    where t.deadline <= evaluated_at and t.completion < 100 and t.cancelled_at is null
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

create function public.apex_record_project_pause() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'paused' and old.status <> 'paused' then
    insert into public.apex_project_pauses(owner_id, project_id, began_at)
    values (new.owner_id, new.id, clock_timestamp());
  elsif old.status = 'paused' and new.status <> 'paused' then
    update public.apex_project_pauses set ended_at = clock_timestamp()
    where project_id = new.id and ended_at is null;
  end if;
  return new;
end;
$$;

create trigger apex_record_project_pause after update of status on public.apex_projects
for each row execute function public.apex_record_project_pause();

create function public.apex_reject_dependency_cycle() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(new.owner_id::text, 0));
  if exists (
    with recursive ancestors(id) as (
      select new.prerequisite_id
      union
      select d.prerequisite_id from public.apex_task_dependencies d
      join ancestors a on d.task_id = a.id where d.owner_id = new.owner_id
    )
    select 1 from ancestors where id = new.task_id
  ) then
    raise exception 'That dependency would create a cycle.';
  end if;
  return new;
end;
$$;

create trigger apex_reject_dependency_cycle before insert on public.apex_task_dependencies
for each row execute function public.apex_reject_dependency_cycle();

create function public.apex_cancel_task(target uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  update public.apex_tasks set cancelled_at = clock_timestamp()
  where id = target and owner_id = auth.uid() and cancelled_at is null and completion < 100;
  return found;
end;
$$;

create function public.apex_manual_momentum(target uuid, amount numeric, explanation text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if amount is null or amount = 0 or abs(amount) > 1000000 then
    raise exception 'Enter a nonzero finite adjustment no larger than one million.';
  end if;
  if not exists (select 1 from public.apex_projects where id = target and owner_id = auth.uid()) then
    raise exception 'Project not found.';
  end if;
  insert into public.apex_momentum(owner_id, project_id, kind, component, value, reason)
  values (auth.uid(), target, 'manual', 'manual', amount, btrim(explanation));
end;
$$;

revoke all on function public.apex_record_project_pause(), public.apex_reject_dependency_cycle(),
  public.apex_cancel_task(uuid), public.apex_manual_momentum(uuid, numeric, text) from public, anon, authenticated;
grant execute on function public.apex_cancel_task(uuid), public.apex_manual_momentum(uuid, numeric, text) to authenticated;

create extension if not exists pg_cron;
select cron.schedule('apex-evaluate-deadlines', '*/5 * * * *', 'select public.apex_evaluate_deadlines()');

commit;
