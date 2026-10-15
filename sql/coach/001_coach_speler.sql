-- =====================================================================
-- Sjotter · Coach & Speler · migratie 001
-- Uitvoeren in Supabase → SQL Editor (project equmwyvxbjjocwetwfcw).
-- Veilig om opnieuw uit te voeren: alles gebruikt "if not exists" /
-- "create or replace" / "drop policy if exists".
-- Alle tabellen beginnen met cs_ zodat ze nooit botsen met de
-- bestaande Sjotter-tabellen (teams, wedstrijden, ...).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Hulpfunctie: leesbare teamcode (zonder 0/O/1/I)
-- ---------------------------------------------------------------------
create or replace function public.cs_code_genereren()
returns text language plpgsql volatile set search_path = public as $$
declare
  tekens constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  c text;
begin
  loop
    c := '';
    for i in 1..6 loop
      c := c || substr(tekens, 1 + floor(random() * length(tekens))::int, 1);
    end loop;
    exit when not exists (select 1 from public.cs_ploegen where code = c);
  end loop;
  return c;
end $$;

-- ---------------------------------------------------------------------
-- Tabellen
-- ---------------------------------------------------------------------
create table if not exists public.cs_ploegen (
  id            uuid primary key default gen_random_uuid(),
  naam          text not null check (char_length(naam) between 2 and 80),
  club          text check (club is null or char_length(club) <= 80),
  categorie     text check (categorie is null or char_length(categorie) <= 30),
  seizoen       text not null default '2026-27' check (seizoen ~ '^\d{4}-\d{2}$'),
  formaat       smallint not null default 8 check (formaat in (2, 3, 5, 8, 11)),
  groepen       jsonb not null default '[{"id":"a","naam":"Groep A","kleur":"#F4C95D"}]'::jsonb
                check (jsonb_typeof(groepen) = 'array' and jsonb_array_length(groepen) between 1 and 6),
  weak_link_aan boolean not null default false,
  code          text unique,
  eigenaar      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at    timestamptz not null default now()
);

