// Sjotter · Edge Function "ksk-sync"
// Haalt de gegevens van het KSK-spelersplatform op (enkel lezen) en werkt de
// Sjotter-ploeg bij via public.cs_ksk_sync_toepassen. KSK wordt nooit gewijzigd.
//
// Geheim (Supabase → Edge Functions → Secrets):
//   KSK_SERVICE_KEY   secret- of service_role-key van het KSK-project (wordt enkel gebruikt om te lezen)
// Optioneel: KSK_URL (standaard het KSK-project hieronder)
// Automatisch aanwezig: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Aanroepen:
//   * automatisch (pg_cron, zie sql/coach/004_ksk_sync_cron.sql): header x-sync-secret
//     = public.cs_ksk_sync_instelling.geheim
//   * vanuit de app: met de gebruikerstoken van een coach van de ploeg
// Zet bij deze functie "Verify JWT" uit: ze controleert zelf wie haar aanroept.
//
// Dezelfde omzetting als tools/ksk_naar_sjotter.py → dezelfde id's als de migratie.

const NS = "5b0c7e2a-1f3d-4c2b-9a77-6d3f1e0c4a11";
const PLOEG_SLEUTEL = "ksk-lovendegem";
const KSK_STANDAARD_URL = "https://gfjqujhtligypbvrdnug.supabase.co";
// nieuwe sb_secret_-sleutels gaan enkel in "apikey", oude JWT-sleutels ook in Authorization
const sleutelHeaders = (key) => (String(key).startsWith("eyJ") ? { apikey: key, Authorization: `Bearer ${key}` } : { apikey: key });

// ---------- uuid v5 (zelfde als Python uuid.uuid5) ----------
function hexNaarBytes(h) { const b = new Uint8Array(16); h = h.replace(/-/g, ""); for (let i = 0; i < 16; i++) b[i] = parseInt(h.substr(i * 2, 2), 16); return b; }
async function uuid5(naam) {
  const ns = hexNaarBytes(NS), tekstBytes = new TextEncoder().encode(naam);
  const buf = new Uint8Array(ns.length + tekstBytes.length); buf.set(ns); buf.set(tekstBytes, ns.length);
  const h = new Uint8Array(await crypto.subtle.digest("SHA-1", buf)).slice(0, 16);
  h[6] = (h[6] & 0x0f) | 0x50; h[8] = (h[8] & 0x3f) | 0x80;
  const x = [...h].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}
const uid = (...delen) => uuid5(delen.map(String).join("/"));

// ---------- hulpfuncties (zelfde gedrag als de Python-versie) ----------
const leeg = (v) => v === null || v === undefined || v === "" || (Array.isArray(v) && !v.length) || (typeof v === "object" && !Array.isArray(v) && v && !Object.keys(v).length);
const pyStr = (v) => (v === true ? "True" : v === false ? "False" : String(v));
const tekst = (v, n) => { if (leeg(v)) return null; const s = pyStr(v).trim(); return n ? s.slice(0, n) : s; };
// Python round(): halve getallen naar het dichtstbijzijnde even getal
function pyRound(f) { const r = Math.round(f); return Math.abs(f % 1) === 0.5 && r % 2 !== 0 ? r - 1 : r; }
function score(v) { if (v === null || v === undefined || v === "" || typeof v === "object") return null; const f = Number(v); if (Number.isNaN(f)) return null; const x = pyRound(f); return x >= 1 && x <= 10 ? x : null; }
function ids(v) {
  if (leeg(v)) return [];
  if (typeof v === "string") { try { v = JSON.parse(v); } catch { v = v.match(/\d+/g) || []; } }
  if (!Array.isArray(v)) return [];
  return v.filter((x) => /^-?\d+$/.test(String(x).trim())).map((x) => String(parseInt(x, 10)));
}
function uitslag(raw, thuisUit) {
  if (leeg(raw)) return null;
  const m = String(raw).match(/^\s*(\d+)\s*[-–:]\s*(\d+)\s*$/);
  if (!m) return null;
  const a = +m[1], b = +m[2];
  return String(thuisUit || "thuis").toLowerCase() === "uit" ? { wij: b, zij: a } : { wij: a, zij: b };
}
const waar = (v) => ["true", "1"].includes(String(v).toLowerCase());
const CAT = { technisch: "technisch", taktisch: "tactisch", tactisch: "tactisch", fysiek: "fysiek", mentaal: "mentaal" };

