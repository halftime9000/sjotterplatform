# Sjotter platform

Eén repo, één Supabase-project (`equmwyvxbjjocwetwfcw`), meerdere modules:

| Map | Inhoud | Status |
|---|---|---|
| `/` | Hub (geen login). Stuurt oude `#/...`-links door naar `tornooi/` | ✅ |
| `/tornooi/` | Oefenmatch & Tornooi (bestaande Sjotter) | ✅ |
| `/coach/` | Coach & Speler (multi-team versie van het KSK-systeem) | ✅ na SQL-migratie |
| `/training/` | Training Hub (eigen + gedeelde links) | 🚧 |
| `/playernation/` | ThePlayerNation | 🚧 |
| `/shared/` | `config.js`, `sjotter.css` | ✅ |
| `/assets/` | `foto-toernooi.jpg`, `foto-oefenmatch.jpg` (uit de oude repo kopiëren) | ⚠️ |

Alle links zijn relatief, dus de site werkt zowel op `halftime9000.github.io/sjotterplatform/` als op `sjotter.be`.

## Uitrol
1. Upload de bestanden naar deze repo en voeg de twee foto's toe in `assets/`.
2. Ga naar Settings → Pages, kies Deploy from branch, `main` en `/ (root)`.
3. Test op `https://halftime9000.github.io/sjotterplatform/`.
4. Ga naar Supabase → Authentication → URL Configuration → Redirect URLs en voeg toe:
   - `https://halftime9000.github.io/sjotterplatform/**`
   - `https://sjotter.be/**`
5. Overschakelen: verwijder het CNAME-bestand uit de oude repo. Zet daarna in deze repo onder Settings → Pages → Custom domain `sjotter.be` (dit maakt een CNAME-bestand aan). Zet Site URL in Supabase op `https://sjotter.be/tornooi/`.
6. Rollback: zet het custom domain terug in de oude repo.

## Coach & Speler activeren
1. Supabase → SQL Editor → plak en voer `sql/coach/001_coach_speler.sql` uit (veilig om opnieuw uit te voeren).
2. Alle tabellen beginnen met `cs_` en raken de tornooi-tabellen niet.
3. Test op `/coach/`: account maken → ploeg aanmaken → teamcode delen → aanvraag goedkeuren.

## KSK-spelersplatform synchroniseren (overgangsperiode)

Zolang de spelers het oude KSK-platform gebruiken, volgt de Sjotter-ploeg KSK Lovendegem U13 automatisch:
spelers, fiches, wedstrijden, opstellingen, uitslagen en evaluaties. Richting: **KSK → Sjotter, enkel lezen in KSK**.
Wat in Sjotter zelf ingesteld of aangemaakt wordt (logo, leden, ploeginstellingen, eigen wedstrijden) blijft staan; niets wordt verwijderd.

1. **SQL** (Sjotter-project → SQL Editor): voer `sql/coach/003_ksk_sync.sql` uit.
2. **Functie** (Sjotter-project → Edge Functions → Deploy a new function → Via editor):
   naam `ksk-sync`, plak de inhoud van `supabase/functions/ksk-sync/index.ts`, deploy.
   Zet daarna bij de functie **Verify JWT / Enforce JWT verification uit** (de functie controleert zelf wie ze aanroept).
3. **Geheim** (Sjotter-project → Edge Functions → Secrets): `KSK_SERVICE_KEY` = de secret key (of service_role key)
   van het **KSK**-project (KSK → Project Settings → API Keys). Die wordt enkel gebruikt om KSK te lezen.
4. **Testen**: Coach & Speler → ploeg → Instellingen → *Synchronisatie met KSK* → **Nu synchroniseren**.
5. **Automatisch elke 15 minuten**: voer `sql/coach/004_ksk_sync_cron.sql` uit.

Op de Home van de ploeg staat een regel met de laatste synchronisatie; het volledige logboek staat in Instellingen.

Bij de definitieve overstap: `select cron.unschedule('ksk-sync');` (en eventueel de functie verwijderen).
Nieuwe accounts die intussen in KSK worden aangemaakt, worden niet automatisch overgezet (wachtwoorden zijn niet
via de API leesbaar); die spelers maken bij de overstap een Sjotter-account met hetzelfde e-mailadres, de coach keurt
goed en de juiste speler is al voorgeselecteerd.
