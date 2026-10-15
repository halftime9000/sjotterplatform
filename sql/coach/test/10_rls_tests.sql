\set ON_ERROR_STOP 0
\set QUIET 1
create or replace function pg_temp.als(u text) returns void language plpgsql as $$ begin
  perform set_config('request.jwt.claim.sub', u, false);
  execute 'set role authenticated'; end $$;
-- helper om fouten te verwachten
create or replace function pg_temp.verwacht_fout(q text, label text) returns text language plpgsql as $$
begin execute q; return 'FAIL (geen fout): '||label;
exception when others then return 'ok  ('||label||'): '||sqlerrm; end $$;

\echo === coach maakt ploeg
select pg_temp.als('00000000-0000-0000-0000-00000000000c');
insert into cs_ploegen(naam,club,categorie,formaat,groepen) values ('U13 IP','KSK Test','U13',8,'[{"id":"a","naam":"Blauw"},{"id":"b","naam":"Geel"}]');
select naam, length(code)=6 as code_ok, eigenaar='00000000-0000-0000-0000-00000000000c' as eig from cs_ploegen;
select rol,status from cs_leden;
insert into cs_spelers(ploeg_id,voornaam,naam) select id,'Sam','Een' from cs_ploegen;
insert into cs_spelers(ploeg_id,voornaam,naam) select id,'Lou','Twee' from cs_ploegen;
insert into cs_spelers(ploeg_id,voornaam,naam) select id,'Mo','Drie' from cs_ploegen;
reset role;
select code as c from cs_ploegen \gset
select id as pl from cs_ploegen \gset
select id as s1 from cs_spelers where voornaam='Sam' \gset
select id as s2 from cs_spelers where voornaam='Lou' \gset
select id as s3 from cs_spelers where voornaam='Mo' \gset

\echo === anon: ploeg via code ok, tabellen dicht
set role anon;
select naam from cs_ploeg_via_code(lower(:'c'));
select pg_temp.verwacht_fout('select * from cs_ploegen','anon leest ploegen');
reset role;

\echo === vreemde ziet niets
select pg_temp.als('00000000-0000-0000-0000-0000000000ff');
select count(*) as ploegen_vreemde from cs_ploegen;
select count(*) as spelers_vreemde from cs_spelers;
select pg_temp.verwacht_fout($$insert into cs_spelers(ploeg_id,voornaam) values ('$$||:'pl'||$$','Hack')$$,'vreemde voegt speler toe');
select pg_temp.verwacht_fout($$insert into cs_leden(ploeg_id,user_id,rol,status) values ('$$||:'pl'||$$','00000000-0000-0000-0000-0000000000ff','coach','actief')$$,'vreemde maakt zich coach');
reset role;

\echo === speler sluit aan
select pg_temp.als('00000000-0000-0000-0000-0000000000a1');
select pg_temp.verwacht_fout($$select cs_aansluiten('$$||:'c'||$$','Sam Een',false)$$,'zonder ouder-toestemming');
select pg_temp.verwacht_fout($$select cs_aansluiten('XXXXXX','Sam Een',true)$$,'foute code');
select cs_aansluiten(:'c','Sam Een',true) is not null as aangesloten;
select status from cs_leden;
select count(*) as ziet_ploeg_in_wacht from cs_ploegen;
select count(*) as ziet_spelers_in_wacht from cs_spelers;
select pg_temp.verwacht_fout($$update cs_leden set status='actief' where user_id=auth.uid()$$,'zichzelf goedkeuren') ;
select status as nog_steeds from cs_leden;
reset role;

select pg_temp.als('00000000-0000-0000-0000-0000000000a2');
select cs_aansluiten(:'c','Ouder Mo',true) is not null as ouder_aangesloten;
reset role;

\echo === coach keurt goed en koppelt
select pg_temp.als('00000000-0000-0000-0000-00000000000c');
update cs_leden set status='actief', speler_id=:'s1' where user_id='00000000-0000-0000-0000-0000000000a1';
update cs_leden set status='actief', speler_id=:'s3' where user_id='00000000-0000-0000-0000-0000000000a2';
select naam,status,speler_id is not null as gekoppeld from cs_leden order by naam;
select pg_temp.verwacht_fout($$delete from cs_leden where user_id='00000000-0000-0000-0000-00000000000c'$$,'eigenaar verwijderen');
update cs_leden set rol='speler' where user_id='00000000-0000-0000-0000-00000000000c';
select rol as eigenaar_blijft from cs_leden where user_id='00000000-0000-0000-0000-00000000000c';
insert into cs_speler_profiel(speler_id,ploeg_id,data,coach_boodschap) values (:'s1',:'pl','{"positie":"9"}','Goed bezig Sam!');
insert into cs_speler_profiel(speler_id,ploeg_id,data) values (:'s2',:'pl','{}');
insert into cs_wedstrijden(ploeg_id,datum,tegenstander,opstelling) values (:'pl','2026-10-17','FC Test',jsonb_build_object('a',jsonb_build_array(:'s1',:'s2'),'b',jsonb_build_array()));
insert into cs_berichten(ploeg_id,tekst) values (:'pl','Zaterdag 9u verzamelen');
reset role;
select id as w1 from cs_wedstrijden \gset