function profiel(d, email) {
  d = d || {};
  const p = { sterk: {}, werk: {}, gegevens: {} };
  for (const [sk, s] of [["sterke", "sterk"], ["werk", "werk"]]) {
    for (const [ck, c] of Object.entries(CAT)) {
      const v = d[`${sk}_${ck}`];
      if (Array.isArray(v) && v.length) {
        const bestaand = p[s][c] || [];
        p[s][c] = bestaand.concat(v.map(String).filter((x) => !bestaand.includes(x)));
      }
    }
  }
  for (const [kk, k] of [["pv-fav-pos", "pos_fav"], ["pv-ges-pos", "pos_meest"]]) if (Array.isArray(d[kk]) && d[kk].length) p[k] = d[kk].map(String);
  for (const [kk, k] of [["voorkeurspoot", "voet"], ["vorige_clubs", "vorige_clubs"], ["fav_ploeg", "fav_ploeg"], ["rolmodel", "fav_speler"],
    ["waarom_voetbal", "leuk"], ["droomscenario", "droom"], ["herinnering", "herinnering"], ["bf_niveau", "goed"], ["bf_doel", "beter"], ["verw_trainer", "verwacht"]]) {
    if (tekst(d[kk])) p[k] = tekst(d[kk]);
  }
  if (p.voet) p.voet = p.voet.charAt(0).toUpperCase() + p.voet.slice(1).toLowerCase();
  for (const k of ["zb_inzet", "zb_wedstrijd", "zb_gedrag", "zb_coach"]) if (score(d[k])) p[k] = score(d[k]);
  for (const [kk, k] of [["geboortedatum", "geboortedatum"], ["gsm_speler", "gsm"], ["school_naam", "school"], ["jaren_actief", "jaren"],
    ["allergie", "allergie"], ["medicatie", "medicatie"], ["medisch_info", "medisch"]]) {
    if (tekst(d[kk])) p.gegevens[k] = tekst(d[kk], 500);
  }
  if (Array.isArray(d.unavail_dates)) p.afwezig = [...new Set(d.unavail_dates.map(String).filter((x) => /^\d{4}-\d{2}-\d{2}/.test(x)).map((x) => x.slice(0, 10)))].sort();
  if (email) p.ksk_email = email;
  p._ksk = d;
  return p;
}

const EVAL_MAP = [
  ["eigen_mentaliteit", "eigen_mentaliteit", true], ["eigen_mentaliteit_opm", "eigen_mentaliteit_opm", false],
  ["eigen_b_plus", "eigen_bplus", true], ["eigen_b_plus_opmerking", "eigen_bplus_opm", false],
  ["eigen_b_min", "eigen_bmin", true], ["eigen_b_min_opmerking", "eigen_bmin_opm", false],
  ["eigen_trans_bp_bm", "eigen_t1", true], ["eigen_trans_bp_bm_opmerking", "eigen_t1_opm", false],
  ["eigen_trans_bm_bp", "eigen_t2", true], ["eigen_trans_bm_bp_opmerking", "eigen_t2_opm", false],
  ["keeper_doellijn", "k_doellijn", true], ["keeper_1v1", "k_1v1", true],
  ["keeper_communicatie", "k_communicatie", true], ["keeper_uitstraling", "k_uitstraling", true],
  ["keeper_doellijn_opm", "k_doellijn_opm", false], ["keeper_1v1_opm", "k_1v1_opm", false],
  ["keeper_communicatie_opm", "k_communicatie_opm", false], ["keeper_uitstraling_opm", "k_uitstraling_opm", false],
  ["wat_goed", "wat_goed", false], ["wat_minder", "wat_minder", false],
  ["hoe_verbeteren", "hoe_verbeteren", false], ["analyse", "analyse", false],
  ["team_mentaliteit", "team_mentaliteit", true], ["team_samenspel", "team_samenspel", true],
  ["team_mentaliteit_waarom", "team_waarom", false],
  ["tegenstander_systeem", "teg_systeem", false], ["tegenstander_systeem_extra", "teg_extra", false],
  ["tegenstander_beste", "teg_beste", false],
];

