begin;

create table public.apex_recurring_tasks (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id),
  project_id uuid,
  title text not null check (length(btrim(title)) between 1 and 200),
  anchor_deadline timestamptz not null,
  time_zone text not null,
  repeat_unit text not null check (repeat_unit in ('days', 'months')),
  repeat_every integer not null check (repeat_every between 1 and 365),
  last_occurrence integer not null default 0,
  last_deadline timestamptz not null,
  stopped_at timestamptz,
  unique(owner_id, id),
  foreign key (owner_id, project_id) references public.apex_projects(owner_id, id)
);

alter table public.apex_tasks add column recurrence_id uuid, add column occurrence_number integer;
alter table public.apex_tasks add constraint apex_task_occurrence_pair
  check ((recurrence_id is null and occurrence_number is null)
    or (recurrence_id is not null and occurrence_number is not null and occurrence_number >= 0));
alter table public.apex_tasks add constraint apex_task_recurrence_owner
  foreign key(owner_id, recurrence_id) references public.apex_recurring_tasks(owner_id, id);
alter table public.apex_tasks add unique(recurrence_id, occurrence_number);

alter table public.apex_recurring_tasks enable row level security;
revoke all on public.apex_recurring_tasks from public, anon, authenticated;
grant select on public.apex_recurring_tasks to authenticated;
create policy apex_recurrence_owner on public.apex_recurring_tasks for select to authenticated using (owner_id = auth.uid());
create index apex_recurring_due on public.apex_recurring_tasks(last_deadline) where stopped_at is null;

create function public.apex_add_recurring_task(task_title text, task_project uuid,
  first_deadline timestamptz, local_zone text, unit text, cadence integer)
returns void language plpgsql security definer set search_path = '' as $$
declare
  owner uuid := auth.uid();
  series_id uuid;
begin
  if owner is null then raise exception 'Sign in to create a task.'; end if;
  if first_deadline is null or first_deadline <= clock_timestamp() then
    raise exception 'Choose a future deadline for the first repeat.';
  end if;
  if not exists (select 1 from pg_timezone_names where name = local_zone) then
    raise exception 'The time zone is invalid.';
  end if;
  insert into public.apex_recurring_tasks(owner_id, project_id, title, anchor_deadline,
    time_zone, repeat_unit, repeat_every, last_deadline)
  values(owner, task_project, btrim(task_title), first_deadline, local_zone, unit, cadence, first_deadline)
  returning id into series_id;
  insert into public.apex_tasks(owner_id, project_id, title, deadline, recurrence_id, occurrence_number)
  values(owner, task_project, btrim(task_title), first_deadline, series_id, 0);
end;
$$;

create function public.apex_stop_recurrence(target uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.apex_recurring_tasks set stopped_at = clock_timestamp()
  where id = target and owner_id = auth.uid() and stopped_at is null;
end;
$$;

create function public.apex_generate_occurrences() returns void
language plpgsql security definer set search_path = '' as $$
declare
  series public.apex_recurring_tasks;
  next_number integer;
  next_deadline timestamptz;
  next_offset interval;
  evaluated_at timestamptz := statement_timestamp();
begin
  for series in select * from public.apex_recurring_tasks
    where stopped_at is null and last_deadline <= evaluated_at
    order by last_deadline, id limit 100 for update skip locked
  loop
    next_number := series.last_occurrence + 1;
    next_offset := case series.repeat_unit
      when 'months' then make_interval(months => series.repeat_every * next_number)
      else make_interval(days => series.repeat_every * next_number) end;
    next_deadline := timezone(series.time_zone,
      timezone(series.time_zone, series.anchor_deadline) + next_offset);
    insert into public.apex_tasks(owner_id, project_id, title, deadline, recurrence_id, occurrence_number)
    values(series.owner_id, series.project_id, series.title, next_deadline, series.id, next_number)
    on conflict (recurrence_id, occurrence_number) do nothing;
    update public.apex_recurring_tasks set last_occurrence = next_number, last_deadline = next_deadline
    where id = series.id;
  end loop;
end;
$$;

revoke all on function public.apex_add_recurring_task(text, uuid, timestamptz, text, text, integer),
  public.apex_stop_recurrence(uuid), public.apex_generate_occurrences() from public, anon, authenticated;
grant execute on function public.apex_add_recurring_task(text, uuid, timestamptz, text, text, integer),
  public.apex_stop_recurrence(uuid) to authenticated;
select cron.schedule('apex-generate-occurrences', '*/5 * * * *', 'select public.apex_generate_occurrences()');

commit;
