-- Учётные записи пользователей (документ «Платные вкладки: данные для регистрации»).
--
-- profiles — по одной строке на auth.users: данные формы регистрации, профиль исследователя
--   (повторяющиеся разделы — jsonb-массивы записей, их структуру задаёт фронтенд) и
--   17-значный идентификатор платформы. Электронная почта здесь не хранится — она только
--   в auth.users и другим пользователям не видна.
-- organizations / organization_members — кабинеты школ и вузов; пользователь попадает в
--   организацию по коду приглашения всегда с ролью member, роли curator/admin выдаются
--   отдельно (вручную, сервисным ключом).
-- search_history, saved_articles — история поиска и сохранённые статьи авторизованного
--   пользователя; каждый видит только свои строки (RLS).

-- ---------- идентификатор платформы ----------

create or replace function public.generate_platform_id()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  candidate text;
begin
  loop
    -- 17 цифр, первая не ноль
    candidate := (1 + floor(random() * 9))::int::text
      || lpad(floor(random() * 1e8)::bigint::text, 8, '0')
      || lpad(floor(random() * 1e8)::bigint::text, 8, '0');
    exit when not exists (select 1 from public.profiles where platform_id = candidate);
  end loop;
  return candidate;
end;
$$;

-- ---------- профиль ----------

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  platform_id text not null unique check (platform_id ~ '^[1-9][0-9]{16}$'),
  first_name text not null default '' check (char_length(first_name) <= 100),
  last_name text not null default '' check (char_length(last_name) <= 100),
  display_name text check (char_length(display_name) <= 200),
  country text check (char_length(country) <= 100),
  category text check (category in ('pupil', 'student', 'teacher', 'researcher')),
  bio text check (char_length(bio) <= 3000),
  publication_names text[] not null default '{}',
  orcid_id text check (orcid_id ~ '^[0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]{3}[0-9X]$'),
  -- true только после подтверждения через вход в ORCID (OAuth); пользователь сам не меняет
  orcid_verified boolean not null default false,
  scopus_author_id text check (scopus_author_id ~ '^[0-9]{5,15}$'),
  research_area text check (char_length(research_area) <= 300),
  research_topics text[] not null default '{}',
  keywords text[] not null default '{}',
  links jsonb not null default '[]' check (jsonb_typeof(links) = 'array'),
  education jsonb not null default '[]' check (jsonb_typeof(education) = 'array'),
  employment jsonb not null default '[]' check (jsonb_typeof(employment) = 'array'),
  works jsonb not null default '[]' check (jsonb_typeof(works) = 'array'),
  grants jsonb not null default '[]' check (jsonb_typeof(grants) = 'array'),
  activities jsonb not null default '[]' check (jsonb_typeof(activities) = 'array'),
  reviews jsonb not null default '[]' check (jsonb_typeof(reviews) = 'array'),
  mentoring jsonb not null default '[]' check (jsonb_typeof(mentoring) = 'array'),
  terms_accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles alter column platform_id set default public.generate_platform_id();

alter table public.profiles enable row level security;

drop policy if exists "profiles own read" on public.profiles;
create policy "profiles own read" on public.profiles
  for select to authenticated using ((select auth.uid()) = id);

drop policy if exists "profiles own update" on public.profiles;
create policy "profiles own update" on public.profiles
  for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

-- Строку создаёт триггер регистрации; менять можно только «пользовательские» колонки —
-- id, platform_id, orcid_verified и дата согласия с условиями остаются за сервером.
revoke all on table public.profiles from anon, authenticated;
grant select on table public.profiles to authenticated;
grant update (
  first_name, last_name, display_name, country, category, bio, publication_names,
  orcid_id, scopus_author_id, research_area, research_topics, keywords, links,
  education, employment, works, grants, activities, reviews, mentoring
) on table public.profiles to authenticated;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- При смене ORCID iD подтверждение сбрасывается.
create or replace function public.profiles_reset_orcid_verified()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.orcid_id is distinct from old.orcid_id then
    new.orcid_verified := false;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_reset_orcid_verified on public.profiles;
create trigger profiles_reset_orcid_verified
  before update of orcid_id on public.profiles
  for each row execute function public.profiles_reset_orcid_verified();

-- ---------- организации ----------

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text not null unique check (invite_code ~ '^[A-Z0-9-]{6,32}$'),
  created_at timestamptz not null default now()
);

create table if not exists public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('member', 'curator', 'admin')),
  joined_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);

create index if not exists organization_members_user_idx on public.organization_members (user_id);

alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
revoke all on table public.organizations, public.organization_members from anon, authenticated;
grant select on table public.organizations, public.organization_members to authenticated;

