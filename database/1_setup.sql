-- Math Mayhem: one-time database setup. Paste ALL of this into Supabase > SQL Editor and press Run.

create schema if not exists tts;
revoke all on schema tts from public, anon, authenticated;

create table if not exists tts.profiles (
  id text primary key,
  data jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table tts.profiles enable row level security;   -- no policies: nobody can touch the table directly

create table if not exists tts.admins (
  profile_id text primary key references tts.profiles(id) on update cascade,
  salt text not null,
  pin_hash text not null
);
alter table tts.admins enable row level security;

create or replace function tts.clean_name(p text) returns text language sql set search_path='' as $f$
  select left(btrim(regexp_replace(coalesce(p, ''), '[[:cntrl:]]', '', 'g')), 20)
$f$;

create or replace function tts.name_key(p text) returns text language sql immutable set search_path='' as $f$
  select lower(regexp_replace(coalesce(p,''), '[^[:alnum:]]', '', 'g'))
$f$;

create or replace function tts.code_id(p_code text) returns text language plpgsql set search_path='' as $f$
declare v_up text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
        v_key text := tts.name_key(p_code); v_legacy text;
begin
  if v_up ~ '^([A-Z]{3,8}[0-9]{4}|[A-Z]{9,30})$' then
    v_legacy := encode(extensions.digest('tts|' || v_up, 'sha256'), 'hex');
    if exists (select 1 from tts.profiles where id = v_legacy) then return v_legacy; end if;
  end if;
  if char_length(v_key) < 3 then return null; end if;
  return encode(extensions.digest('tts|n|' || v_key, 'sha256'), 'hex');
end $f$;

create or replace function tts.admin_ok(p_code text, p_pin text) returns text language plpgsql set search_path='' as $f$
declare v_id text := tts.code_id(p_code); v_ok boolean;
begin
  if v_id is null or p_pin is null then return null; end if;
  select (encode(extensions.digest(a.salt || p_pin, 'sha256'), 'hex') = a.pin_hash) into v_ok from tts.admins a where a.profile_id = v_id;
  if coalesce(v_ok,false) then return v_id; end if;
  perform pg_sleep(1);
  return null;
end $f$;

create or replace function public.tts_profile_create(p_name text, p_color integer default 0) returns text
language plpgsql security definer set search_path='' as $f$
declare
  v_now bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  v_name text := tts.clean_name(p_name); v_key text := tts.name_key(p_name); v_up text; v_data jsonb; v_id text;
begin
  if char_length(v_key) < 3 then raise exception 'bad_name'; end if;
  if (select count(*) from tts.profiles) >= 100000 then raise exception 'full'; end if;
  v_up := upper(regexp_replace(v_name, '[^A-Za-z0-9]', '', 'g'));
  if v_up ~ '^([A-Z]{3,8}[0-9]{4}|[A-Z]{9,30})$'
     and exists (select 1 from tts.profiles where id = encode(extensions.digest('tts|' || v_up, 'sha256'), 'hex')) then
    raise exception 'taken';
  end if;
  v_id := encode(extensions.digest('tts|n|' || v_key, 'sha256'), 'hex');
  v_data := jsonb_build_object('name', v_name, 'color', least(greatest(coalesce(p_color, 0), 0), 7),
    'rounds', 0, 'right', 0, 'wrong', 0, 'bestStreak', 0, 'bestScore', 0,
    'best', '{}'::jsonb, 'facts', '{}'::jsonb, 'recent', '[]'::jsonb, 'created', v_now, 'updated', v_now);
  insert into tts.profiles (id, data) values (v_id, v_data) on conflict (id) do nothing;
  if not found then raise exception 'taken'; end if;
  return v_name;
end $f$;

create or replace function public.tts_profile_get(p_code text) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.code_id(p_code); v_data jsonb;
begin
  if v_id is null then raise exception 'invalid_code'; end if;
  select data into v_data from tts.profiles where id = v_id;
  return v_data;
end $f$;

create or replace function public.tts_name_available(p_name text) returns boolean
language plpgsql security definer set search_path='' stable as $f$
declare v_key text := tts.name_key(p_name); v_up text := upper(regexp_replace(coalesce(p_name,''), '[^A-Za-z0-9]', '', 'g'));
begin
  if char_length(v_key) < 3 then return false; end if;
  if v_up ~ '^([A-Z]{3,8}[0-9]{4}|[A-Z]{9,30})$'
     and exists (select 1 from tts.profiles where id = encode(extensions.digest('tts|' || v_up, 'sha256'), 'hex')) then return false; end if;
  return not exists (select 1 from tts.profiles where id = encode(extensions.digest('tts|n|' || v_key, 'sha256'), 'hex'));
end $f$;

create or replace function public.tts_profile_set_identity(p_code text, p_name text, p_color integer) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.code_id(p_code); v_data jsonb;
begin
  if v_id is null then raise exception 'invalid_code'; end if;
  update tts.profiles
     set data = data || jsonb_build_object('name', tts.clean_name(p_name),
                                           'color', least(greatest(coalesce(p_color, 0), 0), 7),
                                           'updated', (extract(epoch from clock_timestamp()) * 1000)::bigint),
         updated_at = now()
   where id = v_id returning data into v_data;
  if v_data is null then raise exception 'not_found'; end if;
  return v_data;
end $f$;

create or replace function public.tts_profile_reset(p_code text) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.code_id(p_code); v_data jsonb;
begin
  if v_id is null then raise exception 'invalid_code'; end if;
  update tts.profiles
     set data = data || jsonb_build_object('rounds', 0, 'right', 0, 'wrong', 0, 'bestStreak', 0, 'bestScore', 0,
                                           'best', '{}'::jsonb, 'facts', '{}'::jsonb, 'recent', '[]'::jsonb,
                                           'updated', (extract(epoch from clock_timestamp()) * 1000)::bigint),
         updated_at = now()
   where id = v_id returning data into v_data;
  if v_data is null then raise exception 'not_found'; end if;
  return v_data;
end $f$;

create or replace function public.tts_profile_rename(p_code text, p_name text, p_color integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_old text := tts.code_id(p_code); v_key text := tts.name_key(p_name); v_name text := tts.clean_name(p_name);
        v_new text; v_data jsonb; v_up text := upper(regexp_replace(tts.clean_name(p_name), '[^A-Za-z0-9]', '', 'g'));
        v_now bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  if v_old is null then raise exception 'invalid_code'; end if;
  if char_length(v_key) < 3 then raise exception 'bad_name'; end if;
  perform 1 from tts.profiles where id = v_old for update;
  if not found then raise exception 'not_found'; end if;
  v_new := encode(extensions.digest('tts|n|' || v_key, 'sha256'), 'hex');
  if v_new <> v_old then
    if exists (select 1 from tts.profiles where id = v_new) then raise exception 'taken'; end if;
    if v_up ~ '^([A-Z]{3,8}[0-9]{4}|[A-Z]{9,30})$'
       and exists (select 1 from tts.profiles where id = encode(extensions.digest('tts|' || v_up, 'sha256'), 'hex')) then
      raise exception 'taken';
    end if;
    update tts.profiles set id = v_new where id = v_old;
  end if;
  update tts.profiles set data = data || jsonb_build_object('name', v_name, 'color', least(greatest(coalesce(p_color,0),0),7), 'updated', v_now), updated_at = now()
   where id = v_new returning data into v_data;
  return jsonb_build_object('code', v_name, 'data', v_data);
end $f$;

create or replace function public.tts_profile_apply_round(p_code text, p_delta jsonb) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare
  v_id text := tts.code_id(p_code);
  v_data jsonb; v_r int; v_w int; v_bs int; v_sc int; v_du int; v_mx int; v_m text; v_key text; v_best int;
  v_k text; v_fv jsonb; v_cur jsonb; v_nr int; v_nm int; v_entry jsonb; v_recent jsonb;
  v_now bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  if v_id is null then raise exception 'invalid_code'; end if;
  if p_delta is null or jsonb_typeof(p_delta) <> 'object' or pg_column_size(p_delta) > 20000 then raise exception 'bad_round'; end if;
  select data into v_data from tts.profiles where id = v_id for update;
  if v_data is null then raise exception 'not_found'; end if;
  v_r  := least(greatest(coalesce((p_delta->>'r')::int, 0), 0), 500);
  v_w  := least(greatest(coalesce((p_delta->>'w')::int, 0), 0), 500);
  v_bs := least(greatest(coalesce((p_delta->>'bs')::int, 0), 0), 500);
  v_sc := least(greatest(coalesce((p_delta->>'sc')::int, 0), 0), 20000);
  v_du := coalesce((p_delta->>'du')::int, 60);
  if v_du not in (45, 60, 90) then v_du := 60; end if;
  v_mx := least(greatest(coalesce((p_delta->>'mx')::int, 12), 6), 12);
  v_m  := case when p_delta->>'m' = 'solo' then 'solo' else 'room' end;
  if v_r + v_w = 0 then return v_data; end if;

  v_data := v_data || jsonb_build_object('best', coalesce(v_data->'best', '{}'::jsonb),
                                         'facts', coalesce(v_data->'facts', '{}'::jsonb),
                                         'recent', coalesce(v_data->'recent', '[]'::jsonb));
  v_data := jsonb_set(v_data, '{rounds}', to_jsonb(coalesce((v_data->>'rounds')::int, 0) + 1));
  v_data := jsonb_set(v_data, '{right}', to_jsonb(coalesce((v_data->>'right')::bigint, 0) + v_r));
  v_data := jsonb_set(v_data, '{wrong}', to_jsonb(coalesce((v_data->>'wrong')::bigint, 0) + v_w));
  v_data := jsonb_set(v_data, '{bestStreak}', to_jsonb(greatest(coalesce((v_data->>'bestStreak')::int, 0), v_bs)));
  v_data := jsonb_set(v_data, '{bestScore}', to_jsonb(greatest(coalesce((v_data->>'bestScore')::int, 0), v_sc)));
  v_key := v_du::text || '-' || v_mx::text;
  v_best := greatest(coalesce((v_data->'best'->>v_key)::int, 0), v_sc);
  v_data := jsonb_set(v_data, array['best', v_key], to_jsonb(v_best), true);

  for v_k, v_fv in
    select key, value from jsonb_each(case when jsonb_typeof(p_delta->'fr') = 'object' then p_delta->'fr' else '{}'::jsonb end) limit 200
  loop
    continue when v_k !~ '^[0-9]{1,2}x[0-9]{1,2}$' or jsonb_typeof(v_fv) <> 'array';
    v_nr := least(greatest(coalesce((v_fv->>0)::int, 0), 0), 500);
    v_nm := least(greatest(coalesce((v_fv->>1)::int, 0), 0), 500);
    v_cur := coalesce(v_data->'facts'->v_k, '[0,0]'::jsonb);
    v_data := jsonb_set(v_data, array['facts', v_k],
      jsonb_build_array(coalesce((v_cur->>0)::int, 0) + v_nr, coalesce((v_cur->>1)::int, 0) + v_nm), true);
  end loop;

  v_entry := jsonb_build_object('t', v_now, 'sc', v_sc, 'r', v_r, 'w', v_w, 'du', v_du, 'mx', v_mx, 'm', v_m);
  select coalesce(jsonb_agg(s.e order by s.ord), '[]'::jsonb) into v_recent from (
    select 0::bigint as ord, v_entry as e
    union all
    select t.o, t.x from jsonb_array_elements(coalesce(v_data->'recent', '[]'::jsonb)) with ordinality as t(x, o)
  ) s where s.ord < 10;
  v_data := jsonb_set(v_data, '{recent}', v_recent);

  if jsonb_exists(p_delta, 'name') then
    v_data := jsonb_set(v_data, '{name}', to_jsonb(tts.clean_name(p_delta->>'name')));
  end if;
  if jsonb_exists(p_delta, 'color') then
    v_data := jsonb_set(v_data, '{color}', to_jsonb(least(greatest(coalesce((p_delta->>'color')::int, 0), 0), 7)));
  end if;
  v_data := jsonb_set(v_data, '{updated}', to_jsonb(v_now));

  update tts.profiles set data = v_data, updated_at = now() where id = v_id;
  return v_data;
end $f$;

create or replace function public.tts_leaderboard(p_code text default null) returns jsonb
language plpgsql security definer set search_path='' stable as $f$
declare v_id text := tts.code_id(p_code); v_top jsonb; v_me jsonb; v_total int;
begin
  select count(*) into v_total from tts.profiles where coalesce((data->>'rounds')::int,0) > 0;
  select coalesce(jsonb_agg(x order by (x->>'rank')::int), '[]'::jsonb) into v_top from (
    select jsonb_build_object('rank', row_number() over (order by (data->>'bestScore')::int desc, (data->>'rounds')::int desc),
      'name', data->>'name', 'color', (data->>'color')::int, 'best', (data->>'bestScore')::int, 'streak', (data->>'bestStreak')::int,
      'rounds', (data->>'rounds')::int,
      'acc', case when (data->>'right')::int + (data->>'wrong')::int > 0 then round(100.0*(data->>'right')::int/((data->>'right')::int+(data->>'wrong')::int)) else 0 end) as x
    from tts.profiles where coalesce((data->>'rounds')::int,0) > 0
    order by (data->>'bestScore')::int desc, (data->>'rounds')::int desc limit 10) t;
  if v_id is not null then
    select jsonb_build_object('rank', r) into v_me from (
      select id, row_number() over (order by (data->>'bestScore')::int desc, (data->>'rounds')::int desc) as r
      from tts.profiles where coalesce((data->>'rounds')::int,0) > 0) q where id = v_id;
  end if;
  return jsonb_build_object('total', v_total, 'top', v_top, 'me', v_me);
end $f$;

-- teacher tools
create or replace function public.tts_admin_check(p_code text, p_pin text) returns boolean
language plpgsql security definer set search_path='' as $f$
begin return tts.admin_ok(p_code, p_pin) is not null; end $f$;

create or replace function public.tts_admin_list(p_code text, p_pin text) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin);
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('handle', left(id,12), 'name', data->>'name', 'rounds', (data->>'rounds')::int,
            'best', (data->>'bestScore')::int, 'me', id = v_id) order by created_at) from tts.profiles), '[]'::jsonb);
