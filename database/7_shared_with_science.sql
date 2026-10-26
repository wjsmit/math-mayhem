-- Math Mayhem + Science Mayhem on ONE database (this Supabase project).
-- One profile per student (name, colour, avatar live in tts.profiles), one class list, one teacher PIN.
-- Maths progress stays in tts.profiles.data; science progress lives in sci.profiles.data (same id).
-- Science levels (topic + stage) are two extra columns on the shared class list.
-- Already applied by Claude through the Supabase connector (migration names: shared_science_part1, shared_science_part2).

create schema if not exists sci;
create table if not exists sci.profiles (
  id text primary key,
  data jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table sci.profiles enable row level security;

alter table tts.roster  add column if not exists sci_track text not null default 'ptable';
alter table tts.roster  add column if not exists stage     text not null default 'ks3';
alter table tts.roster  add column if not exists hidden    boolean not null default false;
alter table tts.classes add column if not exists alt_code  text;

-- empty science stats
create or replace function tts.sci_blank() returns jsonb language sql set search_path = '' as $f$
  select jsonb_build_object('rounds',0,'right',0,'wrong',0,'bestStreak',0,'bestScore',0,
    'best','{}'::jsonb,'facts','{}'::jsonb,'recent','[]'::jsonb,
    'created',(extract(epoch from clock_timestamp())*1000)::bigint,'updated',(extract(epoch from clock_timestamp())*1000)::bigint)
$f$;

-- every new maths profile gets an empty science record with the same id
create or replace function tts.on_profile_insert() returns trigger language plpgsql set search_path = '' as $f$
begin
  insert into sci.profiles (id, data) values (new.id, tts.sci_blank())
  on conflict (id) do update set data = excluded.data, updated_at = now();
  return new;
end $f$;
create trigger profiles_sci_insert after insert on tts.profiles for each row execute function tts.on_profile_insert();

-- renaming a profile changes its id: carry the science record and the class-list link across
create or replace function tts.on_profile_rekey() returns trigger language plpgsql set search_path = '' as $f$
begin
  insert into sci.profiles (id, data, created_at)
    select new.id, s.data, s.created_at from sci.profiles s where s.id = old.id
  on conflict (id) do update set data = excluded.data, updated_at = now();
  update tts.roster set profile_id = new.id where profile_id = old.id;
  return new;
end $f$;
create trigger profiles_rekey after update of id on tts.profiles for each row when (old.id is distinct from new.id) execute function tts.on_profile_rekey();

-- science data as the science game wants it: science stats + the shared name, colour and avatar
create or replace function tts.sci_data(p_id text) returns jsonb language sql stable set search_path = '' as $f$
  select s.data
         || jsonb_build_object('name', t.data->>'name', 'color', coalesce((t.data->>'color')::int, 0))
         || case when jsonb_exists(t.data, 'av') then jsonb_build_object('av', t.data->>'av') else '{}'::jsonb end
  from sci.profiles s join tts.profiles t on t.id = s.id where s.id = p_id
$f$;
create or replace function tts.sci_ensure(p_id text) returns void language sql set search_path = '' as $f$
  insert into sci.profiles (id, data) select t.id, tts.sci_blank() from tts.profiles t where t.id = p_id on conflict (id) do nothing
$f$;

-- ===== maths functions that need to know about the shared class list =====
create or replace function public.tts_class_open(p_class text, p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_pid text := tts.code_id(p_code); v_class tts.classes; v_up text := upper(regexp_replace(coalesce(p_class,''), '[^A-Za-z]', '', 'g'));
begin
  if v_pid is null or not exists (select 1 from tts.profiles where id = v_pid) then raise exception 'not_found'; end if;
  select * into v_class from tts.classes where code = v_up or alt_code = v_up;
  if v_class.id is null then perform pg_sleep(1); raise exception 'no_class'; end if;
  return jsonb_build_object('label', v_class.label,
    'names', coalesce((select jsonb_agg(jsonb_build_object('rid', r.id, 'name', r.real_name) order by r.real_name)
                         from tts.roster r where r.class_id = v_class.id and r.profile_id is null and not r.hidden), '[]'::jsonb));
end $f$;

create or replace function public.tts_class_claim(p_class text, p_code text, p_rid bigint) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_pid text := tts.code_id(p_code); v_class tts.classes; v_up text := upper(regexp_replace(coalesce(p_class,''), '[^A-Za-z]', '', 'g')); n int; v_track text;
begin
  if v_pid is null or not exists (select 1 from tts.profiles where id = v_pid) then raise exception 'not_found'; end if;
  select * into v_class from tts.classes where code = v_up or alt_code = v_up;
  if v_class.id is null then raise exception 'no_class'; end if;
  if exists (select 1 from tts.roster where profile_id = v_pid) then raise exception 'already_linked'; end if;
  update tts.roster set profile_id = v_pid where id = p_rid and class_id = v_class.id and profile_id is null and not hidden returning track into v_track;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'name_taken'; end if;
  return jsonb_build_object('class', v_class.label, 'track', v_track);
end $f$;

create or replace function public.tts_admin_roster(p_code text, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin);
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  return jsonb_build_object(
    'classes', coalesce((select jsonb_agg(jsonb_build_object('label', label, 'code', code) order by label) from tts.classes), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'rid', r.id, 'class', c.label, 'real', r.real_name, 'track', r.track, 'user', p.data->>'name',
        'rounds', (p.data->>'rounds')::int, 'right', (p.data->>'right')::int, 'wrong', (p.data->>'wrong')::int,
        'best', (p.data->>'bestScore')::int, 'last', (p.data->>'updated')::bigint, 'facts', p.data->'facts')
        order by c.label, r.real_name)
      from tts.roster r join tts.classes c on c.id = r.class_id left join tts.profiles p on p.id = r.profile_id where not r.hidden), '[]'::jsonb));
