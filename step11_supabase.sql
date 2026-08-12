-- ============================================================
-- PetXchange — Step 11: report, repost, save post,
--                       "new here" support
-- Run AFTER step 10. Safe to run more than once.
-- Supabase → SQL Editor → New query → Run
-- ============================================================

-- ============================================================
-- 1. REPORT POST
-- ============================================================
create table if not exists public.post_reports (
  id           uuid primary key default gen_random_uuid(),
  post_id      uuid not null references public.posts(id) on delete cascade,
  reporter_id  uuid not null references auth.users(id) on delete cascade,
  reason       text not null,
  details      text,
  status       text not null default 'pending',
  created_at   timestamptz not null default now()
);

alter table public.post_reports drop constraint if exists post_reports_reason_check;
alter table public.post_reports add constraint post_reports_reason_check
  check (reason in (
    'spam','harassment_or_bullying','hate_speech','nudity_or_sexual_content',
    'violence_or_dangerous','animal_cruelty','misinformation','scam_or_fraud',
    'intellectual_property','other'
  ));

alter table public.post_reports drop constraint if exists post_reports_status_check;
alter table public.post_reports add constraint post_reports_status_check
  check (status in ('pending','reviewed','dismissed','actioned'));

-- embed-enabling FK, same fix as fix_embeds.sql — reporter_id points at
-- auth.users for integrity, and separately at profiles so
-- select('..., profiles(full_name, avatar_url)') works on this table too
do $$
begin
  alter table public.post_reports
    add constraint post_reports_reporter_id_profiles_fkey
    foreign key (reporter_id) references public.profiles(id) on delete cascade;
exception when duplicate_object then null;
end $$;

create unique index if not exists post_reports_pair_unique on public.post_reports (post_id, reporter_id);
create index if not exists post_reports_post_idx on public.post_reports (post_id);
create index if not exists post_reports_status_idx on public.post_reports (status);

alter table public.post_reports enable row level security;

drop policy if exists "post_reports_select_own" on public.post_reports;
drop policy if exists "post_reports_insert_own" on public.post_reports;
drop policy if exists "post_reports_delete_own" on public.post_reports;

create policy "post_reports_select_own" on public.post_reports
  for select to authenticated using (reporter_id = auth.uid());

create policy "post_reports_insert_own" on public.post_reports
  for insert to authenticated with check (reporter_id = auth.uid());

-- can retract a report while it's still pending, not after it's been reviewed
create policy "post_reports_delete_own" on public.post_reports
  for delete to authenticated using (reporter_id = auth.uid() and status = 'pending');


-- ============================================================
-- 2. REPOST
-- ============================================================
create table if not exists public.post_reposts (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references public.posts(id) on delete cascade,  -- original post
  user_id    uuid not null references auth.users(id) on delete cascade,    -- who reposted
  comment    text,                                                         -- optional quote-repost caption
  created_at timestamptz not null default now()
);

do $$
begin
  alter table public.post_reposts
    add constraint post_reposts_user_id_profiles_fkey
    foreign key (user_id) references public.profiles(id) on delete cascade;
exception when duplicate_object then null;
end $$;

create unique index if not exists post_reposts_pair_unique on public.post_reposts (post_id, user_id);
create index if not exists post_reposts_post_idx on public.post_reposts (post_id);
create index if not exists post_reposts_user_idx on public.post_reposts (user_id, created_at desc);

alter table public.post_reposts enable row level security;

drop policy if exists "post_reposts_select_all" on public.post_reposts;
drop policy if exists "post_reposts_insert_own" on public.post_reposts;
drop policy if exists "post_reposts_delete_own" on public.post_reposts;

-- visible to everyone, same as likes/comments, so repost counts and
-- "reposted by" lists can render on any profile
create policy "post_reposts_select_all" on public.post_reposts
  for select to authenticated using (true);

create policy "post_reposts_insert_own" on public.post_reposts
  for insert to authenticated with check (user_id = auth.uid());

create policy "post_reposts_delete_own" on public.post_reposts
  for delete to authenticated using (user_id = auth.uid());

-- reuses push_notification() / actor_name() defined in step 10
create or replace function public.notify_repost()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_author uuid;
begin
  select author_id into v_author from public.posts where id = new.post_id;
  perform push_notification(v_author, new.user_id, 'repost',
    actor_name(new.user_id) || ' reposted your post', new.comment, new.post_id, 'post');
  return new;
end $$;
drop trigger if exists notify_repost_trg on public.post_reposts;
create trigger notify_repost_trg after insert on public.post_reposts
  for each row execute function public.notify_repost();


-- ============================================================
-- 3. SAVE POST
-- ============================================================
create table if not exists public.saved_posts (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references public.posts(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

do $$
begin
  alter table public.saved_posts
    add constraint saved_posts_user_id_profiles_fkey
    foreign key (user_id) references public.profiles(id) on delete cascade;
exception when duplicate_object then null;
end $$;

create unique index if not exists saved_posts_pair_unique on public.saved_posts (post_id, user_id);
create index if not exists saved_posts_user_idx on public.saved_posts (user_id, created_at desc);

alter table public.saved_posts enable row level security;

drop policy if exists "saved_posts_select_own" on public.saved_posts;
drop policy if exists "saved_posts_insert_own" on public.saved_posts;
drop policy if exists "saved_posts_delete_own" on public.saved_posts;

-- private by design, like Instagram saves — nobody but the saver can see their list
create policy "saved_posts_select_own" on public.saved_posts
  for select to authenticated using (user_id = auth.uid());

create policy "saved_posts_insert_own" on public.saved_posts
  for insert to authenticated with check (user_id = auth.uid());

create policy "saved_posts_delete_own" on public.saved_posts
  for delete to authenticated using (user_id = auth.uid());


-- ============================================================
-- 4. "NEW HERE" SUPPORT
-- profiles almost certainly already has created_at (set when the
-- signup trigger creates the row) — this is just a safety net.
-- NOTE: if this column genuinely doesn't exist yet, every existing
-- profile will backfill to the same today's-timestamp default, which
-- would make everyone look "new" until real signups age past your
-- cutoff. Check `select created_at from public.profiles limit 1;`
-- first if you're unsure whether it's already there.
-- ============================================================
alter table public.profiles
  add column if not exists created_at timestamptz not null default now();


-- ============================================================
-- 5. VERIFY
-- ============================================================
select 'tables' as check_name, table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('post_reports','post_reposts','saved_posts')
order by table_name;

select 'repost trigger' as check_name, trigger_name
from information_schema.triggers
where trigger_schema = 'public' and trigger_name = 'notify_repost_trg';

select 'pending reports' as check_name, count(*) from public.post_reports where status = 'pending';

-- confirms the profiles embed FKs actually landed, so
-- select('..., profiles(full_name, avatar_url)') will work on these tables
select
  tc.table_name as source_table,
  kcu.column_name as source_column,
  ccu.table_name as points_to
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
  on tc.constraint_name = kcu.constraint_name and tc.table_schema = kcu.table_schema
join information_schema.constraint_column_usage ccu
  on tc.constraint_name = ccu.constraint_name and tc.table_schema = ccu.table_schema
where tc.constraint_type = 'FOREIGN KEY'
  and tc.table_schema = 'public'
  and ccu.table_name = 'profiles'
  and tc.table_name in ('post_reports','post_reposts','saved_posts')
order by tc.table_name, kcu.column_name;
