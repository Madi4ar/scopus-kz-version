-- Справочник журналов, индексируемых Scopus (для сверки цитирующих источников).
-- Данные загружаются отдельно (не в миграции — список ~49k строк, обновляется
-- Elsevier ежемесячно: https://www.elsevier.com/products/scopus/content).
create table if not exists scopus_sources (
  sourcerecord_id bigint primary key,
  title text not null,
  issn text,
  eissn text,
  status text
);

create index if not exists scopus_sources_issn_idx on scopus_sources(issn) where issn is not null;
create index if not exists scopus_sources_eissn_idx on scopus_sources(eissn) where eissn is not null;

alter table scopus_sources enable row level security;
create policy "public read scopus_sources" on scopus_sources for select using (true);

-- Поля цитирования в articles: считаем через OpenAlex (бесплатный API по DOI),
-- cited_by_scopus_count — подмножество citing-работ, чей журнал найден в scopus_sources.
alter table articles add column if not exists cited_by_count int;
alter table articles add column if not exists cited_by_scopus_count int;
alter table articles add column if not exists citing_works jsonb;
alter table articles add column if not exists citations_checked_at timestamptz;

create index if not exists articles_citations_checked_idx on articles(citations_checked_at);
