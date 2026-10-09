# Реестр журналов Казахстана — MVP

Пилотная поисковая платформа по 3 научным журналам РК (ENU Philology, Buketov Philology,
KazNU Journalism), построенная по схеме из `kazakhstan_journals_registry_pilot.md`:

```
Journal website → OAI-PMH → Supabase (Postgres + Edge Function) → Search (tsvector) → статическая страница
```

Без собственного бэкенда: Supabase Postgres хранит данные и отдаёт их напрямую через
PostgREST, харвестинг метаданных — Edge Function на расписании (`pg_cron`), поиск —
SQL-функция `search_articles`, фронтенд — статический HTML, читающий Supabase напрямую.

## Проект Supabase

- Project ref: `bsnhhwpogtbwahyeapop` ("Madi4ar's Project")
- Dashboard: https://supabase.com/dashboard/project/bsnhhwpogtbwahyeapop

## Структура

```
supabase/
  migrations/
    20261007123519_init_schema.sql   — таблицы journals/articles, FTS, RLS, search_articles(), сид 3 журналов
    20261007124500_harvest_cron.sql  — pg_cron job (ежедневно 03:00 UTC), читает ключ из Vault
  functions/
    harvest-journals/index.ts        — Edge Function: харвестит OAI-PMH, upsert в articles
```

## Таблицы

- `journals` — реестр журналов (id, name, publisher, base_url, oai_endpoint, issn, язык, ...)
- `articles` — статьи (title, authors, abstract, doi, publication_date, volume/issue/pages,
  article_url, pdf_url, metadata_quality, raw_metadata jsonb, ...), уникальность по
  `(journal_id, oai_identifier)` для безопасного повторного харвеста
- `search_articles(query text, limit_count int)` — RPC для полнотекстового поиска
  (`tsvector` с весами: title > authors/keywords > abstract)

RLS: публичное чтение (`select`) для всех, запись — только через Edge Function с
service_role ключом (он лежит в Supabase Vault как секрет `harvest_journals_key`,
не в коде и не в git).

## Харвестер (`harvest-journals`)

Для каждого активного журнала с `oai_endpoint`:

1. Делает `ListRecords` (`metadataPrefix=oai_dc`), постранично через `resumptionToken`.
2. При повторном запуске использует `journals.last_crawled_at` как `from` — тянет только
   новое/обновлённое (минус 1 день буфера на пересечение).
3. Нормализует Dublin Core → строки `articles`, определяет `doi`/`pdf_url`/`article_url`
   из списка `dc:identifier`, вытаскивает volume/issue/pages из `dc:source` регуляркой.
4. Upsert по `(journal_id, oai_identifier)`.
5. Обновляет `journals.last_crawled_at`.

Задеплоить изменения функции:

```bash
supabase functions deploy harvest-journals
```

Запустить вручную (нужен `secret`-ключ проекта, Project Settings → API Keys):

```bash
curl -X POST "https://bsnhhwpogtbwahyeapop.supabase.co/functions/v1/harvest-journals" \
  -H "Authorization: Bearer <secret key>" \
  -H "apikey: <secret key>"
```

Автоматический запуск — `pg_cron` job `harvest-journals-daily`, каждый день в 03:00 UTC.
Проверить/изменить расписание:

```sql
select * from cron.job where jobname = 'harvest-journals-daily';
select cron.alter_job((select jobid from cron.job where jobname='harvest-journals-daily'), schedule := '0 */6 * * *');
```

## Фронтенд (поиск)

Статическая HTML-страница (опубликована как Claude Artifact), ходит в Supabase напрямую
через `sb_publishable_...` ключ (публичный, безопасен в клиентском коде) — без своего API.
Исходник: см. артефакт «Реестр журналов РК».

## Текущий статус пилота (на 2026-10-07)

| Журнал | OAI-PMH endpoint | Статей собрано |
|---|---|---|
| ENU Philology | `bulphil.enu.kz/index.php/main/oai` | 684 |
| Buketov Philology | `philology-vestnik.buketov.edu.kz/index.php/index/oai` | 553 |
| KazNU Journalism | `bulletin-journalism.kaznu.kz/index.php/1-journal/ru/oai` | 1357 |

Все три OAI-PMH endpoint-а подтверждены вживую (не предположение из .md, а реальный
`verb=ListRecords&metadataPrefix=oai_dc`). У KazNU endpoint требует локаль в пути (`/ru/oai`).

## Перечень КОКСНВО (с 2026-10-09)

Миграция `20261009120000_import_koksnvo_journals.sql` добавляет в реестр все журналы из
«Журналы_со_ссылками.xlsx» (Списки 1/2/3 + журналы ВСУЗов, `koksnvo_list = 4`): 223 новых
журнала, у 147 OAI-PMH endpoint найден и проверен вживую (`Identify` + `ListRecords`).
Остальные добавлены с `crawler_type = 'manual'` и без `oai_endpoint` — в каталоге видны,
харвестер их пропускает; причина в `journals.notes`.

- Сайты на Elpub (`/jour/oai`) и ещё пара отвечают только браузерному User-Agent —
  для них `oai_browser_user_agent = true`.
- `ojs.egi.kz`, `mathjournal.kz`, `bulecon.enu.kz`: `Identify` работает, `ListRecords` отдаёт
  HTTP 500 на стороне сайта — ошибка будет видна в `journals.harvest_error`.
- Харвестер теперь работает порциями (бюджет ~90 с на вызов, 4 журнала параллельно,
  продолжение по сохранённому `harvest_resumption_token`), cron — каждые 10 минут
  (`20261009121000_harvest_cron_every_10min.sql`); каждый журнал обновляется не чаще раза в 20 ч.

## Что дальше (не входит в MVP)

- `pdf_url` сейчас почти всегда `null` — OJS oai_dc отдаёт только landing-страницу статьи,
  не прямую ссылку на PDF; для полнотекстового индекса нужен отдельный проход по
  `article_url` → поиск ссылки на галлею.
- Полнотекстовая индексация PDF и построение citation graph (см. `references`/`relation` в
  исходном .md) — не реализовано.
- `robots.txt` / частота обновления для HTML-фоллбека — не нужны, так как OAI-PMH у всех
  трёх журналов рабочий.
