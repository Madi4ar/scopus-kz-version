-- search_articles всё ещё падал по statement_timeout (anon: 3s) на частых словах при
-- холодном кэше: «когда язык» → 'язык' → 6.3k совпадений, и каждую строку надо было
-- поднять с диска, чтобы отранжировать.
-- Теперь работа ограничена сверху:
--   1) совпадения в названии — по отдельному GIN-индексу на to_tsvector(title),
--      не больше 1500 кандидатов, ранжирование по title/keywords;
--   2) если их меньше limit_count — добор совпадений из аннотаций/ключевых слов
--      ровно на недостающее число строк.
-- Запрос из одних стоп-слов («когда», «и») сразу возвращает пусто.

create index if not exists articles_title_tsv_idx
  on articles using gin (to_tsvector('russian', coalesce(title, '')));

create or replace function search_articles(
  query text,
  limit_count int default 20,
  journal_filter uuid[] default null,
  koksnvo_filter smallint default null,
  year_from int default null,
  year_to int default null
)
returns table (
  id uuid,
  journal_id uuid,
  journal_name text,
  title text,
  authors text,
  abstract text,
  doi text,
  publication_date date,
  volume text,
  issue text,
  pages text,
  language text,
  article_url text,
  pdf_url text,
  metadata_quality text,
  cited_by_count int,
  cited_by_scopus_count int,
  citing_works jsonb,
  rank real
)
language sql
stable
as $$
  with q as (
    select websearch_to_tsquery('russian', query) as tsq
  ),
  title_candidates as (
    select a.id, a.title, a.keywords
    from articles a
    join journals j on j.id = a.journal_id
    cross join q
    where numnode(q.tsq) > 0
      and to_tsvector('russian', coalesce(a.title, '')) @@ q.tsq
      and (journal_filter is null or cardinality(journal_filter) = 0 or a.journal_id = any(journal_filter))
      and (koksnvo_filter is null or j.koksnvo_list = koksnvo_filter)
      and (year_from is null or a.publication_date >= make_date(year_from, 1, 1))
      and (year_to is null or a.publication_date <= make_date(year_to, 12, 31))
    limit 1500
  ),
  title_hits as (
    select
      c.id,
      (ts_rank(to_tsvector('russian', coalesce(c.title, '')), q.tsq) * 2
        + ts_rank(to_tsvector('russian', coalesce(c.keywords, '')), q.tsq))::real + 1 as rank
    from title_candidates c
    cross join q
    order by rank desc
    limit limit_count
  ),
  body_hits as (
    select a.id, 0::real as rank
    from articles a
    join journals j on j.id = a.journal_id
    cross join q
    where numnode(q.tsq) > 0
      and a.search_vector @@ q.tsq
      and not (to_tsvector('russian', coalesce(a.title, '')) @@ q.tsq)
      and (journal_filter is null or cardinality(journal_filter) = 0 or a.journal_id = any(journal_filter))
      and (koksnvo_filter is null or j.koksnvo_list = koksnvo_filter)
      and (year_from is null or a.publication_date >= make_date(year_from, 1, 1))
      and (year_to is null or a.publication_date <= make_date(year_to, 12, 31))
    limit greatest(limit_count - (select count(*) from title_hits), 0)
  ),
  hits as (
    select * from title_hits
    union all
    select * from body_hits
  )
  select
    a.id,
    a.journal_id,
    j.name as journal_name,
    a.title,
    a.authors,
    a.abstract,
    a.doi,
    a.publication_date,
    a.volume,
    a.issue,
    a.pages,
    a.language,
    a.article_url,
    a.pdf_url,
    a.metadata_quality,
    a.cited_by_count,
    a.cited_by_scopus_count,
    a.citing_works,
    h.rank
  from hits h
  join articles a on a.id = h.id
  join journals j on j.id = a.journal_id
  order by h.rank desc, a.publication_date desc nulls last;
$$;

grant execute on function search_articles(text, int, uuid[], smallint, int, int) to anon, authenticated;
