-- Westside members app — database migrations, in order.
-- Run these in the Supabase SQL editor to rebuild the database from scratch.
-- (These are the exact steps that were applied while building the app.)

-- =====================================================================
-- 1. Base: profiles table + row-level security + auto-profile trigger
-- =====================================================================
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  email text,
  phone text,
  family text,
  photo_url text,
  created_at timestamptz default now()
);

alter table public.profiles enable row level security;

-- (These SELECT/UPDATE policies are REPLACED in step 2; shown for history.)
create policy "Members can view all profiles"
  on public.profiles for select to authenticated using (true);
create policy "Members can create own profile"
  on public.profiles for insert to authenticated with check (auth.uid() = id);
create policy "Members can update own profile"
  on public.profiles for update to authenticated using (auth.uid() = id);

create function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name',''));
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- =====================================================================
-- 2. Roles + approval gating
-- =====================================================================
alter table public.profiles
  add column if not exists role text not null default 'member',
  add column if not exists status text not null default 'pending';

create or replace function public.is_approved(uid uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.profiles where id = uid and status = 'approved');
$$;

create or replace function public.is_admin(uid uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.profiles where id = uid and role = 'admin');
$$;

-- Bootstrap the first admin (change the email if handing off).
update public.profiles set role='admin', status='approved' where email = 'josephwcook@gmail.com';

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, role, status)
  values (
    new.id, new.email,
    coalesce(new.raw_user_meta_data->>'full_name',''),
    case when new.email = 'josephwcook@gmail.com' then 'admin' else 'member' end,
    case when new.email = 'josephwcook@gmail.com' then 'approved' else 'pending' end
  );
  return new;
end;
$$;

-- No self-promotion: non-admins can't change their own role/status.
create or replace function public.guard_profile_privileges()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin(auth.uid()) then
    new.role := old.role;
    new.status := old.status;
  end if;
  return new;
end;
$$;

drop trigger if exists protect_role_status on public.profiles;
create trigger protect_role_status before update on public.profiles
  for each row execute function public.guard_profile_privileges();

drop policy if exists "Members can view all profiles" on public.profiles;
create policy "View own or approved sees all" on public.profiles
  for select to authenticated
  using ( auth.uid() = id or public.is_approved(auth.uid()) );

drop policy if exists "Admins update any profile" on public.profiles;
create policy "Admins update any profile" on public.profiles
  for update to authenticated
  using ( public.is_admin(auth.uid()) );

-- =====================================================================
-- 3. Richer profile fields + avatar storage
-- =====================================================================
alter table public.profiles
  add column if not exists address text,
  add column if not exists birthday date;

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

drop policy if exists "Public read avatars" on storage.objects;
create policy "Public read avatars" on storage.objects
  for select using ( bucket_id = 'avatars' );

drop policy if exists "Users upload own avatar" on storage.objects;
create policy "Users upload own avatar" on storage.objects
  for insert to authenticated
  with check ( bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text );

drop policy if exists "Users update own avatar" on storage.objects;
create policy "Users update own avatar" on storage.objects
  for update to authenticated
  using ( bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text );

-- =====================================================================
-- 4. Self-service account deletion
-- =====================================================================
create or replace function public.delete_own_account()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from auth.users where id = auth.uid();  -- cascades to profiles
end;
$$;
revoke all on function public.delete_own_account() from public;
grant execute on function public.delete_own_account() to authenticated;

-- =====================================================================
-- 5. Member map: geocoded coordinates
-- =====================================================================
alter table public.profiles
  add column if not exists lat double precision,
  add column if not exists lng double precision;

-- =====================================================================
-- 6. RBAC: custom roles + per-section permission levels (0 none,1 read,
--    2 write, 3 full control) + super-admin. Seeds Admin/Leader/Member.
-- =====================================================================
create table if not exists public.roles (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  is_system boolean not null default false,
  created_at timestamptz default now()
);
create table if not exists public.role_permissions (
  role_id uuid not null references public.roles(id) on delete cascade,
  section text not null,
  level int not null default 0 check (level between 0 and 3),
  primary key (role_id, section)
);
alter table public.profiles
  add column if not exists role_id uuid references public.roles(id),
  add column if not exists is_super_admin boolean not null default false;
update public.profiles set is_super_admin = true where email = 'josephwcook@gmail.com';

do $$
declare
  sec text;
  sections text[] := array['directory','calendar','announcements','prayer_wall','approvals','attendance','care','files','giving'];
  admin_id uuid; leader_id uuid; member_id uuid;
