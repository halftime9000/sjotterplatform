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
    ("keeper_opm", "k_opm", False),
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

def main():
    bron, email = sys.argv[1], sys.argv[2]
    ploegnaam = sys.argv[3] if len(sys.argv) > 3 else "U13 IP"
    raw = open(bron, encoding="utf-8-sig").read().strip()
    if raw.lower().startswith("export"):                    # CSV-download uit de SQL Editor
        import csv, io
        csv.field_size_limit(10**9)
        rijen = list(csv.reader(io.StringIO(raw)))
        raw = rijen[1][0]
    if raw.startswith('"'): raw = json.loads(raw)            # soms als string geëxporteerd
    ex = json.loads(raw)
    if isinstance(ex, list) and ex and "export" in ex[0]: ex = json.loads(ex[0]["export"])
    spelers, wedstrijden, evals = ex.get("spelers") or [], ex.get("wedstrijden") or [], ex.get("evaluaties") or []
    rollen = ex.get("rollen") or []

    PID = uid("ploeg", "ksk-lovendegem")
    seizoenen = sorted({s.get("seizoen") for s in spelers if s.get("seizoen")})
    seizoen = seizoenen[-1] if seizoenen else "2026-27"
    smap = {str(s["id"]): uid("speler", s["id"]) for s in spelers}
    email_per = {str(r.get("speler_id")): r.get("email") for r in rollen if r.get("speler_id") and r.get("email")}
    keeper = {str(r.get("speler_id")) for r in rollen if r.get("speler_id") and str(r.get("role")) == "keeper"}

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
    w(f"""do $import$
declare v_coach uuid;
begin
  select id into v_coach from auth.users where lower(email) = lower({lit(email)});
  if v_coach is null then raise exception 'Geen Sjotter-account gevonden voor %. Maak eerst een account op /coach/.', {lit(email)}; end if;
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
          f"({lit(sid)}, {lit(PID)}, {lit((tekst(s.get('voornaam'), 60) or '?'))}, {lit(tekst(s.get('naam'), 60) or '')}, {lit(nr)}, {lit(str(s['id']) in keeper)}, true);")
        w(f"  insert into public.cs_speler_profiel (speler_id, ploeg_id, data) values ({lit(sid)}, {lit(PID)}, {dq(profiel(d, email_per.get(str(s['id']))))});")

    wmap = {}
    for m in wedstrijden:
        wid = uid("wedstrijd", m["id"]); wmap[str(m["id"])] = wid
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
          f"({lit(wid)}, {lit(PID)}, {lit(beo)}, {dq(a)}, {dq(ratings)}, {lit(motm)}, {lit(wl)}, {lit(bool(e.get('vergrendeld')))}) "
          f"on conflict (wedstrijd_id, speler_id) do nothing;")

    w(f"  raise notice 'Import klaar: % spelers, % wedstrijden, % evaluaties ({overgeslagen} zonder geldige speler/wedstrijd, wel in archief).', "
      f"{len(spelers)}, {len(wedstrijden)}, {len(evals) - overgeslagen};")
    w("end $import$;")
    w(f"insert into public.cs_import_archief (bron, data) values ('ksk-lovendegem-u13', {dq(ex)});")
    w("commit;")
    print("\n".join(out))

if __name__ == "__main__":
    main()
