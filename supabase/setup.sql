-- ============================================================
-- Sprayboard database setup
-- Supabase > SQL Editor > New query > paste all of this > Run
-- Safe to run more than once.
-- ============================================================

-- ---------- tables ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Climber',
  created_at timestamptz not null default now()
);

create table if not exists public.crews (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  join_code text not null unique,
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.crew_members (
  crew_id uuid not null references public.crews(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  primary key (crew_id, user_id)
);

create table if not exists public.walls (
  id text primary key,
  crew_id uuid not null references public.crews(id) on delete cascade,
  name text not null,
  angle int not null default 40,
  aspect real not null,
  holds jsonb not null default '[]',
  photo_path text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.problems (
  id text primary key,
  crew_id uuid not null references public.crews(id) on delete cascade,
  wall_id text not null references public.walls(id) on delete cascade,
  name text not null,
  grade int not null default 3,          -- -1 means project (graded on first send)
  feet text not null default 'Marked feet only',
  no_match boolean not null default false,
  notes text not null default '',
  holds jsonb not null default '{}',
  setter_id uuid references auth.users(id) on delete set null,
  setter_name text not null default '',
  fa jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.ticks (
  id text primary key,
  crew_id uuid not null references public.crews(id) on delete cascade,
  wall_id text not null references public.walls(id) on delete cascade,
  problem_id text not null references public.problems(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  day date not null default current_date,
  at timestamptz not null default now(),
  sent boolean not null default false,
  attempts int not null default 1 check (attempts between 1 and 999),
  grade int,
  stars int not null default 0 check (stars between 0 and 3),
  note text not null default '',
  fa boolean not null default false
);

create index if not exists walls_crew_idx on public.walls(crew_id);
create index if not exists problems_wall_idx on public.problems(wall_id);
create index if not exists ticks_problem_idx on public.ticks(problem_id);
create index if not exists ticks_user_idx on public.ticks(user_id);

-- ---------- helpers ----------
create or replace function public.is_crew_member(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from crew_members where crew_id = c and user_id = auth.uid());
$$;

create or replace function public.is_crew_owner(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from crews where id = c and owner_id = auth.uid());
$$;

-- every new account gets a profile with the name they signed up with
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles(id, display_name)
  values (new.id, coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''), 'Climber'))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- start a crew (you become its owner) and get a 6-letter join code
create or replace function public.create_crew(crew_name text) returns public.crews
language plpgsql security definer set search_path = public as $$
declare
  c crews;
  code text;
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  loop
    code := '';
    for i in 1..6 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from crews where join_code = code);
  end loop;
  insert into crews(name, join_code, owner_id)
  values (coalesce(nullif(trim(crew_name), ''), 'My crew'), code, auth.uid())
  returning * into c;
  insert into crew_members(crew_id, user_id, role) values (c.id, auth.uid(), 'owner');
  return c;
end $$;

-- join a crew with its code
create or replace function public.join_crew(code text) returns public.crews
language plpgsql security definer set search_path = public as $$
declare c crews;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into c from crews where join_code = upper(trim(code));
  if c.id is null then raise exception 'No crew with that code'; end if;
  insert into crew_members(crew_id, user_id) values (c.id, auth.uid())
  on conflict do nothing;
  return c;
end $$;

revoke all on function public.create_crew(text) from public, anon;
revoke all on function public.join_crew(text) from public, anon;
grant execute on function public.create_crew(text) to authenticated;
grant execute on function public.join_crew(text) to authenticated;

-- ---------- security rules (row level security) ----------
alter table public.profiles     enable row level security;
alter table public.crews        enable row level security;
alter table public.crew_members enable row level security;
alter table public.walls        enable row level security;
alter table public.problems     enable row level security;
alter table public.ticks        enable row level security;

-- profiles: signed-in people can see names; you can only edit your own
drop policy if exists "read names" on public.profiles;
create policy "read names" on public.profiles for select to authenticated using (true);
drop policy if exists "edit own profile" on public.profiles;
create policy "edit own profile" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists "create own profile" on public.profiles;
create policy "create own profile" on public.profiles for insert to authenticated
  with check (id = auth.uid());

-- crews: members see their crew; only the owner renames or deletes it
drop policy if exists "members see crew" on public.crews;
create policy "members see crew" on public.crews for select to authenticated
  using (public.is_crew_member(id));
drop policy if exists "owner edits crew" on public.crews;
create policy "owner edits crew" on public.crews for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "owner deletes crew" on public.crews;
create policy "owner deletes crew" on public.crews for delete to authenticated
  using (owner_id = auth.uid());

-- crew members: members see each other; you can leave, the owner can remove people
drop policy if exists "members see members" on public.crew_members;
create policy "members see members" on public.crew_members for select to authenticated
  using (public.is_crew_member(crew_id));
drop policy if exists "leave or remove" on public.crew_members;
create policy "leave or remove" on public.crew_members for delete to authenticated
  using (user_id = auth.uid() or public.is_crew_owner(crew_id));

-- walls: any crew member can view, add and edit holds; creator or crew owner can delete
drop policy if exists "crew reads walls" on public.walls;
create policy "crew reads walls" on public.walls for select to authenticated
  using (public.is_crew_member(crew_id));
drop policy if exists "crew adds walls" on public.walls;
create policy "crew adds walls" on public.walls for insert to authenticated
  with check (public.is_crew_member(crew_id));
drop policy if exists "crew edits walls" on public.walls;
create policy "crew edits walls" on public.walls for update to authenticated
  using (public.is_crew_member(crew_id)) with check (public.is_crew_member(crew_id));
drop policy if exists "creator or owner deletes wall" on public.walls;
create policy "creator or owner deletes wall" on public.walls for delete to authenticated
  using (public.is_crew_member(crew_id) and (created_by = auth.uid() or public.is_crew_owner(crew_id)));

-- problems: any crew member can view, set and edit; setter or crew owner can delete
drop policy if exists "crew reads problems" on public.problems;
create policy "crew reads problems" on public.problems for select to authenticated
  using (public.is_crew_member(crew_id));
drop policy if exists "crew sets problems" on public.problems;
create policy "crew sets problems" on public.problems for insert to authenticated
  with check (public.is_crew_member(crew_id));
drop policy if exists "crew edits problems" on public.problems;
create policy "crew edits problems" on public.problems for update to authenticated
  using (public.is_crew_member(crew_id)) with check (public.is_crew_member(crew_id));
drop policy if exists "setter or owner deletes problem" on public.problems;
create policy "setter or owner deletes problem" on public.problems for delete to authenticated
  using (public.is_crew_member(crew_id) and (setter_id = auth.uid() or public.is_crew_owner(crew_id)));

-- ticks (logbook): the crew can see everyone's sends; you can only add, change or delete your own
drop policy if exists "crew reads ticks" on public.ticks;
create policy "crew reads ticks" on public.ticks for select to authenticated
  using (public.is_crew_member(crew_id));
drop policy if exists "log own ticks" on public.ticks;
create policy "log own ticks" on public.ticks for insert to authenticated
  with check (user_id = auth.uid() and public.is_crew_member(crew_id));
drop policy if exists "edit own ticks" on public.ticks;
create policy "edit own ticks" on public.ticks for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "delete own ticks" on public.ticks;
create policy "delete own ticks" on public.ticks for delete to authenticated
  using (user_id = auth.uid());

-- ---------- wall photos ----------
-- private bucket; photos live at <crew id>/<file> and only that crew can see them
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('wall-photos', 'wall-photos', false, 10485760, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists "crew views wall photos" on storage.objects;
create policy "crew views wall photos" on storage.objects for select to authenticated
  using (bucket_id = 'wall-photos' and public.is_crew_member(((storage.foldername(name))[1])::uuid));
drop policy if exists "crew uploads wall photos" on storage.objects;
create policy "crew uploads wall photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'wall-photos' and public.is_crew_member(((storage.foldername(name))[1])::uuid));
drop policy if exists "crew deletes wall photos" on storage.objects;
create policy "crew deletes wall photos" on storage.objects for delete to authenticated
  using (bucket_id = 'wall-photos' and public.is_crew_member(((storage.foldername(name))[1])::uuid));

-- ---------- live updates (new problems and sends appear without refreshing) ----------
do $$
declare t text;
begin
  foreach t in array array['walls','problems','ticks'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- Done. You should see "Success. No rows returned".
