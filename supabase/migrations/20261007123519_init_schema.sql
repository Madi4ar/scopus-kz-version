-- Реестр журналов и статей для пилотного подключения к научной поисковой платформе.
-- Схема соответствует kazakhstan_journals_registry_pilot.md

create table if not exists journals (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  publisher text,
  base_url text not null,
  archive_url text,
  platform text,
  oai_endpoint text,
  issn_print text,
  issn_online text,
  language text,
  open_access boolean default true,
  crawler_type text default 'oai_pmh',
  last_crawled_at timestamptz,
  is_active boolean default true,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists articles (
  id uuid primary key default gen_random_uuid(),
  journal_id uuid not null references journals(id) on delete cascade,
  oai_identifier text,
  title text not null,
  authors text,
  abstract text,
  keywords text,
  doi text,
  publication_date date,
  volume text,
  issue text,
  pages text,
  language text,
  article_url text,
  pdf_url text,
  section text,
  metadata_quality text default 'partial' check (metadata_quality in ('complete', 'partial', 'minimal')),
  raw_metadata jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (journal_id, oai_identifier)
);

create index if not exists articles_journal_id_idx on articles(journal_id);
create index if not exists articles_doi_idx on articles(doi);

-- Полнотекстовый поиск по названию, авторам, аннотации и ключевым словам
alter table articles add column if not exists search_vector tsvector
  generated always as (
    setweight(to_tsvector('simple', coalesce(title, '')), 'A') ||
    setweight(to_tsvector('simple', coalesce(authors, '')), 'B') ||
    setweight(to_tsvector('simple', coalesce(keywords, '')), 'B') ||
    setweight(to_tsvector('simple', coalesce(abstract, '')), 'C')
  ) stored;

create index if not exists articles_search_vector_idx on articles using gin(search_vector);

-- RLS: публичный доступ только на чтение, запись только через service_role (Edge Function)
alter table journals enable row level security;
alter table articles enable row level security;

create policy "public read journals" on journals for select using (true);
create policy "public read articles" on articles for select using (true);

-- RPC для поиска статей, используется фронтендом через supabase-js (.rpc)
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
    ts_rank(a.search_vector, websearch_to_tsquery('simple', query)) as rank
  from articles a
  join journals j on j.id = a.journal_id
  where a.search_vector @@ websearch_to_tsquery('simple', query)
  order by rank desc
  limit limit_count;
$$;

-- Сид реестра из kazakhstan_journals_registry_pilot.md
insert into journals (name, publisher, base_url, archive_url, platform, oai_endpoint, issn_print, issn_online, language, open_access, notes)
values
  (
    'Bulletin of L.N. Gumilyov Eurasian National University. PHILOLOGY Series',
    'L.N. Gumilyov Eurasian National University',
    'https://bulphil.enu.kz/index.php/main/issue/view/39',
    'https://bulphil.enu.kz/index.php/main/issue/archive',
    'OJS',
    'https://bulphil.enu.kz/index.php/main/oai',
    null, null,
    'kk,ru,en',
    true,
    'CC BY-NC 4.0. OAI-PMH подтвержден вручную 2026-10-07 (verb=ListRecords, metadataPrefix=oai_dc работает).'
  ),
  (
    'Bulletin of the Karaganda University. Philology Series',
    'Karaganda Buketov University',
    'https://philology-vestnik.buketov.edu.kz/',
    'https://philology-vestnik.buketov.edu.kz/index.php/index/issue/archive',
    'OJS',
    'https://philology-vestnik.buketov.edu.kz/index.php/index/oai',
    '2518-198X', '2663-5127',
    'kk,ru,en',
    true,
    '4 выпуска в год. OAI-PMH подтвержден вручную 2026-10-07.'
  ),
  (
    'Herald of Journalism (Вестник КазНУ. Серия журналистики)',
    'Al-Farabi Kazakh National University',
    'https://bulletin-journalism.kaznu.kz/index.php/1-journal/ru',
    'https://bulletin-journalism.kaznu.kz/index.php/1-journal/ru/issue/archive',
    'OJS',
    'https://bulletin-journalism.kaznu.kz/index.php/1-journal/ru/oai',
    null, null,
    'kk,ru,en',
    true,
    'Архив с 2014 года. OAI endpoint требует локаль в пути (/ru/oai), подтвержден вручную 2026-10-07. Старые статьи могут не иметь DOI/аннотации -> metadata_quality=partial/minimal.'
  )
on conflict do nothing;
