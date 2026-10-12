-- Харвестер (Edge Function harvest-journals, ключ service_role) пишет в articles
-- страницу OAI-PMH (до ~100 записей с аннотациями) одним upsert'ом. У service_role
-- не было своего statement_timeout, действовал общий authenticator = 8s, и часть
-- upsert'ов падала по таймауту (16 журналов так и не собрались ни разу, среди них
-- «Өрлеу. Үздіксіз білім жаршысы»). Обычная пачка из 100 строк пишется за 0.4–2s;
-- таймауты — редкие всплески (вероятно, слив pending list GIN-индексов по
-- search_vector при 4 параллельных воркерах).
--
-- service_role используется только сервером (харвестер, cron), посетители сайта
-- ходят под anon с прежним лимитом 3s.

alter role service_role set statement_timeout = '60s';

-- Журналы, упавшие на таймауте записи, иначе ждали бы 20 часов до следующей попытки
-- (см. REFRESH_AFTER_HOURS в харвестере) — снимаем паузу, их подберёт ближайший cron.
update journals
set harvest_error = null,
    harvest_error_at = null
where harvest_error ilike '%statement timeout%';

-- PostgREST перечитывает настройки ролей по этому сигналу
notify pgrst, 'reload config';
