create role anon nologin; create role authenticated nologin;
create schema auth;
create table auth.users(id uuid primary key, email text, raw_user_meta_data jsonb default '{}');
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
grant usage on schema auth to anon, authenticated; grant execute on function auth.uid() to anon, authenticated;
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
insert into auth.users(id,email) values
 ('00000000-0000-0000-0000-00000000000c','coach@x.be'),
 ('00000000-0000-0000-0000-0000000000a1','speler1@x.be'),
 ('00000000-0000-0000-0000-0000000000a2','ouder3@x.be'),
 ('00000000-0000-0000-0000-0000000000ff','vreemde@x.be');
