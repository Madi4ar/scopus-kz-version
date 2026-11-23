-- Поиск падал на каждом запросе с текстом: в plpgsql RETURN QUERY требует точного
-- совпадения типов, а «real + 1» даёт double precision (ошибка 42804, колонка rank).
-- В 20261012180000 функция была language sql и приводила тип сама. Тело — как в
-- 20261118121000, только rank явно приводится к real.

create or replace function search_articles(
  query text,
  limit_count int default 20,
  journal_filter uuid[] default null,
  koksnvo_filter smallint default null,
  year_from int default null,
  year_to int default null,
  author_filter text default null
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
language plpgsql
stable
as $$
#variable_conflict use_column
declare
  tsq tsquery := websearch_to_tsquery('russian', coalesce(query, ''));
  k text;
  author_ids uuid[];
begin
  if nullif(btrim(author_filter), '') is not null then
    k := author_key(author_filter);
    if k is null then
      return;
    end if;
    execute format($sql$
      select array_agg(article_id) from (
        select distinct article_id from article_authors
        where author_key = %1$L or author_key like %2$L
        limit 5000
      ) s
    $sql$, k, k || ' _') into author_ids;
    if author_ids is null then
      return;
    end if;
  end if;

  if numnode(tsq) = 0 then
    -- без слов запроса ищем только по автору; запрос из одних стоп-слов — пусто
    if author_ids is null then
      return;
    end if;
    return query
    select
      a.id, a.journal_id, j.name, a.title, a.authors, a.abstract, a.doi, a.publication_date,
      a.volume, a.issue, a.pages, a.language, a.article_url, a.pdf_url, a.metadata_quality,
      a.cited_by_count, a.cited_by_scopus_count, a.citing_works, 0::real
    from articles a
    join journals j on j.id = a.journal_id
    where a.id = any(author_ids)
      and (journal_filter is null or cardinality(journal_filter) = 0 or a.journal_id = any(journal_filter))
      and (koksnvo_filter is null or j.koksnvo_list = koksnvo_filter)
      and (year_from is null or a.publication_date >= make_date(year_from, 1, 1))
      and (year_to is null or a.publication_date <= make_date(year_to, 12, 31))
    order by a.publication_date desc nulls last
    limit limit_count;
    return;
  end if;

  return query
  with title_candidates as (
    select a.id, a.title, a.keywords
    from articles a
    join journals j on j.id = a.journal_id
    where to_tsvector('russian', coalesce(a.title, '')) @@ tsq
      and (author_ids is null or a.id = any(author_ids))
      and (journal_filter is null or cardinality(journal_filter) = 0 or a.journal_id = any(journal_filter))
      and (koksnvo_filter is null or j.koksnvo_list = koksnvo_filter)
      and (year_from is null or a.publication_date >= make_date(year_from, 1, 1))
      and (year_to is null or a.publication_date <= make_date(year_to, 12, 31))
    limit 1500
  ),
  title_hits as (
    select
      c.id,
      (ts_rank(to_tsvector('russian', coalesce(c.title, '')), tsq) * 2
        + ts_rank(to_tsvector('russian', coalesce(c.keywords, '')), tsq) + 1)::real as rank
    from title_candidates c
    order by 2 desc
    limit limit_count
  ),
  body_hits as (
    select a.id, 0::real as rank
    from articles a
    join journals j on j.id = a.journal_id
    where a.search_vector @@ tsq
      and not (to_tsvector('russian', coalesce(a.title, '')) @@ tsq)
      and (author_ids is null or a.id = any(author_ids))
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
    a.id, a.journal_id, j.name, a.title, a.authors, a.abstract, a.doi, a.publication_date,
    a.volume, a.issue, a.pages, a.language, a.article_url, a.pdf_url, a.metadata_quality,
    a.cited_by_count, a.cited_by_scopus_count, a.citing_works, h.rank::real
  from hits h
  join articles a on a.id = h.id
  join journals j on j.id = a.journal_id
  order by h.rank desc, a.publication_date desc nulls last;
end;
$$;

grant execute on function search_articles(text, int, uuid[], smallint, int, int, text) to anon, authenticated;