create table if not exists public.cs_spelers (
  id          uuid primary key default gen_random_uuid(),
  ploeg_id    uuid not null references public.cs_ploegen(id) on delete cascade,
  voornaam    text not null check (char_length(voornaam) between 1 and 60),
  naam        text not null default '' check (char_length(naam) <= 60),
  rugnummer   smallint check (rugnummer between 0 and 99),
  is_keeper   boolean not null default false,
  actief      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists cs_spelers_ploeg_idx on public.cs_spelers(ploeg_id);

-- Profiel apart: enkel coach en de speler zelf mogen dit zien.
create table if not exists public.cs_speler_profiel (
  speler_id        uuid primary key references public.cs_spelers(id) on delete cascade,
  ploeg_id         uuid not null references public.cs_ploegen(id) on delete cascade,
  data             jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  updated_at       timestamptz not null default now()
);
create index if not exists cs_profiel_ploeg_idx on public.cs_speler_profiel(ploeg_id);
alter table public.cs_speler_profiel drop column if exists coach_boodschap;

create table if not exists public.cs_leden (
  id                 uuid primary key default gen_random_uuid(),
  ploeg_id           uuid not null references public.cs_ploegen(id) on delete cascade,
  user_id            uuid not null references auth.users(id) on delete cascade,
  rol                text not null default 'speler' check (rol in ('coach', 'speler')),
  status             text not null default 'wacht' check (status in ('wacht', 'actief')),
  speler_id          uuid references public.cs_spelers(id) on delete set null,
  naam               text check (naam is null or char_length(naam) <= 80),
  email              text,
  created_at         timestamptz not null default now(),
  unique (ploeg_id, user_id)
);
create index if not exists cs_leden_user_idx on public.cs_leden(user_id);
alter table public.cs_leden drop column if exists ouder_toestemming;

create table if not exists public.cs_wedstrijden (
  id           uuid primary key default gen_random_uuid(),
  ploeg_id     uuid not null references public.cs_ploegen(id) on delete cascade,
  datum        date not null,
  tegenstander text not null check (char_length(tegenstander) between 1 and 80),
  thuis_uit    text not null default 'thuis' check (thuis_uit in ('thuis', 'uit')),
  opstelling   jsonb not null default '{}'::jsonb check (jsonb_typeof(opstelling) = 'object'),
  scores       jsonb not null default '{}'::jsonb check (jsonb_typeof(scores) = 'object'),
  eval_open    boolean not null default true,
  created_at   timestamptz not null default now()
);
create index if not exists cs_wedstrijden_ploeg_idx on public.cs_wedstrijden(ploeg_id, datum);
alter table public.cs_wedstrijden drop column if exists aanvang, drop column if exists locatie, drop column if exists notities;

create table if not exists public.cs_evaluaties (
  id            uuid primary key default gen_random_uuid(),
  wedstrijd_id  uuid not null references public.cs_wedstrijden(id) on delete cascade,
  ploeg_id      uuid not null references public.cs_ploegen(id) on delete cascade,
  speler_id     uuid not null references public.cs_spelers(id) on delete cascade,
  user_id       uuid default auth.uid() references auth.users(id) on delete set null,
  antwoorden    jsonb not null default '{}'::jsonb check (jsonb_typeof(antwoorden) = 'object'),
  ratings       jsonb not null default '{}'::jsonb check (jsonb_typeof(ratings) = 'object'),
  motm          uuid references public.cs_spelers(id) on delete set null,
  weak_link     uuid references public.cs_spelers(id) on delete set null,
  ingediend     boolean not null default false,
  updated_at    timestamptz not null default now(),
  unique (wedstrijd_id, speler_id)
);
create index if not exists cs_evaluaties_ploeg_idx on public.cs_evaluaties(ploeg_id);

-- (berichten zijn geschrapt: communicatie loopt via WhatsApp)
drop table if exists public.cs_berichten;

-- ---------------------------------------------------------------------
-- Rechten-hulpfuncties (security definer → geen RLS-lussen)
-- ---------------------------------------------------------------------
create or replace function public.cs_is_lid(p uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from cs_leden
                 where ploeg_id = p and user_id = auth.uid() and status = 'actief');
$$;

create or replace function public.cs_is_coach(p uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from cs_leden
                 where ploeg_id = p and user_id = auth.uid() and status = 'actief' and rol = 'coach');
$$;

create or replace function public.cs_heeft_aanvraag(p uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from cs_leden where ploeg_id = p and user_id = auth.uid());
$$;

create or replace function public.cs_is_mijn_speler(s uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from cs_leden
                 where speler_id = s and user_id = auth.uid() and status = 'actief');
$$;

-- ---------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------

-- Nieuwe ploeg: code geven en de maker als coach toevoegen.
create or replace function public.cs_ploeg_voor_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.code is null then new.code := cs_code_genereren(); end if;
  if auth.uid() is not null then new.eigenaar := auth.uid(); end if;
  return new;
end $$;

create or replace function public.cs_ploeg_na_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into cs_leden (ploeg_id, user_id, rol, status, naam, email)
  select new.id, new.eigenaar, 'coach', 'actief',
         coalesce(u.raw_user_meta_data->>'naam', split_part(u.email, '@', 1)), u.email
  from auth.users u where u.id = new.eigenaar
  on conflict (ploeg_id, user_id) do nothing;
  return new;
end $$;

drop trigger if exists cs_ploeg_voor_insert on public.cs_ploegen;
create trigger cs_ploeg_voor_insert before insert on public.cs_ploegen
  for each row execute function public.cs_ploeg_voor_insert();
drop trigger if exists cs_ploeg_na_insert on public.cs_ploegen;
create trigger cs_ploeg_na_insert after insert on public.cs_ploegen
  for each row execute function public.cs_ploeg_na_insert();

-- Eigenaar en code kunnen niet zomaar gewijzigd worden.
create or replace function public.cs_ploeg_voor_update()
returns trigger language plpgsql set search_path = public as $$
begin
  new.eigenaar := old.eigenaar;
  new.id := old.id;
  return new;
end $$;
drop trigger if exists cs_ploeg_voor_update on public.cs_ploegen;
create trigger cs_ploeg_voor_update before update on public.cs_ploegen
  for each row execute function public.cs_ploeg_voor_update();

-- Leden: speler moet bij dezelfde ploeg horen; eigenaar blijft coach.
create or replace function public.cs_lid_controle()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.speler_id is not null and not exists
     (select 1 from cs_spelers where id = new.speler_id and ploeg_id = new.ploeg_id) then
    raise exception 'Speler hoort niet bij deze ploeg';
  end if;
  if tg_op = 'UPDATE' then
    new.user_id := old.user_id;
    new.ploeg_id := old.ploeg_id;
    if exists (select 1 from cs_ploegen where id = old.ploeg_id and eigenaar = old.user_id) then
      new.rol := 'coach';
      new.status := 'actief';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists cs_lid_controle on public.cs_leden;
create trigger cs_lid_controle before insert or update on public.cs_leden
  for each row execute function public.cs_lid_controle();

create or replace function public.cs_lid_niet_eigenaar_verwijderen()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from cs_ploegen where id = old.ploeg_id and eigenaar = old.user_id) then
    raise exception 'De eigenaar van de ploeg kan niet verwijderd worden';
  end if;
  return old;