\echo === speler: profiel
select pg_temp.als('00000000-0000-0000-0000-0000000000a1');
select count(*) as ziet_spelers from cs_spelers;
select count(*) as ziet_profielen from cs_speler_profiel;
update cs_speler_profiel set data='{"positie":"7"}', coach_boodschap='hack' where speler_id=:'s1';
select data->>'positie' as pos, coach_boodschap from cs_speler_profiel;
update cs_speler_profiel set data='{"x":1}' where speler_id=:'s2';
select count(*) as berichten from cs_berichten;
select pg_temp.verwacht_fout($$insert into cs_berichten(ploeg_id,tekst) values ('$$||:'pl'||$$','hoi')$$,'speler post bericht');
select count(*) as leden_zichtbaar from cs_leden;

\echo === speler: evaluatie
insert into cs_evaluaties(wedstrijd_id,ploeg_id,speler_id,ratings,motm,weak_link,antwoorden,ingediend)
 values (:'w1',:'pl',:'s1',jsonb_build_object(:'s2',8),:'s2',:'s2','{"eigen_mentaliteit":8}',true);
select ratings, motm is not null as motm, weak_link is null as wl_uit from cs_evaluaties;
select pg_temp.verwacht_fout(format($$update cs_evaluaties set ratings=jsonb_build_object('%s',11) where speler_id='%s'$$,:'s2',:'s1'),'score 11');
select pg_temp.verwacht_fout(format($$update cs_evaluaties set ratings=jsonb_build_object('%s',7) where speler_id='%s'$$,:'s1',:'s1'),'zichzelf scoren');
select pg_temp.verwacht_fout(format($$update cs_evaluaties set motm='%s' where speler_id='%s'$$,:'s1',:'s1'),'zichzelf motm');
select pg_temp.verwacht_fout(format($$insert into cs_evaluaties(wedstrijd_id,ploeg_id,speler_id) values ('%s','%s','%s')$$,:'w1',:'pl',:'s2'),'evaluatie voor ander');
reset role;

select pg_temp.als('00000000-0000-0000-0000-0000000000a2');
select pg_temp.verwacht_fout(format($$insert into cs_evaluaties(wedstrijd_id,ploeg_id,speler_id) values ('%s','%s','%s')$$,:'w1',:'pl',:'s3'),'niet in opstelling');
select count(*) as ouder_ziet_evals from cs_evaluaties;
select count(*) as ouder_ziet_profielen from cs_speler_profiel;
reset role;

\echo === weak link aan + eval gesloten
select pg_temp.als('00000000-0000-0000-0000-00000000000c');
update cs_ploegen set weak_link_aan=true, eigenaar='00000000-0000-0000-0000-0000000000ff';
select weak_link_aan, eigenaar='00000000-0000-0000-0000-00000000000c' as eigenaar_onveranderd from cs_ploegen;
reset role;
select pg_temp.als('00000000-0000-0000-0000-0000000000a1');
update cs_evaluaties set weak_link=:'s2' where speler_id=:'s1';
select weak_link is not null as wl_nu_bewaard from cs_evaluaties;
reset role;
select pg_temp.als('00000000-0000-0000-0000-00000000000c');
update cs_wedstrijden set eval_open=false;
select count(*) as coach_ziet_evals from cs_evaluaties;
select length(cs_code_vernieuwen(:'pl'))=6 as nieuwe_code;
reset role;
select pg_temp.als('00000000-0000-0000-0000-0000000000a1');
select pg_temp.verwacht_fout(format($$update cs_evaluaties set antwoorden='{}' where speler_id='%s'$$,:'s1'),'eval gesloten');
select pg_temp.verwacht_fout($$select cs_code_vernieuwen('$$||:'pl'||$$')$$,'speler vernieuwt code');
reset role;

\echo === speler verlaat ploeg / coach verwijdert ploeg
select pg_temp.als('00000000-0000-0000-0000-0000000000a2');
delete from cs_leden where user_id=auth.uid();
select count(*) as ouder_na_vertrek from cs_ploegen;
reset role;
select pg_temp.als('00000000-0000-0000-0000-00000000000c');
delete from cs_ploegen;
reset role;
select (select count(*) from cs_ploegen) p,(select count(*) from cs_leden) l,(select count(*) from cs_spelers) s,(select count(*) from cs_evaluaties) e;
