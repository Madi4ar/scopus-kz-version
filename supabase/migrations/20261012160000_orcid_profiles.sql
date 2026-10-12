-- Профиль по ORCID: фронтенд берёт DOI работ из публичного API ORCID и передаёт сюда,
-- статьи матчатся по DOI (без учёта регистра — ~9.8k DOI в базе с заглавными буквами).
-- Тело author_profile вынесено в author_profile_from(ids, key), чтобы оба профиля
-- (по имени и по ORCID) отдавали один и тот же формат.

create index if not exists articles_doi_lower_idx on articles (lower(doi)) where doi is not null;

create or replace function author_profile_from(p_ids uuid[], p_key text)
returns jsonb
language sql
stable
as $$
  with mine as (
    select aa.article_id, aa.name
    from article_authors aa
    where aa.author_key = p_key
      and aa.article_id = any(p_ids)
  ),
  arts as (
    select
      a.id,
      a.title,
      a.authors,
      a.publication_date,
      a.doi,
      a.article_url,
      a.journal_id,
      j.name as journal_name,
      coalesce(a.cited_by_count, 0) as cited_by_count,
      coalesce(a.cited_by_scopus_count, 0) as cited_by_scopus_count,
      coalesce((
        select array_agg((w ->> 'year')::int)
        from jsonb_array_elements(
          case when jsonb_typeof(a.citing_works) = 'array' then a.citing_works else '[]'::jsonb end
        ) w
        where (w ->> 'year') ~ '^\d{4}$'
      ), '{}') as citing_years
    from articles a
    join journals j on j.id = a.journal_id
    where a.id = any(p_ids)
  )
  select jsonb_build_object(
    'key', p_key,
    'name', (select mode() within group (order by name) from mine),
    'variants', (
      select coalesce(jsonb_agg(v order by c desc, v), '[]'::jsonb)
      from (select name as v, count(*) as c from mine group by name) s
    ),
    'articles', (
      select coalesce(jsonb_agg(to_jsonb(arts) order by publication_date desc nulls last), '[]'::jsonb)
      from arts
    ),
    'journals', (
      select coalesce(jsonb_agg(jsonb_build_object('id', journal_id, 'name', journal_name, 'count', c) order by c desc), '[]'::jsonb)
      from (select journal_id, journal_name, count(*) as c from arts group by journal_id, journal_name) s
    ),
    'coauthors', (
      select coalesce(jsonb_agg(jsonb_build_object('name', name, 'count', c) order by c desc, name), '[]'::jsonb)
      from (
        select mode() within group (order by aa.name) as name, count(distinct aa.article_id) as c
        from article_authors aa
        where aa.article_id = any(p_ids)
          and aa.author_key is distinct from p_key
        group by aa.author_key
        order by c desc
        limit 30
      ) s
    )
  );
$$;

create or replace function author_profile(p_name text)
returns jsonb
language sql
stable
as $$
  select author_profile_from(
    coalesce((
      select array_agg(distinct aa.article_id)
      from article_authors aa
      where aa.author_key = author_key(p_name)
    ), '{}'),
    author_key(p_name)
  );
$$;

-- p_dois — DOI работ из ORCID; p_family/p_given — имя из ORCID, чтобы исключить
-- самого автора из соавторов и собрать варианты написания.
create or replace function orcid_profile(p_dois text[], p_family text, p_given text default null)
returns jsonb
language sql
stable
as $$
  select author_profile_from(
    coalesce((
      select array_agg(a.id)
      from articles a
      where a.doi is not null
        and lower(a.doi) = any(select lower(btrim(x)) from unnest(p_dois) x)
    ), '{}'),
    author_key(coalesce(p_family, '') || ', ' || coalesce(p_given, ''))
  );
$$;

grant execute on function author_profile_from(uuid[], text) to anon, authenticated;
grant execute on function author_profile(text) to anon, authenticated;
grant execute on function orcid_profile(text[], text, text) to anon, authenticated;