// ---------- KSK-export → Sjotter-rijen ----------
export async function zetOm(ex) {
  const spelers = ex.spelers || [], wedstrijden = ex.wedstrijden || [], evals = ex.evaluaties || [], rollen = ex.rollen || [];
  const PID = await uid("ploeg", PLOEG_SLEUTEL);
  const smap = {};
  for (const s of spelers) smap[String(s.id)] = await uid("speler", PID, s.id);
  const emailPer = {}, keeper = new Set(), trainer = new Set();
  for (const r of rollen) {
    if (r.speler_id && r.email) emailPer[String(r.speler_id)] = r.email;
    if (r.speler_id && String(r.role) === "keeper") keeper.add(String(r.speler_id));
    if (r.speler_id && ["admin", "coach"].includes(String(r.role))) trainer.add(String(r.speler_id));
  }
  for (const s of spelers) {
    if (waar((s.data || {}).is_keeper)) keeper.add(String(s.id));
    if (waar((s.data || {}).is_trainer)) trainer.add(String(s.id));
  }
  const uitSpelers = spelers.map((s) => {
    const d = s.data || {};
    const nr = /^\d+$/.test(String(d.rugnummer)) && +d.rugnummer <= 99 ? +d.rugnummer : null;
    return {
      id: smap[String(s.id)], voornaam: tekst(s.voornaam, 60) || "?", naam: tekst(s.naam, 60) || "", rugnummer: nr,
      is_keeper: keeper.has(String(s.id)), actief: !trainer.has(String(s.id)), profiel: profiel(d, emailPer[String(s.id)]),
    };
  });
  const wmap = {}, uitW = [];
  for (const m of wedstrijden) {
    const wid = await uid("wedstrijd", PID, m.id); wmap[String(m.id)] = wid;
    const opstelling = {
      blauw: ids(m.blauw_spelers).filter((i) => smap[i]).map((i) => smap[i]),
      geel: ids(m.geel_spelers).filter((i) => smap[i]).map((i) => smap[i]),
    };
    const scores = {};
    for (const g of ["blauw", "geel"]) { const u = uitslag(m[g + "_score"], m.thuis_uit); if (u) scores[g] = u; }
    uitW.push({
      id: wid, datum: String(m.datum || "").slice(0, 10) || "2026-01-01", tegenstander: tekst(m.tegenstander, 80) || "Onbekend",
      thuis_uit: String(m.thuis_uit || "").toLowerCase() === "uit" ? "uit" : "thuis", opstelling, scores,
    });
  }
  const uitE = [];
  for (const e of evals) {
    const wid = wmap[String(e.match_id)], beo = smap[String(e.beoordelaar)];
    if (!wid || !beo) continue;
    const ratings = {};
    for (const [k, v] of Object.entries(e.ratings || {})) { const t = smap[String(k)], sc = score(v); if (t && sc && t !== beo) ratings[t] = sc; }
    let motm = e.motm !== null && e.motm !== undefined ? smap[String(e.motm)] || null : null; if (motm === beo) motm = null;
    let wl = e.weak_link !== null && e.weak_link !== undefined ? smap[String(e.weak_link)] || null : null; if (wl === beo) wl = null;
    const a = {};
    for (const [kk, k, isScore] of EVAL_MAP) {
      const v = e[kk];
      if (isScore) { if (score(v)) a[k] = score(v); } else if (tekst(v)) a[k] = tekst(v, 800);
    }
    const ingediend = !!e.vergrendeld || Object.keys(ratings).length > 0 || Object.keys(a).length > 0;
    a._ksk = e;
    uitE.push({ wedstrijd_id: wid, speler_id: beo, antwoorden: a, ratings, motm, weak_link: wl, ingediend });
  }
  return { ploeg_id: PID, spelers: uitSpelers, wedstrijden: uitW, evaluaties: uitE };
}

