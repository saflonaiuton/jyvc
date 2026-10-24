-- JayVC's Supabase schema. Apply this file in the Supabase SQL editor.
-- The app's API uses the service-role key only on the server; never expose it
-- to a browser. Clients can read only their own profile and queue row.

create extension if not exists pgcrypto;

create table if not exists public.guest_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null unique,
  gender text check (gender in ('Male', 'Female')),
  match_with text check (match_with in ('Male', 'Female')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint guest_profile_preferences_complete
    check ((gender is null and match_with is null) or (gender is not null and match_with is not null))
);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  user_a_id uuid not null references auth.users(id) on delete cascade,
  user_b_id uuid not null references auth.users(id) on delete cascade,
  state text not null default 'active' check (state in ('active', 'ended')),
  ended_by uuid references auth.users(id),
  daily_room_name text not null unique,
  daily_room_url text,
  room_state text not null default 'pending' check (room_state in ('pending', 'creating', 'ready', 'failed')),
  room_claimed_at timestamptz,
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  constraint distinct_match_participants check (user_a_id <> user_b_id)
);

create index if not exists matches_user_a_active_idx
  on public.matches (user_a_id, created_at desc);
create index if not exists matches_user_b_active_idx
  on public.matches (user_b_id, created_at desc);

create table if not exists public.matchmaking_queue (
  user_id uuid primary key references auth.users(id) on delete cascade,
  gender text not null check (gender in ('Male', 'Female')),
  match_with text not null check (match_with in ('Male', 'Female')),
  state text not null default 'waiting' check (state in ('waiting', 'matched')),
  match_id uuid references public.matches(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists matchmaking_queue_waiting_preferences_idx
  on public.matchmaking_queue (gender, match_with, created_at)
  where state = 'waiting';

create table if not exists public.guest_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reported_id uuid not null references auth.users(id) on delete cascade,
  match_id uuid not null references public.matches(id) on delete cascade,
  reason text not null check (reason in ('inappropriate', 'harassment', 'underage', 'spam', 'other')),
  details text check (char_length(details) <= 500),
  created_at timestamptz not null default now(),
  constraint distinct_report_participants check (reporter_id <> reported_id),
  unique (reporter_id, match_id)
);

alter table public.guest_profiles enable row level security;
alter table public.matches enable row level security;
alter table public.matchmaking_queue enable row level security;
alter table public.guest_reports enable row level security;

drop policy if exists "Guests can read their own profile" on public.guest_profiles;
create policy "Guests can read their own profile"
  on public.guest_profiles for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Guests can read their own queue row" on public.matchmaking_queue;
create policy "Guests can read their own queue row"
  on public.matchmaking_queue for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Guests can read matches they participate in" on public.matches;
create policy "Guests can read matches they participate in"
  on public.matches for select
  to authenticated
  using (auth.uid() = user_a_id or auth.uid() = user_b_id);

-- No browser write policies are defined. The trusted API verifies each Supabase
-- access token before using the service-role client to mutate queue and reports.
-- guest_reports intentionally has no client read policy.

create or replace function public.match_guest_queue(p_user_id uuid)
returns table(match_id uuid, partner_id uuid, daily_room_name text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gender text;
  v_match_with text;
  v_partner_id uuid;
  v_match_id uuid;
  v_room_name text;
begin
  if p_user_id is null then
    raise exception 'A guest id is required';
  end if;

  -- Serialize the short pairing transaction so concurrent queue joins cannot
  -- both skip one another and remain waiting indefinitely.
  perform pg_advisory_xact_lock(hashtext('jayvc_matchmaking_queue'));

  -- Serialize concurrent queue joins for the same guest.
  perform 1
  from public.matchmaking_queue q
  where q.user_id = p_user_id
  for update;

  -- A repeated join after a lost response returns the same active match.
  select m.id,
         case when m.user_a_id = p_user_id then m.user_b_id else m.user_a_id end,
         m.daily_room_name
    into v_match_id, v_partner_id, v_room_name
  from public.matches m
  where m.state = 'active'
    and (m.user_a_id = p_user_id or m.user_b_id = p_user_id)
  order by m.created_at desc
  limit 1;

  if v_match_id is not null then
    return query select v_match_id, v_partner_id, v_room_name;
    return;
  end if;

  select p.gender, p.match_with
    into v_gender, v_match_with
  from public.guest_profiles p
  where p.user_id = p_user_id;

  if v_gender is null
     or v_match_with is null
     or v_gender not in ('Male', 'Female')
     or v_match_with not in ('Male', 'Female') then
    raise exception 'Valid gender preferences are required';
  end if;

  select q.user_id
    into v_partner_id
  from public.matchmaking_queue q
  where q.user_id <> p_user_id
    and q.state = 'waiting'
    and q.gender = v_match_with
    and q.match_with = v_gender
  order by random()
  limit 1
  for update skip locked;

  if v_partner_id is null then
    return;
  end if;

  v_match_id := gen_random_uuid();
  v_room_name := 'jayvc-' || replace(v_match_id::text, '-', '');

  insert into public.matches (id, user_a_id, user_b_id, daily_room_name)
  values (v_match_id, p_user_id, v_partner_id, v_room_name);

  update public.matchmaking_queue
  set state = 'matched', match_id = v_match_id, updated_at = now()
  where user_id in (p_user_id, v_partner_id);

  return query select v_match_id, v_partner_id, v_room_name;
end;
$$;

create or replace function public.claim_daily_room(p_match_id uuid, p_user_id uuid)
returns table(should_create boolean, daily_room_name text, daily_room_url text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_match public.matches%rowtype;
begin
  select * into v_match
  from public.matches m
  where m.id = p_match_id
    and m.state = 'active'
    and (m.user_a_id = p_user_id or m.user_b_id = p_user_id)
  for update;

  if not found then
    raise exception 'Active match not found';
  end if;

  if v_match.daily_room_url is not null then
    return query select false, v_match.daily_room_name, v_match.daily_room_url;
    return;
  end if;

  if v_match.room_state = 'creating'
     and v_match.room_claimed_at > now() - interval '60 seconds' then
    return query select false, v_match.daily_room_name, null::text;
    return;
  end if;

  update public.matches
  set room_state = 'creating', room_claimed_at = now()
  where id = p_match_id;

  return query select true, v_match.daily_room_name, null::text;
end;
$$;

create or replace function public.save_daily_room(p_match_id uuid, p_user_id uuid, p_room_url text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.matches
  set daily_room_url = p_room_url,
      room_state = 'ready',
      room_claimed_at = null
  where id = p_match_id
    and state = 'active'
    and (user_a_id = p_user_id or user_b_id = p_user_id);
  if found then
    update public.matchmaking_queue q
    set updated_at = now()
    where q.match_id = p_match_id;
  end if;
  return found;
end;
$$;

create or replace function public.fail_daily_room(p_match_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.matches
  set room_state = 'failed', room_claimed_at = null
  where id = p_match_id
    and state = 'active'
    and (user_a_id = p_user_id or user_b_id = p_user_id);
  update public.matchmaking_queue q
  set updated_at = now()
  where q.match_id = p_match_id;
end;
$$;

create or replace function public.end_guest_match(p_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_match_id uuid;
begin
  select m.id into v_match_id
  from public.matches m
  where m.state = 'active'
    and (m.user_a_id = p_user_id or m.user_b_id = p_user_id)
  order by m.created_at desc
  limit 1
  for update;

  if v_match_id is not null then
    update public.matches
    set state = 'ended', ended_by = p_user_id, ended_at = now()
    where id = v_match_id;
  end if;

  delete from public.matchmaking_queue q where q.user_id = p_user_id;
  return v_match_id;
end;
$$;

revoke all on function public.match_guest_queue(uuid) from public, anon, authenticated;
revoke all on function public.claim_daily_room(uuid, uuid) from public, anon, authenticated;
revoke all on function public.save_daily_room(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.fail_daily_room(uuid, uuid) from public, anon, authenticated;
revoke all on function public.end_guest_match(uuid) from public, anon, authenticated;
grant execute on function public.match_guest_queue(uuid) to service_role;
grant execute on function public.claim_daily_room(uuid, uuid) to service_role;
grant execute on function public.save_daily_room(uuid, uuid, text) to service_role;
grant execute on function public.fail_daily_room(uuid, uuid) to service_role;
grant execute on function public.end_guest_match(uuid) to service_role;

do $$
begin
  alter publication supabase_realtime add table public.matchmaking_queue;
exception
  when duplicate_object then null;
  when undefined_object then
    raise notice 'supabase_realtime publication is unavailable; enable Realtime for matchmaking_queue in the Supabase dashboard.';
end $$;