begin
  insert into public.roles (name, is_system) values ('Admin', true)  on conflict (name) do nothing;
  insert into public.roles (name, is_system) values ('Leader', true) on conflict (name) do nothing;
  insert into public.roles (name, is_system) values ('Member', true) on conflict (name) do nothing;
  select id into admin_id from public.roles where name='Admin';
  select id into leader_id from public.roles where name='Leader';
  select id into member_id from public.roles where name='Member';
  foreach sec in array sections loop
    insert into public.role_permissions (role_id, section, level) values (admin_id,  sec, 3) on conflict (role_id, section) do update set level = excluded.level;
    insert into public.role_permissions (role_id, section, level) values (leader_id, sec, 2) on conflict (role_id, section) do update set level = excluded.level;
    insert into public.role_permissions (role_id, section, level) values (member_id, sec, 1) on conflict (role_id, section) do update set level = excluded.level;
  end loop;
end $$;

update public.profiles set role_id = (select id from public.roles where name='Member') where role_id is null;
update public.profiles set role_id = (select id from public.roles where name='Admin')  where email = 'josephwcook@gmail.com';

create or replace function public.is_super_admin(uid uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select coalesce((select is_super_admin from public.profiles where id = uid), false);
$$;
create or replace function public.can(uid uuid, sec text, min_level int)
returns boolean language sql security definer stable set search_path = public as $$
  select public.is_super_admin(uid)
      or coalesce((select rp.level >= min_level
             from public.profiles p join public.role_permissions rp on rp.role_id = p.role_id
            where p.id = uid and rp.section = sec), false);
$$;

-- extend the self-escalation guard to the new privilege columns
create or replace function public.guard_profile_privileges()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin(auth.uid()) then
    new.role := old.role; new.status := old.status; new.role_id := old.role_id;
  end if;
  if not public.is_super_admin(auth.uid()) then
    new.is_super_admin := old.is_super_admin;
  end if;
  return new;
end;
$$;

alter table public.roles enable row level security;
alter table public.role_permissions enable row level security;
drop policy if exists "roles readable" on public.roles;
create policy "roles readable" on public.roles for select to authenticated using (true);
drop policy if exists "roles managed by super" on public.roles;
create policy "roles managed by super" on public.roles for all to authenticated
  using (public.is_super_admin(auth.uid())) with check (public.is_super_admin(auth.uid()));
drop policy if exists "role_perms readable" on public.role_permissions;
create policy "role_perms readable" on public.role_permissions for select to authenticated using (true);
drop policy if exists "role_perms managed by super" on public.role_permissions;
create policy "role_perms managed by super" on public.role_permissions for all to authenticated
  using (public.is_super_admin(auth.uid())) with check (public.is_super_admin(auth.uid()));

-- =====================================================================
-- SECTION 7 — Phase-2 engagement tables (announcements, events + RSVP,
-- prayer wall, serving/duties). These were originally created in the
-- Supabase dashboard; captured here (verified against the live schema
-- 2026-09-23) so this file rebuilds the whole database. Every table gates
-- through can(uid, section, level) from SECTION 6. RLS is enabled with
-- per-command policies. events/duties include series_id (see note below).
-- =====================================================================

-- Announcements -------------------------------------------------------
create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  author_id uuid references auth.users(id) on delete set null,
  author_name text,
  created_at timestamptz default now()
);
alter table public.announcements enable row level security;
drop policy if exists "read announcements" on public.announcements;
create policy "read announcements" on public.announcements for select to authenticated
  using (public.can(auth.uid(),'announcements',1));
drop policy if exists "write announcements" on public.announcements;
create policy "write announcements" on public.announcements for insert to authenticated
  with check (public.can(auth.uid(),'announcements',2) and author_id = auth.uid());
drop policy if exists "edit announcements" on public.announcements;
create policy "edit announcements" on public.announcements for update to authenticated
  using (public.can(auth.uid(),'announcements',3) or (public.can(auth.uid(),'announcements',2) and author_id = auth.uid()));
drop policy if exists "delete announcements" on public.announcements;
create policy "delete announcements" on public.announcements for delete to authenticated
  using (public.can(auth.uid(),'announcements',3) or (public.can(auth.uid(),'announcements',2) and author_id = auth.uid()));

-- Events + RSVP -------------------------------------------------------
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  location text,
  event_date date not null,
  start_time text,
  created_by uuid references auth.users(id) on delete set null,
  created_by_name text,
  created_at timestamptz default now(),
  series_id uuid
);
create index if not exists events_series_idx on public.events (series_id);
alter table public.events enable row level security;
drop policy if exists "ev read" on public.events;
create policy "ev read" on public.events for select to authenticated
  using (public.can(auth.uid(),'calendar',1));
drop policy if exists "ev write" on public.events;
create policy "ev write" on public.events for insert to authenticated
  with check (public.can(auth.uid(),'calendar',2) and created_by = auth.uid());
drop policy if exists "ev edit" on public.events;
create policy "ev edit" on public.events for update to authenticated
  using (public.can(auth.uid(),'calendar',3) or (public.can(auth.uid(),'calendar',2) and created_by = auth.uid()));
