-- Sjotter · Coach & Speler · clublogo per ploeg
-- Veilig om meerdere keren uit te voeren. Voegt enkel een kolom toe; bestaande gegevens blijven ongewijzigd.
alter table public.cs_ploegen add column if not exists logo text;
alter table public.cs_ploegen drop constraint if exists cs_ploegen_logo_check;
alter table public.cs_ploegen add constraint cs_ploegen_logo_check
  check (logo is null or (logo like 'data:image/%' and char_length(logo) <= 200000));