end $$;
drop trigger if exists cs_lid_niet_eigenaar_verwijderen on public.cs_leden;
create trigger cs_lid_niet_eigenaar_verwijderen before delete on public.cs_leden
  for each row when (pg_trigger_depth() = 0)
  execute function public.cs_lid_niet_eigenaar_verwijderen();

-- Profiel: ploeg_id volgt altijd de speler.
create or replace function public.cs_profiel_controle()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select ploeg_id into new.ploeg_id from cs_spelers where id = new.speler_id;
  if new.ploeg_id is null then raise exception 'Onbekende speler'; end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists cs_profiel_controle on public.cs_speler_profiel;
create trigger cs_profiel_controle before insert or update on public.cs_speler_profiel
  for each row execute function public.cs_profiel_controle();

-- Evaluaties: alles controleren aan de serverkant.
create or replace function public.cs_evaluatie_controle()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  w  cs_wedstrijden%rowtype;
  p  cs_ploegen%rowtype;
  in_opstelling boolean;
  k text; v jsonb;
begin
  select * into w from cs_wedstrijden where id = new.wedstrijd_id;
  if not found then raise exception 'Onbekende wedstrijd'; end if;
  select * into p from cs_ploegen where id = w.ploeg_id;
  new.ploeg_id := w.ploeg_id;

  if not exists (select 1 from cs_spelers where id = new.speler_id and ploeg_id = w.ploeg_id) then
    raise exception 'Speler hoort niet bij deze ploeg';
  end if;

  if not cs_is_coach(w.ploeg_id) then
    if not w.eval_open then raise exception 'Evaluaties voor deze wedstrijd zijn gesloten'; end if;
    select exists (
      select 1 from jsonb_each(w.opstelling) g, jsonb_array_elements_text(g.value) s
      where s = new.speler_id::text
    ) into in_opstelling;
    if not in_opstelling then raise exception 'Je stond niet in de opstelling van deze wedstrijd'; end if;
    if tg_op = 'UPDATE' then new.user_id := old.user_id; else new.user_id := auth.uid(); end if;
  end if;

  -- ratings: { "<speler_id>": 1..10 }, niet voor jezelf
  for k, v in select * from jsonb_each(new.ratings) loop
    if jsonb_typeof(v) <> 'number' or (v::text)::numeric not between 1 and 10 then
      raise exception 'Score moet tussen 1 en 10 liggen';
    end if;
    if k = new.speler_id::text then raise exception 'Je kan jezelf niet scoren bij ploegmaats'; end if;
    if not exists (select 1 from cs_spelers where id::text = k and ploeg_id = w.ploeg_id) then
      raise exception 'Onbekende ploegmaat in de scores';
    end if;
  end loop;

  if new.motm is not null and not exists (select 1 from cs_spelers where id = new.motm and ploeg_id = w.ploeg_id) then
    raise exception 'Onbekende speler als man van de match';
  end if;
  if new.weak_link is not null and not exists (select 1 from cs_spelers where id = new.weak_link and ploeg_id = w.ploeg_id) then
    new.weak_link := null;
  end if;

  if new.motm = new.speler_id then raise exception 'Je kan jezelf niet als man van de match kiezen'; end if;
  if not p.weak_link_aan then new.weak_link := null; end if;
  if new.weak_link = new.speler_id then new.weak_link := null; end if;

  new.updated_at := now();
  return new;