// ---------- KSK lezen ----------
async function kskTabel(tabel) {
  const url = (Deno.env.get("KSK_URL") || KSK_STANDAARD_URL).trim(), key = (Deno.env.get("KSK_SERVICE_KEY") || "").replace(/\s+/g, "");
  if (!key) throw new Error("Geheim KSK_SERVICE_KEY ontbreekt bij de functie ksk-sync");
  const rijen = [];
  for (let van = 0; ; van += 1000) {
    const r = await fetch(`${url}/rest/v1/${tabel}?select=*&order=id`, {
      headers: { ...sleutelHeaders(key), Range: `${van}-${van + 999}`, "Range-Unit": "items" },
    });
    if (!r.ok) throw new Error(r.status === 401 ? `KSK weigert de sleutel (401). Controleer KSK_SERVICE_KEY: het moet de secret- of service_role-key van het KSK-project (gfjq…) zijn.` : `KSK ${tabel}: ${r.status} ${(await r.text()).slice(0, 200)}`);
    const deel = await r.json();
    rijen.push(...deel);
    if (deel.length < 1000) return rijen;
  }
}

async function sjotter(pad, opties = {}) {
  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const r = await fetch(`${url}${pad}`, {
    ...opties, headers: { ...sleutelHeaders(key), "Content-Type": "application/json", ...(opties.headers || {}) },
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`Sjotter ${pad}: ${r.status} ${t}`);
  return t ? JSON.parse(t) : null;
}

// ---------- wie mag dit starten? ----------
async function magStarten(req, ploegId) {
  const kop = req.headers.get("x-sync-secret");
  if (kop) {
    const rij = await sjotter("/rest/v1/cs_ksk_sync_instelling?select=geheim&id=eq.1");
    if (rij && rij[0] && rij[0].geheim && rij[0].geheim === kop) return "automatisch";
    return null;
  }
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const u = await fetch(`${url}/auth/v1/user`, { headers: { apikey: key, Authorization: `Bearer ${token}` } });
  if (!u.ok) return null;
  const gebruiker = await u.json();
  const leden = await sjotter(`/rest/v1/cs_leden?select=id&ploeg_id=eq.${ploegId}&user_id=eq.${gebruiker.id}&rol=eq.coach&status=eq.actief`);
  return leden && leden.length ? `handmatig (${gebruiker.email})` : null;
}

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-sync-secret", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const antwoord = (data, status = 200) => new Response(JSON.stringify(data), { status, headers: { ...CORS, "Content-Type": "application/json" } });

if (typeof Deno !== "undefined" && Deno.serve) {
  Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
    const PID = await uid("ploeg", PLOEG_SLEUTEL);
    let bron = null;
    try {
      bron = await magStarten(req, PID);
      if (!bron) return antwoord({ fout: "Geen toegang" }, 401);
      const [spelers, wedstrijden, evaluaties, rollen] = await Promise.all(
        ["spelers", "wedstrijden", "match_evaluaties", "user_roles"].map(kskTabel));
      const p = await zetOm({ spelers, wedstrijden, evaluaties, rollen });
      p.bron = bron;
      const telling = await sjotter("/rest/v1/rpc/cs_ksk_sync_toepassen", { method: "POST", body: JSON.stringify({ p }) });
      return antwoord({ ok: true, bron, telling, ksk: { spelers: spelers.length, wedstrijden: wedstrijden.length, evaluaties: evaluaties.length } });
    } catch (e) {
      const geheimen = [Deno.env.get("KSK_SERVICE_KEY"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")].filter(Boolean);
      const veilig = (t) => geheimen.reduce((x, g) => x.split(g).join("•••").split(g.replace(/\s+/g, "")).join("•••"), String(t)).replace(/sb_secret_[A-Za-z0-9_\- ]+/g, "sb_secret_•••");
      e = new Error(veilig(e && e.message || e));
      try { await sjotter("/rest/v1/rpc/cs_ksk_sync_fout", { method: "POST", body: JSON.stringify({ p_ploeg: PID, p_bron: bron, p_fout: String(e && e.message || e) }) }); } catch { /* log mislukt */ }
      return antwoord({ ok: false, fout: String(e && e.message || e) }, 500);
    }
  });
}
