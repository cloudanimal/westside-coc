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