end $f$;

create or replace function public.tts_admin_import(p_code text, p_pin text, p_label text, p_names text[], p_track text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin); v_label text := left(btrim(coalesce(p_label,'')), 20); v_cid bigint; v_cc text; v_n text; v_add int := 0; n int; i int;
        v_track text := case when p_track = any (array['tables','addsub','bodmas','frac','alg1','alg2','alg3','alg4','muldiv','fracs','mixed','ineq']) then p_track else 'tables' end;
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  if v_label = '' then raise exception 'bad_label'; end if;
  if coalesce(array_length(p_names,1),0) > 80 then raise exception 'too_many'; end if;
  select id, code into v_cid, v_cc from tts.classes where lower(label) = lower(v_label);
  if v_cid is null then
    for i in 1..20 loop
      v_cc := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + floor(random()*24)::int, 1), '') from generate_series(1,5));
      begin
        insert into tts.classes (label, code) values (v_label, v_cc) returning id into v_cid;
        exit;
      exception when unique_violation then v_cid := null;
      end;
    end loop;
    if v_cid is null then raise exception 'try_again'; end if;
  end if;
  foreach v_n in array coalesce(p_names, array[]::text[]) loop
    v_n := left(btrim(regexp_replace(coalesce(v_n,''), '[[:cntrl:]]', '', 'g')), 40);
    if char_length(v_n) < 2 then continue; end if;
    insert into tts.roster (class_id, real_name, track) values (v_cid, v_n, v_track)
      on conflict (class_id, (lower(real_name))) do update set hidden = false, track = excluded.track where tts.roster.hidden;
    get diagnostics n = row_count;
    v_add := v_add + n;
  end loop;
  return jsonb_build_object('class', v_label, 'code', v_cc, 'added', v_add);
end $f$;

-- teacher: take a name off the class list (hidden, never lost: adding the name again brings it back)
create or replace function public.tts_admin_roster_remove(p_code text, p_pin text, p_rid bigint) returns int
language plpgsql security definer set search_path = '' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin); n int;
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  update tts.roster set hidden = true, profile_id = null where id = p_rid;
  get diagnostics n = row_count;
  return n;
end $f$;

-- ===== science functions (same names the science game already calls) =====
create or replace function public.sci_name_available(p_name text) returns boolean
language sql stable security definer set search_path = '' as $f$ select public.tts_name_available(p_name) $f$;

create or replace function public.sci_profile_create(p_name text, p_color integer default 0) returns text
language sql security definer set search_path = '' as $f$ select public.tts_profile_create(p_name, p_color) $f$;

