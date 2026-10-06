-- Active Pitch: Supabase schema

create extension if not exists postgis with schema extensions;

create type public.game_type as enum ('casual', 'full_sided');

-- profiles: one row per auth user, holds the public username
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  username    text not null check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  created_at  timestamptz not null default now()
);

-- case-insensitive uniqueness ("Brody" and "brody" can't both exist)
create unique index profiles_username_lower_idx on public.profiles (lower(username));

-- auto-create a profile when someone signs up.
-- client calls: supabase.auth.signUp({ email, password, options: { data: { username } } })
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, username)
  values (new.id, new.raw_user_meta_data ->> 'username');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- pins: one row per announced game
create table public.pins (
  id            uuid primary key default gen_random_uuid(),
  creator_id    uuid not null references public.profiles (id) on delete cascade,
  location      extensions.geography(point, 4326) not null,
  game_type     public.game_type not null,
  starts_at     timestamptz not null,
  expires_at    timestamptz not null,   -- always starts_at + 4h, set by trigger
  cancelled_at  timestamptz,            -- null = active (soft cancel)
  created_at    timestamptz not null default now()
);

create index pins_location_idx   on public.pins using gist (location);
create index pins_expires_at_idx on public.pins (expires_at);
create index pins_creator_id_idx on public.pins (creator_id);

-- expires_at can't be a generated column (timestamptz + interval isn't
-- immutable in Postgres), so a trigger keeps it in sync instead
create function public.set_pin_expiry()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.expires_at := new.starts_at + interval '4 hours';
  return new;
end;
$$;

create trigger pins_set_expiry
  before insert or update of starts_at on public.pins
  for each row execute function public.set_pin_expiry();

-- rsvps: composite primary key = one RSVP per user per pin
create table public.rsvps (
  pin_id      uuid not null references public.pins (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (pin_id, user_id)
);

create index rsvps_user_id_idx on public.rsvps (user_id);

-- Row-level security
alter table public.profiles enable row level security;
alter table public.pins     enable row level security;
alter table public.rsvps    enable row level security;

-- profiles
create policy "profiles readable by signed-in users"
  on public.profiles for select to authenticated
  using (true);

-- pins
create policy "pins readable by signed-in users"
  on public.pins for select to authenticated
  using (true);

create policy "users create their own pins"
  on public.pins for insert to authenticated
  with check ((select auth.uid()) = creator_id);

create policy "creators can cancel their pins"
  on public.pins for update to authenticated
  using ((select auth.uid()) = creator_id)
  with check ((select auth.uid()) = creator_id);

-- the only column a user may ever update is cancelled_at
-- (no pin editing, matches the out-of-scope list)
revoke update on public.pins from anon, authenticated;
grant update (cancelled_at) on public.pins to authenticated;

-- rsvps: users only ever see their OWN rsvp rows.
-- headcounts come from pins_near_me(), so nobody can list attendees.
create policy "users see their own rsvps"
  on public.rsvps for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "users rsvp to active pins"
  on public.rsvps for insert to authenticated
  with check (
    (select auth.uid()) = user_id
    and exists (
      select 1 from public.pins p
      where p.id = pin_id
        and p.cancelled_at is null
        and p.expires_at > now()
    )
  );

-- creators can't drop their own rsvp; they cancel the pin instead
create policy "users remove their own rsvps"
  on public.rsvps for delete to authenticated
  using (
    (select auth.uid()) = user_id
    and not exists (
      select 1 from public.pins p
      where p.id = pin_id
        and p.creator_id = (select auth.uid())
    )
  );

-- Functions (called from the app via supabase.rpc)

-- get pins near me: active pins within radius, with headcount.
-- security definer so it can COUNT rsvps that RLS hides from the caller.
create function public.pins_near_me(
  p_lat      double precision,
  p_lng      double precision,
  p_radius_m double precision default 10000
)
returns table (
  id               uuid,
  lat              double precision,
  lng              double precision,
  game_type        public.game_type,
  starts_at        timestamptz,
  expires_at       timestamptz,
  creator_username text,
  headcount        bigint,
  distance_m       double precision,
  is_mine          boolean,
  i_rsvped         boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    p.id,
    extensions.st_y(p.location::extensions.geometry),
    extensions.st_x(p.location::extensions.geometry),
    p.game_type,
    p.starts_at,
    p.expires_at,
    pr.username,
    (select count(*) from public.rsvps r where r.pin_id = p.id),
    extensions.st_distance(
      p.location,
      extensions.st_point(p_lng, p_lat)::extensions.geography
    ),
    p.creator_id = auth.uid(),
    exists (
      select 1 from public.rsvps r
      where r.pin_id = p.id and r.user_id = auth.uid()
    )
  from public.pins p
  join public.profiles pr on pr.id = p.creator_id
  where p.cancelled_at is null
    and p.expires_at > now()
    and extensions.st_dwithin(
      p.location,
      extensions.st_point(p_lng, p_lat)::extensions.geography,
      least(p_radius_m, 10000)  -- clients can't ask for more than 10 km
    )
  order by p.starts_at;
$$;

-- create pin
create function public.create_pin(
  p_lat       double precision,
  p_lng       double precision,
  p_game_type public.game_type,
  p_starts_at timestamptz
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  new_id uuid;
begin
  if p_starts_at < now() - interval '15 minutes' then
    raise exception 'Start time is in the past';
  end if;
  if p_starts_at > now() + interval '7 days' then
    raise exception 'Start time is too far in the future';
  end if;

  insert into public.pins (creator_id, location, game_type, starts_at)
  values (
    auth.uid(),
    extensions.st_point(p_lng, p_lat)::extensions.geography,
    p_game_type,
    p_starts_at
  )
  returning id into new_id;

  -- creator counts toward the headcount
  insert into public.rsvps (pin_id, user_id)
  values (new_id, auth.uid());

  return new_id;
end;
$$;

-- cancel pin (soft delete)
create function public.cancel_pin(p_pin_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.pins
  set cancelled_at = now()
  where id = p_pin_id
    and creator_id = auth.uid()
    and cancelled_at is null;

  if not found then
    raise exception 'Pin not found, already cancelled, or not yours';
  end if;
end;
$$;

-- rsvp (idempotent: double taps are harmless)
create function public.rsvp(p_pin_id uuid)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into public.rsvps (pin_id, user_id)
  values (p_pin_id, auth.uid())
  on conflict (pin_id, user_id) do nothing;
$$;

-- cancel rsvp
create function public.cancel_rsvp(p_pin_id uuid)
returns void
language sql
security invoker
set search_path = ''
as $$
  delete from public.rsvps
  where pin_id = p_pin_id
    and user_id = auth.uid();
$$;

-- Function permissions: signed-in users only
revoke execute on function public.pins_near_me(double precision, double precision, double precision) from public, anon;
revoke execute on function public.create_pin(double precision, double precision, public.game_type, timestamptz) from public, anon;
revoke execute on function public.cancel_pin(uuid) from public, anon;
revoke execute on function public.rsvp(uuid) from public, anon;
revoke execute on function public.cancel_rsvp(uuid) from public, anon;

grant execute on function public.pins_near_me(double precision, double precision, double precision) to authenticated;
grant execute on function public.create_pin(double precision, double precision, public.game_type, timestamptz) to authenticated;
grant execute on function public.cancel_pin(uuid) to authenticated;
grant execute on function public.rsvp(uuid) to authenticated;
grant execute on function public.cancel_rsvp(uuid) to authenticated;