#!/usr/bin/env python3
"""
KSK-spelersplatform  ->  Sjotter Coach & Speler

Gebruik:
    python3 ksk_naar_sjotter.py ksk-export.json coach@email.be [ploegnaam] > import.sql

- Leest de JSON-export van het KSK-project (zie EXPORT_SQL hieronder).
- Schrijft één SQL-bestand voor het Sjotter-project (SQL Editor).
- Niets wordt weggegooid: elk origineel record wordt bewaard
  (per speler in data._ksk, per evaluatie in antwoorden._ksk,
  en de volledige export in cs_import_archief).
- Het KSK-project zelf wordt nooit aangeraakt.
- Het resultaat bevat persoonsgegevens: NIET in git zetten.
"""
import json, sys, uuid, re, secrets

EXPORT_SQL = """
select json_build_object(
  'spelers',     (select coalesce(json_agg(t), '[]') from spelers t),
  'wedstrijden', (select coalesce(json_agg(t), '[]') from wedstrijden t),
  'evaluaties',  (select coalesce(json_agg(t), '[]') from match_evaluaties t),
  'svdm',        (select coalesce(json_agg(t), '[]') from speler_vd_maand t),
  'rollen',      (select coalesce(json_agg(t), '[]') from user_roles t)
)::text as export;
"""

NS = uuid.UUID("5b0c7e2a-1f3d-4c2b-9a77-6d3f1e0c4a11")   # vaste namespace: zelfde input -> zelfde uuid's
def uid(*parts): return str(uuid.uuid5(NS, "/".join(str(p) for p in parts)))

def leeg(v): return v is None or v == "" or v == [] or v == {}

def tekst(v, n=None):
    if leeg(v): return None
    v = str(v).strip()
    return v[:n] if n else v

def score(v):
    try:
        x = int(round(float(v)))
        return x if 1 <= x <= 10 else None
    except (TypeError, ValueError):
        return None

def ids(v):
    """lijst van speler-id's uit int[], jsonb of tekst"""
    if leeg(v): return []
    if isinstance(v, str):
        try: v = json.loads(v)
        except ValueError: v = re.findall(r"\d+", v)
    return [str(int(x)) for x in v if str(x).strip().lstrip("-").isdigit()]

def uitslag(raw, thuis_uit):
    if leeg(raw): return None
    m = re.match(r"^\s*(\d+)\s*[-–:]\s*(\d+)\s*$", str(raw))
    if not m: return None
    a, b = int(m.group(1)), int(m.group(2))
    uit = str(thuis_uit or "thuis").lower() == "uit"
    return {"wij": b, "zij": a} if uit else {"wij": a, "zij": b}

CAT = {"technisch": "technisch", "taktisch": "tactisch", "tactisch": "tactisch", "fysiek": "fysiek", "mentaal": "mentaal"}

def profiel(d, email):
    d = d or {}
    p = {"sterk": {}, "werk": {}, "gegevens": {}}
    for soort_ksk, soort in (("sterke", "sterk"), ("werk", "werk")):
        for c_ksk, c in CAT.items():
            v = d.get(f"{soort_ksk}_{c_ksk}")
            if isinstance(v, list) and v:
                p[soort].setdefault(c, [])
                p[soort][c] += [str(x) for x in v if str(x) not in p[soort][c]]
    for k_ksk, k in (("pv-fav-pos", "pos_fav"), ("pv-ges-pos", "pos_meest")):
        if isinstance(d.get(k_ksk), list) and d[k_ksk]: p[k] = [str(x) for x in d[k_ksk]]
    for k_ksk, k in (("voorkeurspoot", "voet"), ("vorige_clubs", "vorige_clubs"), ("fav_ploeg", "fav_ploeg"),
                     ("rolmodel", "fav_speler"), ("waarom_voetbal", "leuk"), ("droomscenario", "droom"),
                     ("herinnering", "herinnering"), ("bf_niveau", "goed"), ("bf_doel", "beter"), ("verw_trainer", "verwacht")):
        if tekst(d.get(k_ksk)): p[k] = tekst(d.get(k_ksk))
    if p.get("voet"): p["voet"] = p["voet"].capitalize()
    for k in ("zb_inzet", "zb_wedstrijd", "zb_gedrag", "zb_coach"):
        if score(d.get(k)): p[k] = score(d.get(k))
    for k_ksk, k in (("geboortedatum", "geboortedatum"), ("gsm_speler", "gsm"), ("school_naam", "school"),
                     ("jaren_actief", "jaren"), ("allergie", "allergie"), ("medicatie", "medicatie"), ("medisch_info", "medisch")):
        if tekst(d.get(k_ksk)): p["gegevens"][k] = tekst(d.get(k_ksk), 500)
    afw = d.get("unavail_dates")
    if isinstance(afw, list): p["afwezig"] = sorted({str(x)[:10] for x in afw if re.match(r"^\d{4}-\d{2}-\d{2}", str(x))})
    if email: p["ksk_email"] = email
    p["_ksk"] = d          # alles, ook velden zonder plaats in Sjotter
    return p