drop policy if exists "ev delete" on public.events;
create policy "ev delete" on public.events for delete to authenticated
  using (public.can(auth.uid(),'calendar',3) or (public.can(auth.uid(),'calendar',2) and created_by = auth.uid()));

create table if not exists public.event_rsvps (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  response text not null check (response in ('yes','maybe','no')),
  user_name text,
  primary key (event_id, user_id)
);
alter table public.event_rsvps enable row level security;
drop policy if exists "rsvp read" on public.event_rsvps;
create policy "rsvp read" on public.event_rsvps for select to authenticated
  using (public.can(auth.uid(),'calendar',1));
drop policy if exists "rsvp add" on public.event_rsvps;
create policy "rsvp add" on public.event_rsvps for insert to authenticated
  with check (public.can(auth.uid(),'calendar',1) and user_id = auth.uid());
drop policy if exists "rsvp upd" on public.event_rsvps;
create policy "rsvp upd" on public.event_rsvps for update to authenticated
  using (user_id = auth.uid());
drop policy if exists "rsvp del" on public.event_rsvps;
create policy "rsvp del" on public.event_rsvps for delete to authenticated
  using (user_id = auth.uid());

-- Prayer wall ---------------------------------------------------------
create table if not exists public.prayer_requests (
  id uuid primary key default gen_random_uuid(),
  body text not null,
  requester_id uuid references auth.users(id) on delete set null,
  requester_name text,
  answered boolean not null default false,
  created_at timestamptz default now()
);
alter table public.prayer_requests enable row level security;
drop policy if exists "pr read" on public.prayer_requests;
create policy "pr read" on public.prayer_requests for select to authenticated
  using (public.can(auth.uid(),'prayer_wall',1));
drop policy if exists "pr write" on public.prayer_requests;
create policy "pr write" on public.prayer_requests for insert to authenticated
  with check (public.can(auth.uid(),'prayer_wall',2) and requester_id = auth.uid());
drop policy if exists "pr edit" on public.prayer_requests;
create policy "pr edit" on public.prayer_requests for update to authenticated
  using (public.can(auth.uid(),'prayer_wall',3) or (public.can(auth.uid(),'prayer_wall',2) and requester_id = auth.uid()));
drop policy if exists "pr delete" on public.prayer_requests;
create policy "pr delete" on public.prayer_requests for delete to authenticated
  using (public.can(auth.uid(),'prayer_wall',3) or (public.can(auth.uid(),'prayer_wall',2) and requester_id = auth.uid()));

create table if not exists public.prayer_follows (
  request_id uuid not null references public.prayer_requests(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (request_id, user_id)
);
alter table public.prayer_follows enable row level security;
drop policy if exists "pf read" on public.prayer_follows;
create policy "pf read" on public.prayer_follows for select to authenticated
  using (public.can(auth.uid(),'prayer_wall',1));
drop policy if exists "pf add" on public.prayer_follows;
create policy "pf add" on public.prayer_follows for insert to authenticated
  with check (public.can(auth.uid(),'prayer_wall',1) and user_id = auth.uid());
drop policy if exists "pf remove" on public.prayer_follows;
create policy "pf remove" on public.prayer_follows for delete to authenticated
  using (user_id = auth.uid());

-- Serving / duties ----------------------------------------------------
create table if not exists public.duties (
  id uuid primary key default gen_random_uuid(),
  duty_date date not null,
  role text not null,
  assignee_name text,
  assignee_id uuid references auth.users(id) on delete set null,
  note text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz default now(),
  series_id uuid
);
create index if not exists duties_series_idx on public.duties (series_id);
alter table public.duties enable row level security;
drop policy if exists "duty read" on public.duties;
create policy "duty read" on public.duties for select to authenticated
  using (public.can(auth.uid(),'scheduling',1));
drop policy if exists "duty write" on public.duties;
create policy "duty write" on public.duties for insert to authenticated
  with check (public.can(auth.uid(),'scheduling',2));
drop policy if exists "duty edit" on public.duties;
create policy "duty edit" on public.duties for update to authenticated
  using (public.can(auth.uid(),'scheduling',2));
drop policy if exists "duty delete" on public.duties;
create policy "duty delete" on public.duties for delete to authenticated
  using (public.can(auth.uid(),'scheduling',2));

-- =====================================================================
-- SECTION 8 — Multi-date series grouping (2026-09-23, applied live)
-- Historical incremental: events/duties gained series_id so a multi-date
-- entry (one row per date) can be deleted as a set ("Delete all dates").
-- The columns/indexes are already included in SECTION 7 above; these
-- statements are what actually ran against the existing database and are
-- safe to re-run (idempotent).
-- =====================================================================
alter table public.events add column if not exists series_id uuid;
alter table public.duties add column if not exists series_id uuid;
create index if not exists events_series_idx on public.events (series_id);
create index if not exists duties_series_idx on public.duties (series_id);
