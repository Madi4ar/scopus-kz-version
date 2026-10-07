-- 1) Добавляем в реестр журналов поля для "внутренней страницы" журнала:
--    отрасль/тематика и тип источника (запрошено пользователем).
alter table journals add column if not exists discipline text;
alter table journals add column if not exists source_type text default 'Научный журнал (рецензируемый)';

update journals set
  discipline = 'Филология, лингвистика, литературоведение, переводоведение'
where name like 'Bulletin of L.N. Gumilyov%';

update journals set
  discipline = 'Филология, лингвистика, литературоведение'
where name like 'Bulletin of the Karaganda%';

update journals set
  discipline = 'Журналистика, медиакоммуникации, PR, новые медиа'
where name like 'Herald of Journalism%';

-- 2) Полнотекстовый поиск: 'simple' не делает стемминга, поэтому словоформы
--    ("дискурс" / "дискурсивный") считались разными токенами и поиск по
--    абстракту часто не находил статью. Переключаем на 'russian' —
--    большинство аннотаций на русском, а английские/казахские слова всё
--    равно индексируются как есть (просто без стемминга), так что для них
--    ничего не ломается.
drop index if exists articles_search_vector_idx;
alter table articles drop column if exists search_vector;

alter table articles add column search_vector tsvector
  generated always as (
    setweight(to_tsvector('russian', coalesce(title, '')), 'A') ||
    setweight(to_tsvector('russian', coalesce(authors, '')), 'B') ||
    setweight(to_tsvector('russian', coalesce(keywords, '')), 'B') ||
    setweight(to_tsvector('russian', coalesce(abstract, '')), 'C')
  ) stored;

create index articles_search_vector_idx on articles using gin(search_vector);

create or replace function search_articles(query text, limit_count int default 20)
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
    ts_rank(a.search_vector, websearch_to_tsquery('russian', query)) as rank
  from articles a
  join journals j on j.id = a.journal_id
  where a.search_vector @@ websearch_to_tsquery('russian', query)
  order by rank desc
  limit limit_count;
$$;

-- 3) RPC для "внутренней страницы" реестра: профиль журнала + число статей.
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
  last_crawled_at timestamptz,
  article_count bigint
)
language sql stable
as $$
  select
    j.id, j.name, j.publisher, j.base_url, j.platform, j.oai_endpoint,
    j.issn_print, j.issn_online, j.language, j.open_access, j.discipline,
    j.source_type, j.last_crawled_at,
    count(a.id) as article_count
  from journals j
  left join articles a on a.journal_id = j.id
  group by j.id
  order by j.name;
$$;