EVAL_MAP = [
    ("eigen_mentaliteit", "eigen_mentaliteit", True), ("eigen_mentaliteit_opm", "eigen_mentaliteit_opm", False),
    ("eigen_b_plus", "eigen_bplus", True), ("eigen_b_plus_opmerking", "eigen_bplus_opm", False),
    ("eigen_b_min", "eigen_bmin", True), ("eigen_b_min_opmerking", "eigen_bmin_opm", False),
    ("eigen_trans_bp_bm", "eigen_t1", True), ("eigen_trans_bp_bm_opmerking", "eigen_t1_opm", False),
    ("eigen_trans_bm_bp", "eigen_t2", True), ("eigen_trans_bm_bp_opmerking", "eigen_t2_opm", False),
    ("keeper_doellijn", "k_doellijn", True), ("keeper_1v1", "k_1v1", True),
    ("keeper_communicatie", "k_communicatie", True), ("keeper_uitstraling", "k_uitstraling", True),
    ("keeper_doellijn_opm", "k_doellijn_opm", False), ("keeper_1v1_opm", "k_1v1_opm", False),
    ("keeper_communicatie_opm", "k_communicatie_opm", False), ("keeper_uitstraling_opm", "k_uitstraling_opm", False),
    ("wat_goed", "wat_goed", False), ("wat_minder", "wat_minder", False),
    ("hoe_verbeteren", "hoe_verbeteren", False), ("analyse", "analyse", False),
    ("team_mentaliteit", "team_mentaliteit", True), ("team_samenspel", "team_samenspel", True),
    ("team_mentaliteit_waarom", "team_waarom", False),
    ("tegenstander_systeem", "teg_systeem", False), ("tegenstander_systeem_extra", "teg_extra", False),
    ("tegenstander_beste", "teg_beste", False),
]

def dq(obj):
    """jsonb-literal met een dollar-quote die zeker niet in de data voorkomt"""
    s = json.dumps(obj, ensure_ascii=False)
    while True:
        tag = "$k" + secrets.token_hex(4) + "$"
        if tag not in s: return f"{tag}{s}{tag}::jsonb"

