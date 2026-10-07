-- Ежедневный автоматический харвест OAI-PMH через pg_cron + pg_net.
-- Секретный ключ для вызова Edge Function хранится в Supabase Vault
-- (secret name: 'harvest_journals_key') и НЕ коммитится в эту миграцию.

create extension if not exists pg_cron;
create extension if not exists pg_net;

grant usage on schema cron to postgres;

-- cron.schedule обновляет существующий job при совпадении jobname, поэтому миграция идемпотентна.
select cron.schedule(
  'harvest-journals-daily',
  '0 3 * * *', -- 03:00 UTC каждый день
  $$
  select net.http_post(
    url := 'https://bsnhhwpogtbwahyeapop.supabase.co/functions/v1/harvest-journals',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'harvest_journals_key'
      ),
      'apikey', (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'harvest_journals_key'
      )
    ),
    body := '{}'::jsonb
  );
  $$
);