create or replace function public.sci_profile_get(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_id text := tts.code_id(p_code);
begin
  if v_id is null then raise exception 'invalid_code'; end if;
  perform tts.sci_ensure(v_id);
  return tts.sci_data(v_id);
end $f$;

create or replace function public.sci_profile_rename(p_code text, p_name text, p_color integer default 0) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare r jsonb; v_id text;
begin
  r := public.tts_profile_rename(p_code, p_name, p_color);
  v_id := tts.code_id(r->>'code');
  perform tts.sci_ensure(v_id);
  return jsonb_build_object('code', r->>'code', 'data', tts.sci_data(v_id));
end $f$;

create or replace function public.sci_profile_set_identity(p_code text, p_name text, p_color integer) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_id text := tts.code_id(p_code);
begin
  if v_id is null then raise exception 'invalid_code'; end if;
  perform public.tts_profile_set_identity(p_code, p_name, p_color);
  perform tts.sci_ensure(v_id);
  return tts.sci_data(v_id);
end $f$;

create or replace function public.sci_profile_set_avatar(p_code text, p_av text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_id text := tts.code_id(p_code);
begin
  if v_id is null then raise exception 'invalid_code'; end if;
  perform public.tts_profile_set_avatar(p_code, p_av);
  perform tts.sci_ensure(v_id);
  return tts.sci_data(v_id);
end $f$;

create or replace function public.sci_profile_reset(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_id text := tts.code_id(p_code);
begin
  if v_id is null then raise exception 'invalid_code'; end if;
  perform tts.sci_ensure(v_id);
  update sci.profiles
     set data = data || jsonb_build_object('rounds', 0, 'right', 0, 'wrong', 0, 'bestStreak', 0, 'bestScore', 0,
                                           'best', '{}'::jsonb, 'facts', '{}'::jsonb, 'recent', '[]'::jsonb,
                                           'updated', (extract(epoch from clock_timestamp()) * 1000)::bigint),
         updated_at = now()
   where id = v_id;
  if not found then raise exception 'not_found'; end if;
  return tts.sci_data(v_id);
end $f$;

create or replace function public.sci_profile_apply_round(p_code text, p_delta jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  v_id text := tts.code_id(p_code);
  v_data jsonb; v_r int; v_w int; v_bs int; v_sc int; v_du int; v_mx int; v_m text; v_key text; v_best int; v_tk text; v_sg text;
  v_k text; v_fv jsonb; v_cur jsonb; v_nr int; v_nm int; v_entry jsonb; v_recent jsonb;
  v_now bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  if v_id is null then raise exception 'invalid_code'; end if;
  if p_delta is null or jsonb_typeof(p_delta) <> 'object' or pg_column_size(p_delta) > 20000 then raise exception 'bad_round'; end if;
  perform tts.sci_ensure(v_id);
  select data into v_data from sci.profiles where id = v_id for update;
  if v_data is null then raise exception 'not_found'; end if;
  v_r  := least(greatest(coalesce((p_delta->>'r')::int, 0), 0), 500);
  v_w  := least(greatest(coalesce((p_delta->>'w')::int, 0), 0), 500);
  v_bs := least(greatest(coalesce((p_delta->>'bs')::int, 0), 0), 500);
  v_sc := least(greatest(coalesce((p_delta->>'sc')::int, 0), 0), 20000);
  v_du := coalesce((p_delta->>'du')::int, 60);
  if v_du not in (45, 60, 90) then v_du := 60; end if;
  v_mx := least(greatest(coalesce((p_delta->>'mx')::int, 12), 6), 12);
  v_m  := case when p_delta->>'m' = 'solo' then 'solo' else 'room' end;
  v_tk := case when p_delta->>'tk' = any (array['ptable','symbols','bonding','motion','forces','geo','states','cells','mixed']) then p_delta->>'tk' else 'ptable' end;
  v_sg := case when p_delta->>'sg' = 'ig' then 'ig' else 'ks3' end;
  if v_r + v_w = 0 then return tts.sci_data(v_id); end if;

  v_data := v_data || jsonb_build_object('best', coalesce(v_data->'best', '{}'::jsonb),
                                         'facts', coalesce(v_data->'facts', '{}'::jsonb),
                                         'recent', coalesce(v_data->'recent', '[]'::jsonb));
  v_data := jsonb_set(v_data, '{rounds}', to_jsonb(coalesce((v_data->>'rounds')::int, 0) + 1));
  v_data := jsonb_set(v_data, '{right}', to_jsonb(coalesce((v_data->>'right')::bigint, 0) + v_r));
  v_data := jsonb_set(v_data, '{wrong}', to_jsonb(coalesce((v_data->>'wrong')::bigint, 0) + v_w));
  v_data := jsonb_set(v_data, '{bestStreak}', to_jsonb(greatest(coalesce((v_data->>'bestStreak')::int, 0), v_bs)));
  v_data := jsonb_set(v_data, '{bestScore}', to_jsonb(greatest(coalesce((v_data->>'bestScore')::int, 0), v_sc)));
  v_key := v_du::text || '-' || v_tk || '-' || v_sg;
  v_best := greatest(coalesce((v_data->'best'->>v_key)::int, 0), v_sc);
  v_data := jsonb_set(v_data, array['best', v_key], to_jsonb(v_best), true);

  for v_k, v_fv in
    select key, value from jsonb_each(case when jsonb_typeof(p_delta->'fr') = 'object' then p_delta->'fr' else '{}'::jsonb end) limit 200
  loop
    continue when v_k !~ '^[a-z]{2,6}[0-9]{1,4}$' or jsonb_typeof(v_fv) <> 'array';
    v_nr := least(greatest(coalesce((v_fv->>0)::int, 0), 0), 500);
    v_nm := least(greatest(coalesce((v_fv->>1)::int, 0), 0), 500);
    v_cur := coalesce(v_data->'facts'->v_k, '[0,0]'::jsonb);
    v_data := jsonb_set(v_data, array['facts', v_k],
      jsonb_build_array(coalesce((v_cur->>0)::int, 0) + v_nr, coalesce((v_cur->>1)::int, 0) + v_nm), true);
  end loop;

  v_entry := jsonb_build_object('t', v_now, 'sc', v_sc, 'r', v_r, 'w', v_w, 'du', v_du, 'mx', v_mx, 'm', v_m, 'tk', v_tk, 'sg', v_sg);
  select coalesce(jsonb_agg(s.e order by s.ord), '[]'::jsonb) into v_recent from (
    select 0::bigint as ord, v_entry as e
    union all
    select t.o, t.x from jsonb_array_elements(coalesce(v_data->'recent', '[]'::jsonb)) with ordinality as t(x, o)
  ) s where s.ord < 10;
  v_data := jsonb_set(v_data, '{recent}', v_recent);
  v_data := jsonb_set(v_data, '{updated}', to_jsonb(v_now));

  update sci.profiles set data = v_data, updated_at = now() where id = v_id;
  return tts.sci_data(v_id);
end $f$;

create or replace function public.sci_leaderboard(p_code text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_id text := tts.code_id(p_code); v_top jsonb; v_me jsonb; v_total int;
begin
  select count(*) into v_total from sci.profiles s join tts.profiles t on t.id = s.id where coalesce((s.data->>'rounds')::int,0) > 0;
  select coalesce(jsonb_agg(x order by (x->>'rank')::int), '[]'::jsonb) into v_top from (
    select jsonb_build_object('rank', row_number() over (order by (s.data->>'bestScore')::int desc, (s.data->>'rounds')::int desc),
      'name', coalesce(r.real_name, t.data->>'name'), 'color', (t.data->>'color')::int, 'av', t.data->>'av', 'best', (s.data->>'bestScore')::int, 'streak', (s.data->>'bestStreak')::int,
      'rounds', (s.data->>'rounds')::int,
      'acc', case when (s.data->>'right')::int + (s.data->>'wrong')::int > 0 then round(100.0*(s.data->>'right')::int/((s.data->>'right')::int+(s.data->>'wrong')::int)) else 0 end) as x
    from sci.profiles s join tts.profiles t on t.id = s.id left join tts.roster r on r.profile_id = s.id
    where coalesce((s.data->>'rounds')::int,0) > 0
    order by (s.data->>'bestScore')::int desc, (s.data->>'rounds')::int desc limit 10) q;
  if v_id is not null then
    select jsonb_build_object('rank', rk) into v_me from (
      select s.id, row_number() over (order by (s.data->>'bestScore')::int desc, (s.data->>'rounds')::int desc) as rk
      from sci.profiles s join tts.profiles t on t.id = s.id where coalesce((s.data->>'rounds')::int,0) > 0) q where id = v_id;
  end if;
  return jsonb_build_object('total', v_total, 'top', v_top, 'me', v_me);
end $f$;

create or replace function public.sci_class_open(p_class text, p_code text) returns jsonb
language sql security definer set search_path = '' as $f$ select public.tts_class_open(p_class, p_code) $f$;

create or replace function public.sci_class_claim(p_class text, p_code text, p_rid bigint) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare r jsonb := public.tts_class_claim(p_class, p_code, p_rid); v_track text; v_stage text;
begin
  select sci_track, stage into v_track, v_stage from tts.roster where id = p_rid;
  return jsonb_build_object('class', r->>'class', 'track', v_track, 'stage', v_stage);
end $f$;

create or replace function public.sci_class_mine(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_pid text := tts.code_id(p_code); v_label text; v_track text; v_stage text;
begin
  if v_pid is null then return null; end if;
  select c.label, r.sci_track, r.stage into v_label, v_track, v_stage from tts.roster r join tts.classes c on c.id = r.class_id where r.profile_id = v_pid;
  if v_label is null then return null; end if;
  return jsonb_build_object('class', v_label, 'track', v_track, 'stage', v_stage);
end $f$;

create or replace function public.sci_admin_check(p_code text, p_pin text) returns boolean
language sql security definer set search_path = '' as $f$ select public.tts_admin_check(p_code, p_pin) $f$;

create or replace function public.sci_admin_set_pin(p_code text, p_pin text, p_new text) returns boolean
language sql security definer set search_path = '' as $f$ select public.tts_admin_set_pin(p_code, p_pin, p_new) $f$;

create or replace function public.sci_admin_unlink(p_code text, p_pin text, p_rid bigint) returns integer
language sql security definer set search_path = '' as $f$ select public.tts_admin_unlink(p_code, p_pin, p_rid) $f$;

create or replace function public.sci_admin_roster_remove(p_code text, p_pin text, p_rid bigint) returns integer
language sql security definer set search_path = '' as $f$ select public.tts_admin_roster_remove(p_code, p_pin, p_rid) $f$;

create or replace function public.sci_admin_list(p_code text, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin);
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('handle', left(t.id,12), 'name', t.data->>'name', 'rounds', coalesce((s.data->>'rounds')::int,0),
            'best', coalesce((s.data->>'bestScore')::int,0), 'me', t.id = v_id) order by t.created_at)
    from tts.profiles t left join sci.profiles s on s.id = t.id), '[]'::jsonb);
end $f$;

create or replace function public.sci_admin_roster(p_code text, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin);
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  return jsonb_build_object(
    'classes', coalesce((select jsonb_agg(jsonb_build_object('label', label, 'code', code) order by label) from tts.classes), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'rid', r.id, 'class', c.label, 'real', r.real_name, 'track', r.sci_track, 'stage', r.stage, 'user', t.data->>'name',
        'rounds', (s.data->>'rounds')::int, 'right', (s.data->>'right')::int, 'wrong', (s.data->>'wrong')::int,
        'best', (s.data->>'bestScore')::int, 'last', (s.data->>'updated')::bigint, 'facts', s.data->'facts')
        order by c.label, r.real_name)
      from tts.roster r join tts.classes c on c.id = r.class_id
      left join tts.profiles t on t.id = r.profile_id left join sci.profiles s on s.id = r.profile_id where not r.hidden), '[]'::jsonb));