drop policy if exists "members read own memberships" on public.organization_members;
create policy "members read own memberships" on public.organization_members
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "members read own organizations" on public.organizations;
create policy "members read own organizations" on public.organizations
  for select to authenticated using (
    exists (
      select 1 from public.organization_members m
      where m.organization_id = organizations.id and m.user_id = (select auth.uid())
    )
  );

-- Проверка кода в форме регистрации: название организации или null.
create or replace function public.check_invite_code(p_code text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select name from public.organizations where invite_code = upper(btrim(p_code));
$$;

revoke all on function public.check_invite_code(text) from public;
grant execute on function public.check_invite_code(text) to anon, authenticated;

-- Присоединиться к организации из личного кабинета (роль — всегда member).
create or replace function public.join_organization(p_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  org public.organizations;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  select * into org from public.organizations where invite_code = upper(btrim(p_code));
  if org.id is null then
    raise exception 'invalid invite code' using errcode = 'P0002';
  end if;
  insert into public.organization_members (organization_id, user_id)
  values (org.id, auth.uid())
  on conflict do nothing;
  return org.name;
end;
$$;

revoke all on function public.join_organization(text) from public;
grant execute on function public.join_organization(text) to authenticated;

-- ---------- регистрация ----------

-- Данные формы регистрации приходят в raw_user_meta_data (options.data в signUp).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  cat text := meta->>'category';
  code text := upper(btrim(coalesce(meta->>'invite_code', '')));
  org_id uuid;
begin
  if cat not in ('pupil', 'student', 'teacher', 'researcher') then
    cat := null;
  end if;
  insert into public.profiles (id, first_name, last_name, category, terms_accepted_at)
  values (
    new.id,
    left(btrim(coalesce(meta->>'first_name', '')), 100),
    left(btrim(coalesce(meta->>'last_name', '')), 100),
    cat,
    case when meta->>'terms_accepted' = 'true' then now() end
  )
  on conflict (id) do nothing;

  if code <> '' then
    select id into org_id from public.organizations where invite_code = code;
    if org_id is not null then
      insert into public.organization_members (organization_id, user_id)
      values (org_id, new.id)
      on conflict do nothing;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- история поиска ----------

create table if not exists public.search_history (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  query text not null default '' check (char_length(query) <= 500),
  filters jsonb not null default '{}' check (jsonb_typeof(filters) = 'object'),
  result_count int,
  created_at timestamptz not null default now()
);

create index if not exists search_history_user_created_idx on public.search_history (user_id, created_at desc);

alter table public.search_history enable row level security;
revoke all on table public.search_history from anon, authenticated;
grant select, delete on table public.search_history to authenticated;

drop policy if exists "search history own read" on public.search_history;
create policy "search history own read" on public.search_history
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "search history own delete" on public.search_history;
create policy "search history own delete" on public.search_history
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Запись в историю: повтор того же запроса с теми же фильтрами подряд только обновляет
-- время и число результатов; хранится не больше 200 последних записей.
create or replace function public.record_search(p_query text, p_filters jsonb default '{}', p_result_count int default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  last_row public.search_history;
  q text := left(btrim(coalesce(p_query, '')), 500);
  f jsonb := case when jsonb_typeof(p_filters) = 'object' then p_filters else '{}'::jsonb end;
begin
  if uid is null then
    return;
  end if;
  select * into last_row from public.search_history
  where user_id = uid order by created_at desc limit 1;
  if last_row.id is not null and last_row.query = q and last_row.filters = f then
    update public.search_history set created_at = now(), result_count = p_result_count where id = last_row.id;
    return;
  end if;
  insert into public.search_history (user_id, query, filters, result_count) values (uid, q, f, p_result_count);
  delete from public.search_history
  where user_id = uid and id in (
    select id from public.search_history where user_id = uid order by created_at desc offset 200
  );
end;
$$;

revoke all on function public.record_search(text, jsonb, int) from public;
grant execute on function public.record_search(text, jsonb, int) to authenticated;

-- ---------- сохранённые статьи ----------

create table if not exists public.saved_articles (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  article_id uuid not null references public.articles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, article_id)
);

create index if not exists saved_articles_user_created_idx on public.saved_articles (user_id, created_at desc);

alter table public.saved_articles enable row level security;
revoke all on table public.saved_articles from anon, authenticated;
grant select, insert, delete on table public.saved_articles to authenticated;

drop policy if exists "saved articles own read" on public.saved_articles;
create policy "saved articles own read" on public.saved_articles
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "saved articles own insert" on public.saved_articles;
create policy "saved articles own insert" on public.saved_articles
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists "saved articles own delete" on public.saved_articles;
create policy "saved articles own delete" on public.saved_articles
  for delete to authenticated using ((select auth.uid()) = user_id);
