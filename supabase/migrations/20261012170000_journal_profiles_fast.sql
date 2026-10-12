-- journal_profiles падал по statement_timeout (anon: 3s) на холодном кэше:
-- left join articles читал все 66k широких строк (с аннотациями) ради count(a.id).
-- Считаем статьи заранее агрегатом по journal_id — это index-only scan по
-- articles_journal_id_idx без чтения самих строк.

create or replace function journal_profiles()
returns table (
  id uuid,
  name text,
  publisher text,
  base_url text,
  platform text,
  oai_endpoint text,
  issn_print text,
  issn_online text,
  language text,
  open_access boolean,
  discipline text,
  source_type text,
  koksnvo_list smallint,
  koksnvo_order text,
  koksnvo_included_from text,
  last_crawled_at timestamptz,
  harvest_error text,
  article_count bigint
)
language sql stable
as $$
  with counts as (
    select a.journal_id, count(*) as n
    from articles a
    group by a.journal_id
  )
  select
    j.id, j.name, j.publisher, j.base_url, j.platform, j.oai_endpoint,
    j.issn_print, j.issn_online, j.language, j.open_access, j.discipline,
    j.source_type, j.koksnvo_list, j.koksnvo_order, j.koksnvo_included_from,
    j.last_crawled_at, j.harvest_error,
    coalesce(c.n, 0) as article_count
  from journals j
  left join counts c on c.journal_id = j.id
  order by coalesce(c.n, 0) desc, j.name;
$$;