end $f$;

create or replace function public.sci_admin_import(p_code text, p_pin text, p_label text, p_names text[], p_track text, p_stage text default 'ks3') returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin); v_label text := left(btrim(coalesce(p_label,'')), 20); v_cid bigint; v_cc text; v_n text; v_add int := 0; v_stage text := case when p_stage = 'ig' then 'ig' else 'ks3' end; n int; i int;
        v_track text := case when p_track = any (array['ptable','symbols','bonding','motion','forces','geo','states','cells','mixed']) then p_track else 'ptable' end;
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  if v_label = '' then raise exception 'bad_label'; end if;
  if coalesce(array_length(p_names,1),0) > 80 then raise exception 'too_many'; end if;
  select id, code into v_cid, v_cc from tts.classes where lower(label) = lower(v_label);
  if v_cid is null then
    for i in 1..20 loop
      v_cc := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + floor(random()*24)::int, 1), '') from generate_series(1,5));
      begin
        insert into tts.classes (label, code) values (v_label, v_cc) returning id into v_cid;
        exit;
      exception when unique_violation then v_cid := null;
      end;
    end loop;
    if v_cid is null then raise exception 'try_again'; end if;
  end if;
  foreach v_n in array coalesce(p_names, array[]::text[]) loop
    v_n := left(btrim(regexp_replace(coalesce(v_n,''), '[[:cntrl:]]', '', 'g')), 40);
    if char_length(v_n) < 2 then continue; end if;
    insert into tts.roster (class_id, real_name, sci_track, stage) values (v_cid, v_n, v_track, v_stage)
      on conflict (class_id, (lower(real_name))) do update set hidden = false, sci_track = excluded.sci_track, stage = excluded.stage where tts.roster.hidden;
    get diagnostics n = row_count;
    v_add := v_add + n;
  end loop;
  return jsonb_build_object('class', v_label, 'code', v_cc, 'added', v_add);
