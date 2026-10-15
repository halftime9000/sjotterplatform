# RLS-tests Coach & Speler (lokaal, niet in Supabase uitvoeren)

Lokale Postgres 16, lege database:

    psql -d t -f 00_supabase_stub.sql      # nabootsing van Supabase (auth.users, auth.uid, rollen)
    psql -d t -f ../001_coach_speler.sql
    psql -d t -f 10_rls_tests.sql          # elke regel "ok (...)" = verwachte weigering

Scenario's: coach maakt ploeg, vreemde ziet niets, aansluiten met code + ouder-toestemming,
goedkeuren en koppelen, profiel enkel voor coach + speler zelf, evaluatieregels
(score 1-10, niet jezelf, enkel opgesteld, gesloten evaluaties), weak link aan/uit,
code vernieuwen, ploeg verlaten en verwijderen (cascade).