end $$;
drop trigger if exists cs_evaluatie_controle on public.cs_evaluaties;
create trigger cs_evaluatie_controle before insert or update on public.cs_evaluaties
  for each row execute function public.cs_evaluatie_controle();

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
alter table public.cs_ploegen        enable row level security;
alter table public.cs_spelers        enable row level security;
alter table public.cs_speler_profiel enable row level security;
alter table public.cs_leden          enable row level security;
alter table public.cs_wedstrijden    enable row level security;
alter table public.cs_evaluaties     enable row level security;

-- ploegen
drop policy if exists cs_ploegen_lezen on public.cs_ploegen;
create policy cs_ploegen_lezen on public.cs_ploegen for select to authenticated
  using (cs_heeft_aanvraag(id));
drop policy if exists cs_ploegen_maken on public.cs_ploegen;
create policy cs_ploegen_maken on public.cs_ploegen for insert to authenticated
  with check (eigenaar = auth.uid());
drop policy if exists cs_ploegen_wijzigen on public.cs_ploegen;
create policy cs_ploegen_wijzigen on public.cs_ploegen for update to authenticated
  using (cs_is_coach(id)) with check (cs_is_coach(id));
drop policy if exists cs_ploegen_verwijderen on public.cs_ploegen;
create policy cs_ploegen_verwijderen on public.cs_ploegen for delete to authenticated
  using (eigenaar = auth.uid());

-- spelers (namen zichtbaar voor de hele ploeg, beheer door coach)
drop policy if exists cs_spelers_lezen on public.cs_spelers;
create policy cs_spelers_lezen on public.cs_spelers for select to authenticated
  using (cs_is_lid(ploeg_id));
drop policy if exists cs_spelers_beheer on public.cs_spelers;
create policy cs_spelers_beheer on public.cs_spelers for all to authenticated
  using (cs_is_coach(ploeg_id)) with check (cs_is_coach(ploeg_id));

-- profiel (coach + speler zelf)
drop policy if exists cs_profiel_lezen on public.cs_speler_profiel;
create policy cs_profiel_lezen on public.cs_speler_profiel for select to authenticated
  using (cs_is_coach(ploeg_id) or cs_is_mijn_speler(speler_id));
drop policy if exists cs_profiel_maken on public.cs_speler_profiel;
create policy cs_profiel_maken on public.cs_speler_profiel for insert to authenticated
  with check (cs_is_coach((select ploeg_id from cs_spelers where id = speler_id)) or cs_is_mijn_speler(speler_id));
drop policy if exists cs_profiel_wijzigen on public.cs_speler_profiel;
create policy cs_profiel_wijzigen on public.cs_speler_profiel for update to authenticated
  using (cs_is_coach(ploeg_id) or cs_is_mijn_speler(speler_id))
  with check (cs_is_coach(ploeg_id) or cs_is_mijn_speler(speler_id));
drop policy if exists cs_profiel_verwijderen on public.cs_speler_profiel;
create policy cs_profiel_verwijderen on public.cs_speler_profiel for delete to authenticated
  using (cs_is_coach(ploeg_id));

-- leden (aansluiten gebeurt via cs_aansluiten, niet rechtstreeks)
drop policy if exists cs_leden_lezen on public.cs_leden;
create policy cs_leden_lezen on public.cs_leden for select to authenticated
  using (user_id = auth.uid() or cs_is_coach(ploeg_id));
drop policy if exists cs_leden_wijzigen on public.cs_leden;
create policy cs_leden_wijzigen on public.cs_leden for update to authenticated
  using (cs_is_coach(ploeg_id)) with check (cs_is_coach(ploeg_id));
drop policy if exists cs_leden_verwijderen on public.cs_leden;
create policy cs_leden_verwijderen on public.cs_leden for delete to authenticated
  using (cs_is_coach(ploeg_id) or user_id = auth.uid());

-- wedstrijden
drop policy if exists cs_wedstrijden_lezen on public.cs_wedstrijden;
create policy cs_wedstrijden_lezen on public.cs_wedstrijden for select to authenticated
  using (cs_is_lid(ploeg_id));
drop policy if exists cs_wedstrijden_beheer on public.cs_wedstrijden;
create policy cs_wedstrijden_beheer on public.cs_wedstrijden for all to authenticated
  using (cs_is_coach(ploeg_id)) with check (cs_is_coach(ploeg_id));

