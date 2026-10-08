-- Добавляем поля цитирования в выдачу search_articles (не только в дефолтный *-листинг).
-- drop обязателен: меняется набор OUT-параметров, create or replace на это не согласен.
drop function if exists search_articles(text, int);

create function search_articles(query text, limit_count int default 20)
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
    ts_rank(a.search_vector, websearch_to_tsquery('russian', query)) as rank
  from articles a
  join journals j on j.id = a.journal_id
  where a.search_vector @@ websearch_to_tsquery('russian', query)
  order by rank desc
  limit limit_count;
$$;
