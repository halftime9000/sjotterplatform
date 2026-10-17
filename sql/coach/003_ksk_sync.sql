-- Sjotter · Coach & Speler · doorlopende synchronisatie vanuit het KSK-spelersplatform
--
-- Richting: KSK  ->  Sjotter (alleen lezen in KSK, nooit schrijven).
-- Zolang de spelers het oude platform gebruiken, volgt de Sjotter-ploeg automatisch:
--   nieuwe of gewijzigde spelers, fiches, wedstrijden, opstellingen, uitslagen en evaluaties.
--
-- Regels:
--   * Enkel records die uit KSK komen worden bijgewerkt (vaste id's, zelfde als bij de migratie).
--   * Wat je in Sjotter zelf aanmaakt (ploeginstellingen, logo, leden, eigen wedstrijden) blijft onaangeroerd.
--   * Profielen worden samengevoegd: KSK-velden winnen, velden die enkel in Sjotter bestaan blijven.
--   * Niets wordt verwijderd. Verdwijnt iets in KSK, dan blijft het in Sjotter staan.
--   * eval_open van een bestaande wedstrijd wordt niet overschreven.
--
-- Veilig om meerdere keren uit te voeren.

create table if not exists public.cs_ksk_sync_log (
  id        bigint generated always as identity primary key,
  ploeg_id  uuid not null references public.cs_ploegen(id) on delete cascade,
  tijd      timestamptz not null default now(),
  ok        boolean not null,
  bron      text,
  telling   jsonb not null default '{}'::jsonb,
  fout      text
);
create index if not exists cs_ksk_sync_log_ploeg_idx on public.cs_ksk_sync_log(ploeg_id, tijd desc);
alter table public.cs_ksk_sync_log enable row level security;
revoke all on public.cs_ksk_sync_log from anon, authenticated;
grant select on public.cs_ksk_sync_log to authenticated;
drop policy if exists cs_ksk_sync_log_lezen on public.cs_ksk_sync_log;
create policy cs_ksk_sync_log_lezen on public.cs_ksk_sync_log for select to authenticated
  using (cs_is_coach(ploeg_id));

-- p = { ploeg_id, bron, spelers: [...], wedstrijden: [...], evaluaties: [...] }
create or replace function public.cs_ksk_sync_toepassen(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ploeg uuid := (p->>'ploeg_id')::uuid;
  v_eigenaar uuid;
  r jsonb;
  is_nieuw boolean;
  t jsonb := '{"spelers_nieuw":0,"spelers_bij":0,"fiches_bij":0,"wedstrijden_nieuw":0,"wedstrijden_bij":0,"evaluaties_nieuw":0,"evaluaties_bij":0,"overgeslagen":0}'::jsonb;
  n int;
begin
  select eigenaar into v_eigenaar from cs_ploegen where id = v_ploeg;
  if v_eigenaar is null then raise exception 'Ploeg % bestaat niet in Sjotter', v_ploeg; end if;
  -- handelen namens de eigenaar (coach), zoals bij de migratie
  perform set_config('request.jwt.claim.sub', v_eigenaar::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_eigenaar, 'role', 'authenticated')::text, true);

  -- spelers
  for r in select value from jsonb_array_elements(coalesce(p->'spelers', '[]')) loop
    if exists (select 1 from cs_spelers where id = (r->>'id')::uuid and ploeg_id <> v_ploeg) then
      t := jsonb_set(t, '{overgeslagen}', to_jsonb((t->>'overgeslagen')::int + 1)); continue;
    end if;
    insert into cs_spelers as s (id, ploeg_id, voornaam, naam, rugnummer, is_keeper, actief)
    values ((r->>'id')::uuid, v_ploeg, r->>'voornaam', coalesce(r->>'naam', ''), (r->>'rugnummer')::smallint,
            coalesce((r->>'is_keeper')::boolean, false), coalesce((r->>'actief')::boolean, true))
    on conflict (id) do update set voornaam = excluded.voornaam, naam = excluded.naam, rugnummer = excluded.rugnummer,
                                   is_keeper = excluded.is_keeper, actief = excluded.actief
      where (s.voornaam, s.naam, s.rugnummer, s.is_keeper, s.actief)
            is distinct from (excluded.voornaam, excluded.naam, excluded.rugnummer, excluded.is_keeper, excluded.actief)
    returning (xmax = 0) into is_nieuw;
    if found then
      t := jsonb_set(t, case when is_nieuw then '{spelers_nieuw}' else '{spelers_bij}' end::text[],
                     to_jsonb((t->>(case when is_nieuw then 'spelers_nieuw' else 'spelers_bij' end))::int + 1));
    end if;

    if r ? 'profiel' then
      insert into cs_speler_profiel as f (speler_id, ploeg_id, data)
      values ((r->>'id')::uuid, v_ploeg, r->'profiel')
      on conflict (speler_id) do update set data = f.data || excluded.data
        where f.data || excluded.data is distinct from f.data;
      get diagnostics n = row_count;
      if n > 0 then t := jsonb_set(t, '{fiches_bij}', to_jsonb((t->>'fiches_bij')::int + 1)); end if;
    end if;
  end loop;

  -- wedstrijden
  for r in select value from jsonb_array_elements(coalesce(p->'wedstrijden', '[]')) loop
    if exists (select 1 from cs_wedstrijden where id = (r->>'id')::uuid and ploeg_id <> v_ploeg) then
      t := jsonb_set(t, '{overgeslagen}', to_jsonb((t->>'overgeslagen')::int + 1)); continue;
    end if;
    insert into cs_wedstrijden as w (id, ploeg_id, datum, tegenstander, thuis_uit, opstelling, scores, eval_open)
    values ((r->>'id')::uuid, v_ploeg, (r->>'datum')::date, r->>'tegenstander', r->>'thuis_uit',
            coalesce(r->'opstelling', '{}'), coalesce(r->'scores', '{}'), true)
    on conflict (id) do update set datum = excluded.datum, tegenstander = excluded.tegenstander, thuis_uit = excluded.thuis_uit,
                                   opstelling = excluded.opstelling, scores = excluded.scores
      where (w.datum, w.tegenstander, w.thuis_uit, w.opstelling, w.scores)
            is distinct from (excluded.datum, excluded.tegenstander, excluded.thuis_uit, excluded.opstelling, excluded.scores)
    returning (xmax = 0) into is_nieuw;
    if found then
      t := jsonb_set(t, case when is_nieuw then '{wedstrijden_nieuw}' else '{wedstrijden_bij}' end::text[],
                     to_jsonb((t->>(case when is_nieuw then 'wedstrijden_nieuw' else 'wedstrijden_bij' end))::int + 1));
    end if;
  end loop;

  -- evaluaties
  for r in select value from jsonb_array_elements(coalesce(p->'evaluaties', '[]')) loop
    if not exists (select 1 from cs_wedstrijden where id = (r->>'wedstrijd_id')::uuid and ploeg_id = v_ploeg)
       or not exists (select 1 from cs_spelers where id = (r->>'speler_id')::uuid and ploeg_id = v_ploeg) then
      t := jsonb_set(t, '{overgeslagen}', to_jsonb((t->>'overgeslagen')::int + 1)); continue;
    end if;
    begin
      insert into cs_evaluaties as e (wedstrijd_id, ploeg_id, speler_id, antwoorden, ratings, motm, weak_link, ingediend)
      values ((r->>'wedstrijd_id')::uuid, v_ploeg, (r->>'speler_id')::uuid, coalesce(r->'antwoorden', '{}'), coalesce(r->'ratings', '{}'),
              (r->>'motm')::uuid, (r->>'weak_link')::uuid, coalesce((r->>'ingediend')::boolean, false))
      on conflict (wedstrijd_id, speler_id) do update set antwoorden = excluded.antwoorden, ratings = excluded.ratings,
             motm = excluded.motm, weak_link = excluded.weak_link, ingediend = excluded.ingediend
        where (e.antwoorden, e.ratings, e.motm, e.weak_link, e.ingediend)
              is distinct from (excluded.antwoorden, excluded.ratings, excluded.motm, excluded.weak_link, excluded.ingediend)
      returning (xmax = 0) into is_nieuw;
      if found then
        t := jsonb_set(t, case when is_nieuw then '{evaluaties_nieuw}' else '{evaluaties_bij}' end::text[],
                       to_jsonb((t->>(case when is_nieuw then 'evaluaties_nieuw' else 'evaluaties_bij' end))::int + 1));
      end if;
    exception when others then
      t := jsonb_set(t, '{overgeslagen}', to_jsonb((t->>'overgeslagen')::int + 1));
    end;
  end loop;

  insert into cs_ksk_sync_log (ploeg_id, ok, bron, telling) values (v_ploeg, true, p->>'bron', t);
  return t;
end $$;

create or replace function public.cs_ksk_sync_fout(p_ploeg uuid, p_bron text, p_fout text)
returns void language sql security definer set search_path = public as $$
  insert into cs_ksk_sync_log (ploeg_id, ok, bron, fout) values (p_ploeg, false, p_bron, left(p_fout, 2000));
$$;

revoke all on function public.cs_ksk_sync_toepassen(jsonb) from public, anon, authenticated;
revoke all on function public.cs_ksk_sync_fout(uuid, text, text) from public, anon, authenticated;
grant execute on function public.cs_ksk_sync_toepassen(jsonb) to service_role;
grant execute on function public.cs_ksk_sync_fout(uuid, text, text) to service_role;

-- logboek beperken tot de laatste 500 runs per ploeg
create or replace function public.cs_ksk_sync_log_opruimen()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from cs_ksk_sync_log where ploeg_id = new.ploeg_id and id not in
    (select id from cs_ksk_sync_log where ploeg_id = new.ploeg_id order by id desc limit 500);
  return null;
end $$;
drop trigger if exists cs_ksk_sync_log_opruimen on public.cs_ksk_sync_log;
create trigger cs_ksk_sync_log_opruimen after insert on public.cs_ksk_sync_log
  for each row execute function public.cs_ksk_sync_log_opruimen();

-- geheim voor de automatische aanroep (pg_cron -> Edge Function); enkel leesbaar voor de server
create table if not exists public.cs_ksk_sync_instelling (
  id      int primary key default 1 check (id = 1),
  geheim  text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
);
insert into public.cs_ksk_sync_instelling (id) values (1) on conflict (id) do nothing;
alter table public.cs_ksk_sync_instelling enable row level security;
revoke all on public.cs_ksk_sync_instelling from public, anon, authenticated;
grant select on public.cs_ksk_sync_instelling to service_role;
