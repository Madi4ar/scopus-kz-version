-- Upsert'ы харвестера в среднем идут ~1s, но отдельные растягивались до 50–60s
-- (pg_stat_statements: mean 1001ms, max 52029ms) и падали даже с лимитом 60s.
-- Причина — pending list GIN-индексов (fastupdate): вставки копят записи в очереди,
-- а её разбор (~5s на текущем объёме) выполняется внутри чьей-то вставки, пока
-- остальные 4 воркера харвестера ждут.
-- Замер на 100 реальных статьях (в транзакции с откатом):
--   fastupdate=on  — 0.64s на вставку + 4.8s на разбор очереди, когда он случается;
--   fastupdate=off — 2.6–3.0s на вставку, стабильно, без всплесков.
-- Выключаем очередь у обоих полнотекстовых индексов: вставка предсказуемая, а поиску
-- больше не нужно просматривать неразобранную очередь на каждом запросе.

alter index articles_search_vector_idx set (fastupdate = off);
alter index articles_title_tsv_idx set (fastupdate = off);

-- уже накопленная очередь не разбирается сама после выключения fastupdate
select gin_clean_pending_list('articles_search_vector_idx'::regclass);
select gin_clean_pending_list('articles_title_tsv_idx'::regclass);

-- журналы, упавшие на таймауте записи, — снова в очередь харвеста
update journals
set harvest_error = null,
    harvest_error_at = null
where harvest_error ilike '%statement timeout%';
