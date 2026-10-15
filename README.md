# Sjotter platform

Eén repo, één Supabase-project (`equmwyvxbjjocwetwfcw`), meerdere modules:

| Map | Inhoud | Status |
|---|---|---|
| `/` | Hub (geen login). Stuurt oude `#/...`-links door naar `tornooi/` | ✅ |
| `/tornooi/` | Oefenmatch & Tornooi (bestaande Sjotter) | ✅ |
| `/coach/` | Coach & Speler (multi-team versie van het KSK-systeem) | 🚧 |
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