-- evaluaties (speler ziet enkel de eigen, coach alles)
drop policy if exists cs_evaluaties_lezen on public.cs_evaluaties;
create policy cs_evaluaties_lezen on public.cs_evaluaties for select to authenticated
  using (cs_is_coach(ploeg_id) or cs_is_mijn_speler(speler_id));
drop policy if exists cs_evaluaties_maken on public.cs_evaluaties;
create policy cs_evaluaties_maken on public.cs_evaluaties for insert to authenticated
  with check (cs_is_mijn_speler(speler_id));
drop policy if exists cs_evaluaties_wijzigen on public.cs_evaluaties;
create policy cs_evaluaties_wijzigen on public.cs_evaluaties for update to authenticated
  using (cs_is_mijn_speler(speler_id) or cs_is_coach(ploeg_id))
  with check (cs_is_mijn_speler(speler_id) or cs_is_coach(ploeg_id));
drop policy if exists cs_evaluaties_verwijderen on public.cs_evaluaties;
create policy cs_evaluaties_verwijderen on public.cs_evaluaties for delete to authenticated
  using (cs_is_coach(ploeg_id));

-- ---------------------------------------------------------------------
-- RPC's
-- ---------------------------------------------------------------------

-- Ploeg opzoeken via code (ook zonder login, om te tonen bij welke ploeg je aansluit)
create or replace function public.cs_ploeg_via_code(p_code text)
returns table (naam text, club text, categorie text, seizoen text)
language sql stable security definer set search_path = public as $$
  select naam, club, categorie, seizoen from cs_ploegen
  where code = upper(trim(p_code)) limit 1;
$$;

-- Aansluiten bij een ploeg als speler. Status 'wacht' tot de coach goedkeurt.
drop function if exists public.cs_aansluiten(text, text, boolean);
create or replace function public.cs_aansluiten(p_code text, p_naam text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  pl cs_ploegen%rowtype;
begin
  if auth.uid() is null then raise exception 'Log eerst in'; end if;
  if p_naam is null or char_length(trim(p_naam)) < 2 then raise exception 'Vul je naam in'; end if;
  select * into pl from cs_ploegen where code = upper(trim(p_code));
  if not found then raise exception 'Deze teamcode bestaat niet'; end if;

  insert into cs_leden (ploeg_id, user_id, rol, status, naam, email)
  select pl.id, auth.uid(), 'speler', 'wacht', left(trim(p_naam), 80), u.email
  from auth.users u where u.id = auth.uid()
  on conflict (ploeg_id, user_id) do update set naam = excluded.naam;
  return pl.id;
end $$;

-- Nieuwe teamcode (bv. als de oude te veel rondgaat)
create or replace function public.cs_code_vernieuwen(p_ploeg uuid)
returns text language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if not cs_is_coach(p_ploeg) then raise exception 'Enkel de coach kan dit'; end if;
  c := cs_code_genereren();
  update cs_ploegen set code = c where id = p_ploeg;
  return c;
end $$;

-- ---------------------------------------------------------------------
-- Rechten
-- ---------------------------------------------------------------------
revoke all on public.cs_ploegen, public.cs_spelers, public.cs_speler_profiel, public.cs_leden,
              public.cs_wedstrijden, public.cs_evaluaties from anon;
grant select, insert, update, delete on public.cs_ploegen, public.cs_spelers, public.cs_speler_profiel,
      public.cs_leden, public.cs_wedstrijden, public.cs_evaluaties to authenticated;

revoke execute on function public.cs_code_genereren(), public.cs_is_lid(uuid), public.cs_is_coach(uuid),
       public.cs_is_mijn_speler(uuid), public.cs_heeft_aanvraag(uuid), public.cs_ploeg_via_code(text),
       public.cs_aansluiten(text, text), public.cs_code_vernieuwen(uuid) from public, anon;
grant execute on function public.cs_is_lid(uuid), public.cs_is_coach(uuid), public.cs_is_mijn_speler(uuid), public.cs_heeft_aanvraag(uuid),
      public.cs_ploeg_via_code(text), public.cs_aansluiten(text, text),
      public.cs_code_vernieuwen(uuid) to authenticated;
grant execute on function public.cs_ploeg_via_code(text) to anon;