def lit(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return str(v)
    return "'" + str(v).replace("'", "''") + "'"

def lees_export(pad):
    raw = open(pad, encoding="utf-8-sig").read().strip()
    if raw.lower().startswith("export"):                    # CSV-download uit de SQL Editor
        import csv, io
        csv.field_size_limit(10**9)
        raw = list(csv.reader(io.StringIO(raw)))[1][0]
    if raw.startswith('"'): raw = json.loads(raw)            # soms als string geëxporteerd
    ex = json.loads(raw)
    if isinstance(ex, list) and ex and "export" in ex[0]: ex = json.loads(ex[0]["export"])
    return ex

TERUG_AUTH = """delete from auth.identities where user_id in (select sjotter_id from sjotter_backup.ksk_migratie where nieuw);
delete from auth.users where id in (select sjotter_id from sjotter_backup.ksk_migratie where nieuw);
do $t$ declare s text := to_char(now(), 'YYYYMMDD_HH24MI'); begin
  execute format('alter table sjotter_backup.ksk_migratie rename to ksk_migratie_teruggedraaid_%s', s);
  execute format('alter table sjotter_backup.auth_users_voor_ksk rename to auth_users_voor_ksk_%s', s);
  execute format('alter table sjotter_backup.auth_identities_voor_ksk rename to auth_identities_voor_ksk_%s', s);
  execute format('alter table sjotter_backup.cs_leden_voor_ksk rename to cs_leden_voor_ksk_%s', s);
  raise notice 'Teruggedraaid. De back-up blijft bewaard met achtervoegsel %.', s;
end $t$;"""

def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("export"); ap.add_argument("email")
    ap.add_argument("--ploegnaam", default="U13 IP")
    ap.add_argument("--auth", help="export van auth.users/auth.identities uit het KSK-project: accounts mee overzetten")
    ap.add_argument("--terugdraai", help="schrijf hier het SQL-bestand om alles ongedaan te maken")
    arg = ap.parse_args()
    email, ploegnaam = arg.email, arg.ploegnaam
    ex = lees_export(arg.export)
    auth = lees_export(arg.auth) if arg.auth else None
    spelers, wedstrijden, evals = ex.get("spelers") or [], ex.get("wedstrijden") or [], ex.get("evaluaties") or []
    rollen = ex.get("rollen") or []

    PID = uid("ploeg", "ksk-lovendegem")
    seizoenen = sorted({s.get("seizoen") for s in spelers if s.get("seizoen")})
    seizoen = seizoenen[-1] if seizoenen else "2026-27"
    smap = {str(s["id"]): uid("speler", PID, s["id"]) for s in spelers}
    email_per = {str(r.get("speler_id")): r.get("email") for r in rollen if r.get("speler_id") and r.get("email")}
    keeper = {str(r.get("speler_id")) for r in rollen if r.get("speler_id") and str(r.get("role")) == "keeper"}
    keeper |= {str(s["id"]) for s in spelers if str((s.get("data") or {}).get("is_keeper")).lower() in ("true", "1")}
    trainer = {str(s["id"]) for s in spelers if str((s.get("data") or {}).get("is_trainer")).lower() in ("true", "1")}
    trainer |= {str(r.get("speler_id")) for r in rollen if r.get("speler_id") and str(r.get("role")) in ("admin", "coach")}
    # coach-account: opgegeven e-mail, anders de admin/coach-e-mails uit KSK
    kandidaten = [e for e in [email] if e and e != "auto"] + [r.get("email") for r in rollen if str(r.get("role")) in ("admin", "coach") and r.get("email")]
    kandidaten = list(dict.fromkeys(k.lower() for k in kandidaten))

    out = []
    w = out.append
    w("-- KSK -> Sjotter Coach & Speler · import")
    w("-- BEVAT PERSOONSGEGEVENS: niet delen, niet in git zetten.")
    w(f"-- {len(spelers)} spelers · {len(wedstrijden)} wedstrijden · {len(evals)} evaluaties")
    w("begin;")
    w("""create table if not exists public.cs_import_archief (
  id uuid primary key default gen_random_uuid(),
  bron text not null,
  data jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.cs_import_archief enable row level security;
revoke all on public.cs_import_archief from anon, authenticated;""")
    if auth:
        w(f"-- {len(auth.get('users') or [])} KSK-accounts · {len(auth.get('identities') or [])} identiteiten")
        w("""-- 1) BACK-UP van de huidige toestand (blijft bewaard in schema sjotter_backup)
create schema if not exists sjotter_backup;
revoke all on schema sjotter_backup from anon, authenticated;
do $b$ begin
  if to_regclass('sjotter_backup.ksk_migratie') is not null then
    raise exception 'De KSK-migratie is al uitgevoerd (sjotter_backup.ksk_migratie bestaat). Niets gewijzigd. Draai eerst terug als je opnieuw wil beginnen.';
  end if;
end $b$;
create table sjotter_backup.auth_users_voor_ksk as select * from auth.users;
create table sjotter_backup.auth_identities_voor_ksk as select * from auth.identities;
create table sjotter_backup.cs_leden_voor_ksk as select * from public.cs_leden;
create table sjotter_backup.ksk_migratie (ksk_id uuid primary key, sjotter_id uuid not null, email text, nieuw boolean not null, tijd timestamptz default now());""")
        w(f"""-- 2) KSK-ACCOUNTS overzetten (zelfde e-mail + zelfde wachtwoord)
do $m$
declare r jsonb; bestaand uuid; kolommen text; n_nieuw int := 0; n_gekoppeld int := 0;
begin
  for r in select value from jsonb_array_elements({dq(auth.get('users') or [])}) loop
    select id into bestaand from auth.users where lower(email) = lower(r->>'email') limit 1;
    if bestaand is not null then
      insert into sjotter_backup.ksk_migratie (ksk_id, sjotter_id, email, nieuw) values ((r->>'id')::uuid, bestaand, r->>'email', false);
      n_gekoppeld := n_gekoppeld + 1;
      continue;
    end if;
    if exists (select 1 from auth.users where id = (r->>'id')::uuid) then
      raise exception 'Account-id % bestaat al in Sjotter met een ander e-mailadres. Niets gewijzigd.', r->>'id';
    end if;
    select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position) into kolommen
      from information_schema.columns c
      where c.table_schema = 'auth' and c.table_name = 'users' and c.is_generated = 'NEVER' and r ? c.column_name;
    execute format('insert into auth.users (%1$s) select %1$s from jsonb_populate_record(null::auth.users, $1)', kolommen) using r;
    insert into sjotter_backup.ksk_migratie (ksk_id, sjotter_id, email, nieuw) values ((r->>'id')::uuid, (r->>'id')::uuid, r->>'email', true);
    n_nieuw := n_nieuw + 1;
  end loop;
  for r in select value from jsonb_array_elements({dq(auth.get('identities') or [])}) loop
    if exists (select 1 from sjotter_backup.ksk_migratie where sjotter_id = (r->>'user_id')::uuid and nieuw) then
      select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position) into kolommen
        from information_schema.columns c
        where c.table_schema = 'auth' and c.table_name = 'identities' and c.is_generated = 'NEVER' and r ? c.column_name;
      execute format('insert into auth.identities (%1$s) select %1$s from jsonb_populate_record(null::auth.identities, $1) on conflict do nothing', kolommen) using r;
    end if;
  end loop;
  raise notice 'Accounts: % nieuw overgezet, % bestonden al in Sjotter (gekoppeld).', n_nieuw, n_gekoppeld;
end $m$;""")
    w(f"""do $import$
declare v_coach uuid;
begin
  select u.id into v_coach from auth.users u
    join unnest(array[{", ".join(lit(k) for k in kandidaten)}]::text[]) with ordinality k(mail, nr) on lower(u.email) = k.mail
    order by k.nr limit 1;
  if v_coach is null then raise exception 'Geen Sjotter-account gevonden voor: %. Maak eerst een coach-account op /coach/ met een van deze e-mailadressen.', {lit(", ".join(kandidaten))}; end if;
  raise notice 'Ploeg wordt gekoppeld aan coach-account %', (select email from auth.users where id = v_coach);
  if exists (select 1 from public.cs_ploegen where id = {lit(PID)}) then raise exception 'Deze import is al uitgevoerd (ploeg bestaat al). Niets gewijzigd.'; end if;
  perform set_config('request.jwt.claim.sub', v_coach::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_coach)::text, true);""")
    groepen = [{"id": "blauw", "naam": "Blauw", "kleur": "#6FB7FF"}, {"id": "geel", "naam": "Geel", "kleur": "#F4C95D"}]
    w(f"  insert into public.cs_ploegen (id, naam, club, categorie, seizoen, formaat, groepen, weak_link_aan, eigenaar)\n"
      f"  values ({lit(PID)}, {lit(ploegnaam)}, 'KSK Lovendegem', 'U13', {lit(seizoen)}, 8, {dq(groepen)}, true, v_coach);")

    for s in spelers:
        sid = smap[str(s["id"])]
        d = s.get("data") or {}
        nr = d.get("rugnummer")
        nr = int(nr) if str(nr).isdigit() and 0 <= int(nr) <= 99 else None
        w(f"  insert into public.cs_spelers (id, ploeg_id, voornaam, naam, rugnummer, is_keeper, actief) values "
          f"({lit(sid)}, {lit(PID)}, {lit((tekst(s.get('voornaam'), 60) or '?'))}, {lit(tekst(s.get('naam'), 60) or '')}, {lit(nr)}, {lit(str(s['id']) in keeper)}, {lit(str(s['id']) not in trainer)});")
        w(f"  insert into public.cs_speler_profiel (speler_id, ploeg_id, data) values ({lit(sid)}, {lit(PID)}, {dq(profiel(d, email_per.get(str(s['id']))))});")

    wmap = {}
    for m in wedstrijden:
        wid = uid("wedstrijd", PID, m["id"]); wmap[str(m["id"])] = wid
        opst = {"blauw": [smap[i] for i in ids(m.get("blauw_spelers")) if i in smap],
                "geel": [smap[i] for i in ids(m.get("geel_spelers")) if i in smap]}
        scores = {}
        for g in ("blauw", "geel"):
            u = uitslag(m.get(g + "_score"), m.get("thuis_uit"))
            if u: scores[g] = u
        tu = "uit" if str(m.get("thuis_uit") or "").lower() == "uit" else "thuis"
        datum = str(m.get("datum") or "")[:10] or "2026-01-01"
        w(f"  insert into public.cs_wedstrijden (id, ploeg_id, datum, tegenstander, thuis_uit, opstelling, scores, eval_open) values "
          f"({lit(wid)}, {lit(PID)}, {lit(datum)}, {lit(tekst(m.get('tegenstander'), 80) or 'Onbekend')}, {lit(tu)}, {dq(opst)}, {dq(scores)}, true);")

    overgeslagen = 0
    for e in evals:
        wid, beo = wmap.get(str(e.get("match_id"))), smap.get(str(e.get("beoordelaar")))
        if not wid or not beo: overgeslagen += 1; continue
        ratings = {}
        for k, v in (e.get("ratings") or {}).items():
            t, sc = smap.get(str(k)), score(v)
            if t and sc and t != beo: ratings[t] = sc
        motm = smap.get(str(e.get("motm"))) if e.get("motm") is not None else None
        if motm == beo: motm = None
        wl = smap.get(str(e.get("weak_link"))) if e.get("weak_link") is not None else None
        if wl == beo: wl = None
        a = {}
        for k_ksk, k, is_score in EVAL_MAP:
            v = e.get(k_ksk)
            if is_score:
                if score(v): a[k] = score(v)
            elif tekst(v): a[k] = tekst(v, 800)
        a["_ksk"] = e
        w(f"  insert into public.cs_evaluaties (wedstrijd_id, ploeg_id, speler_id, antwoorden, ratings, motm, weak_link, ingediend) values "
          f"({lit(wid)}, {lit(PID)}, {lit(beo)}, {dq(a)}, {dq(ratings)}, {lit(motm)}, {lit(wl)}, {lit(bool(e.get('vergrendeld')) or bool(ratings) or any(k != '_ksk' for k in a))}) "
          f"on conflict (wedstrijd_id, speler_id) do nothing;")

    w(f"  raise notice 'Import klaar: % spelers, % wedstrijden, % evaluaties ({overgeslagen} zonder geldige speler/wedstrijd, wel in archief).', "
      f"{len(spelers)}, {len(wedstrijden)}, {len(evals) - overgeslagen};")
    w("end $import$;")
    w(f"insert into public.cs_import_archief (bron, data) values ('ksk-lovendegem-u13', {dq(ex)});")
    if auth:
        w("-- 3) accounts aan de ploeg en aan hun speler koppelen (meteen actief, geen goedkeuring nodig)")
        for r in rollen:
            if not r.get("user_id"): continue
            coach = str(r.get("role")) in ("admin", "coach")
            sid = None if coach else smap.get(str(r.get("speler_id")))
            if not coach and not sid: continue          # 'pending' of speler zonder fiche: niet koppelen
            w(f"insert into public.cs_leden (ploeg_id, user_id, rol, status, speler_id, naam, email) "
              f"select {lit(PID)}, m.sjotter_id, {lit('coach' if coach else 'speler')}, 'actief', {lit(sid)}, {lit(tekst(r.get('naam'), 80))}, m.email "
              f"from sjotter_backup.ksk_migratie m where m.ksk_id = {lit(r['user_id'])} on conflict (ploeg_id, user_id) do nothing;")
        w(f"do $c$ begin raise notice 'Leden in de ploeg: %', (select count(*) from public.cs_leden where ploeg_id = {lit(PID)}); end $c$;")
    w("commit;")
    print("\n".join(out))
    if arg.terugdraai:
        open(arg.terugdraai, "w", encoding="utf-8").write(
            "-- TERUGDRAAIEN van de KSK-migratie in Sjotter\n"
            "-- Verwijdert enkel wat de migratie toevoegde. Het KSK-project zelf werd nooit gewijzigd.\n"
            "begin;\n"
            f"delete from public.cs_ploegen where id = {lit(PID)};  -- ploeg + spelers, wedstrijden, evaluaties, leden\n"
            "do $a$ begin if to_regclass('public.cs_import_archief') is not null then delete from public.cs_import_archief where bron = 'ksk-lovendegem-u13'; end if; end $a$;\n"
            + (TERUG_AUTH + "\n" if auth else "") +
            "commit;\n")

if __name__ == "__main__":
    main()
