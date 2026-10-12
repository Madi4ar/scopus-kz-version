-- search_articles падал по statement_timeout (anon: 3s) на частых словах:
-- ts_rank по search_vector распаковывал из TOAST огромные векторы аннотаций
-- у каждой найденной статьи (~7s на 5k совпадений).
-- Теперь: отбор по-прежнему через GIN-индекс search_vector, а ранжирование —
-- по коротким title/keywords (название весит вдвое больше), при равенстве — новее выше.
-- Заодно фильтр по годам публикации делается в SQL, а не поверх limit,
-- а journal_filter принимает массив — можно выбрать несколько журналов.

drop function if exists search_articles(text, int, uuid, smallint);

create function search_articles(
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
language sql stable
as $$
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
    (ts_rank(to_tsvector('russian', coalesce(a.title, '')), q) * 2
      + ts_rank(to_tsvector('russian', coalesce(a.keywords, '')), q))::real as rank
  from articles a
  join journals j on j.id = a.journal_id
  cross join websearch_to_tsquery('russian', query) q
  where a.search_vector @@ q
    and (journal_filter is null or cardinality(journal_filter) = 0 or a.journal_id = any(journal_filter))
    and (koksnvo_filter is null or j.koksnvo_list = koksnvo_filter)
    and (year_from is null or a.publication_date >= make_date(year_from, 1, 1))
    and (year_to is null or a.publication_date <= make_date(year_to, 12, 31))
  order by rank desc, a.publication_date desc nulls last
  limit limit_count;
$$;

grant execute on function search_articles(text, int, uuid[], smallint, int, int) to anon, authenticated;