end $f$;

create or replace function public.tts_admin_delete(p_code text, p_pin text, p_handle text) returns int
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin); n int;
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  if p_handle is null or char_length(p_handle) <> 12 then raise exception 'bad_handle'; end if;
  delete from tts.profiles where left(id,12) = p_handle and id <> v_id;
  get diagnostics n = row_count;
  return n;
end $f$;

create or replace function public.tts_admin_set_pin(p_code text, p_pin text, p_new text) returns boolean
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin); v_salt text := encode(extensions.gen_random_bytes(8),'hex');
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  if char_length(coalesce(p_new,'')) < 6 then raise exception 'weak_pin'; end if;
  update tts.admins set salt = v_salt, pin_hash = encode(extensions.digest(v_salt || p_new, 'sha256'), 'hex') where profile_id = v_id;
  return true;
end $f$;

-- only the game's own functions are callable from the browser
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.tts_profile_create(text,integer), public.tts_profile_get(text), public.tts_name_available(text),
  public.tts_profile_set_identity(text,text,integer), public.tts_profile_reset(text),
  public.tts_profile_rename(text,text,integer), public.tts_profile_apply_round(text,jsonb),
  public.tts_leaderboard(text), public.tts_admin_check(text,text), public.tts_admin_list(text,text),
  public.tts_admin_delete(text,text,text), public.tts_admin_set_pin(text,text,text)
  to anon, authenticated;
