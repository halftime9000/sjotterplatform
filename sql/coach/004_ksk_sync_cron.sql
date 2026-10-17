-- Sjotter · KSK-synchronisatie automatisch elke 15 minuten
-- Voer dit uit NADAT de Edge Function "ksk-sync" gedeployed is (zie README).
-- Stoppen kan altijd met:  select cron.unschedule('ksk-sync');

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'ksk-sync',
  '*/15 * * * *',
  $job$
  select net.http_post(
    url     := 'https://equmwyvxbjjocwetwfcw.supabase.co/functions/v1/ksk-sync',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-sync-secret', (select geheim from public.cs_ksk_sync_instelling where id = 1)),
    body    := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $job$
);
