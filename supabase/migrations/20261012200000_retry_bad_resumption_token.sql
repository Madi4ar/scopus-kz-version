-- Харвестер теперь сам начинает журнал заново, если сайт отклонил сохранённый
-- resumptionToken (badResumptionToken), вместо ошибки и паузы на 20 часов.
-- Журналы, уже упавшие так до деплоя исправления, снимаем с паузы — токен у них
-- сброшен, ближайший cron начнёт их с начала.
update journals
set harvest_error = null,
    harvest_error_at = null,
    harvest_resumption_token = null
where harvest_error ilike '%badResumptionToken%';