end $f$;

create or replace function public.sci_admin_set_level(p_code text, p_pin text, p_rid bigint, p_track text, p_stage text) returns integer
language plpgsql security definer set search_path = '' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin); n int;
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  if not (p_track = any (array['ptable','symbols','bonding','motion','forces','geo','states','cells','mixed'])) then raise exception 'bad_track'; end if;
  if not (p_stage = any (array['ks3','ig'])) then raise exception 'bad_stage'; end if;
  update tts.roster set sci_track = p_track, stage = p_stage where id = p_rid;
  get diagnostics n = row_count;
  return n;
end $f$;

revoke execute on function
  public.tts_admin_roster_remove(text,text,bigint),
  public.sci_name_available(text), public.sci_profile_create(text,integer), public.sci_profile_get(text), public.sci_profile_rename(text,text,integer),
  public.sci_profile_set_identity(text,text,integer), public.sci_profile_set_avatar(text,text), public.sci_profile_reset(text), public.sci_profile_apply_round(text,jsonb),
  public.sci_leaderboard(text), public.sci_class_open(text,text), public.sci_class_claim(text,text,bigint), public.sci_class_mine(text),
  public.sci_admin_check(text,text), public.sci_admin_set_pin(text,text,text), public.sci_admin_unlink(text,text,bigint), public.sci_admin_roster_remove(text,text,bigint),
  public.sci_admin_list(text,text), public.sci_admin_roster(text,text), public.sci_admin_import(text,text,text,text[],text,text), public.sci_admin_set_level(text,text,bigint,text,text)
  from public, anon, authenticated;
grant execute on function
  public.tts_admin_roster_remove(text,text,bigint),
  public.sci_name_available(text), public.sci_profile_create(text,integer), public.sci_profile_get(text), public.sci_profile_rename(text,text,integer),
  public.sci_profile_set_identity(text,text,integer), public.sci_profile_set_avatar(text,text), public.sci_profile_reset(text), public.sci_profile_apply_round(text,jsonb),
  public.sci_leaderboard(text), public.sci_class_open(text,text), public.sci_class_claim(text,text,bigint), public.sci_class_mine(text),
  public.sci_admin_check(text,text), public.sci_admin_set_pin(text,text,text), public.sci_admin_unlink(text,text,bigint), public.sci_admin_roster_remove(text,text,bigint),
  public.sci_admin_list(text,text), public.sci_admin_roster(text,text), public.sci_admin_import(text,text,text,text[],text,text), public.sci_admin_set_level(text,text,bigint,text,text)
  to anon, authenticated;
