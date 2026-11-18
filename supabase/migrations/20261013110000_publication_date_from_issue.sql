-- 1) Сокращение raw_metadata. 2) Дата публикации из выпуска, а не из dc:date.
--
-- 1. raw_metadata хранила полную запись Dublin Core из OAI и занимала >60% базы
--    (оценка по выборке: ~535 МБ из ~880 МБ данных, из них аннотации на 2–3 языках
--    ~324 МБ — копия колонки abstract). Из-за этого база (859 МБ) превысила лимит
--    бесплатного тарифа 0.5 ГБ и ушла в read-only. Сайт raw_metadata не использует;
--    оставляем только source (описание выпуска с годом), date и пометки импорта.
--    Харвестер с этой же даты пишет raw_metadata в том же сокращённом виде.
-- 2. dc:date у многих OJS — дата загрузки статьи / переезда платформы, а не выхода номера
--    («Vol. 6 No. 1 (2019)» с dc:date 2025-06-25). У ~21.5k статей в 95 журналах год
--    в dc:source раньше года publication_date. Берём год выпуска (1 января), исходная
--    дата — raw_metadata.date_original, признак — raw_metadata.date_from_issue.
--
-- Идемпотентно: обработанные строки помечены raw_metadata.slim и пропускаются.
-- Пока база в read-only, это применялось вручную в SQL Editor порциями (тот же запрос
-- с «limit 10000» в batch и VACUUM между порциями); повторный db push ничего не изменит.

set local statement_timeout = '60min';

with batch as (
  select id
  from articles
  where raw_metadata is not null
    and not (raw_metadata ? 'slim')
), calc as (
  select a.id,
         (select min(m[1]::int)
            from regexp_matches(coalesce(a.raw_metadata->>'source', ''), '\((\d{4})\)', 'g') m
           where m[1]::int between 1950 and 2030) as src_year,
         (select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
            from jsonb_each(a.raw_metadata) e
           where e.key in ('source', 'date', 'title_kk', 'issue_url', 'galley_url', 'pdf_page', 'toc_page',
                           'verified', 'date_approximate', 'volume_inferred', 'abstract_on_source',
                           'date_from_issue', 'date_original')) as kept
  from articles a
  join batch b on b.id = a.id
)
update articles a
set publication_date = case
      when c.src_year < extract(year from a.publication_date) then make_date(c.src_year, 1, 1)
      else a.publication_date
    end,
    raw_metadata = c.kept
      || jsonb_build_object('slim', true)
      || case
           when c.src_year < extract(year from a.publication_date)
             then jsonb_build_object('date_from_issue', true, 'date_original', to_char(a.publication_date, 'YYYY-MM-DD'))
           else '{}'::jsonb
         end
from calc c
where a.id = c.id;
