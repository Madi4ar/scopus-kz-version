-- Ежедневная проверка цитирований через check-citations, запускается в 04:00 UTC
-- (через час после харвеста в 03:00), чтобы новые статьи быстро попадали в очередь
-- на проверку. Использует тот же секрет из Vault, что и харвестер.
select cron.schedule(
  'check-citations-daily',
  '0 4 * * *',
  $$
  select net.http_post(
    url := 'https://bsnhhwpogtbwahyeapop.supabase.co/functions/v1/check-citations',
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
