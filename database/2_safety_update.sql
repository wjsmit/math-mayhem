-- Times Table Showdown: safety update. Paste ALL of this into Supabase > SQL Editor and press Run. Safe to run more than once.

-- 1) Each profile gets a secret "owner key" kept on the student's device. Only that device can change the name.
alter table tts.profiles add column if not exists owner_hash text;

create or replace function public.tts_profile_claim(p_code text) returns text
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.code_id(p_code); v_tok text := encode(extensions.gen_random_bytes(16),'hex');
begin
  if v_id is null then raise exception 'invalid_code'; end if;
  update tts.profiles set owner_hash = encode(extensions.digest(v_tok, 'sha256'), 'hex')
   where id = v_id and owner_hash is null;
  if found then return v_tok; end if;
  return null;   -- already owned by another device
end $f$;

drop function if exists public.tts_profile_rename(text, text, integer);
create or replace function public.tts_profile_rename(p_code text, p_name text, p_color integer, p_token text) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_old text := tts.code_id(p_code); v_key text := tts.name_key(p_name); v_name text := tts.clean_name(p_name);
        v_new text; v_data jsonb; v_owner text; v_up text := upper(regexp_replace(tts.clean_name(p_name), '[^A-Za-z0-9]', '', 'g'));
        v_now bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  if v_old is null then raise exception 'invalid_code'; end if;
  if char_length(v_key) < 3 then raise exception 'bad_name'; end if;
  select owner_hash into v_owner from tts.profiles where id = v_old for update;
  if not found then raise exception 'not_found'; end if;
  if v_owner is null or p_token is null or v_owner <> encode(extensions.digest(p_token, 'sha256'), 'hex') then
    raise exception 'not_owner';
  end if;
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

-- colour changes stay open; the name can only change its capitals/spacing here (real renames need the owner key)
create or replace function public.tts_profile_set_identity(p_code text, p_name text, p_color integer) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.code_id(p_code); v_data jsonb;
begin
  if v_id is null then raise exception 'invalid_code'; end if;
  update tts.profiles
     set data = data || jsonb_build_object(
           'name', case when tts.name_key(p_name) = tts.name_key(data->>'name') and char_length(tts.clean_name(p_name)) > 0
                        then tts.clean_name(p_name) else data->>'name' end,
           'color', least(greatest(coalesce(p_color, 0), 0), 7),
           'updated', (extract(epoch from clock_timestamp()) * 1000)::bigint),
         updated_at = now()
   where id = v_id returning data into v_data;
  if v_data is null then raise exception 'not_found'; end if;
  return v_data;
end $f$;

-- 2) Realistic score limits: at most 120 answers in a round, at most 20 points per right answer,
--    and at most one saved round every 55 seconds per profile.
create or replace function public.tts_profile_apply_round(p_code text, p_delta jsonb) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare
  v_id text := tts.code_id(p_code);
  v_data jsonb; v_r int; v_w int; v_bs int; v_sc int; v_du int; v_mx int; v_m text; v_key text; v_best int;
  v_k text; v_fv jsonb; v_cur jsonb; v_nr int; v_nm int; v_entry jsonb; v_recent jsonb; v_last bigint;
  v_now bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  if v_id is null then raise exception 'invalid_code'; end if;
  if p_delta is null or jsonb_typeof(p_delta) <> 'object' or pg_column_size(p_delta) > 20000 then raise exception 'bad_round'; end if;
  select data into v_data from tts.profiles where id = v_id for update;
  if v_data is null then raise exception 'not_found'; end if;
  v_r  := least(greatest(coalesce((p_delta->>'r')::int, 0), 0), 120);
  v_w  := least(greatest(coalesce((p_delta->>'w')::int, 0), 0), 120 - v_r);
  v_bs := least(greatest(coalesce((p_delta->>'bs')::int, 0), 0), v_r);
  v_sc := least(greatest(coalesce((p_delta->>'sc')::int, 0), 0), v_r * 20);
  v_du := 60;
  v_mx := 12;
  v_m  := case when p_delta->>'m' = 'solo' then 'solo' else 'room' end;
  if v_r + v_w = 0 then return v_data; end if;
  v_last := coalesce((v_data->'recent'->0->>'t')::bigint, 0);
  if v_now - v_last < 55000 then raise exception 'too_soon'; end if;

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
    continue when v_k !~ '^([1-9]|1[0-2])x([1-9]|1[0-2])$' or jsonb_typeof(v_fv) <> 'array';
    v_nr := least(greatest(coalesce((v_fv->>0)::int, 0), 0), 120);
    v_nm := least(greatest(coalesce((v_fv->>1)::int, 0), 0), 120);
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

  -- the name is not changed by saving a round (only capitals/spacing, like set_identity)
  if jsonb_exists(p_delta, 'name') and tts.name_key(p_delta->>'name') = tts.name_key(v_data->>'name')
     and char_length(tts.clean_name(p_delta->>'name')) > 0 then
    v_data := jsonb_set(v_data, '{name}', to_jsonb(tts.clean_name(p_delta->>'name')));
  end if;
  if jsonb_exists(p_delta, 'color') then
    v_data := jsonb_set(v_data, '{color}', to_jsonb(least(greatest(coalesce((p_delta->>'color')::int, 0), 0), 7)));
  end if;
  v_data := jsonb_set(v_data, '{updated}', to_jsonb(v_now));

  update tts.profiles set data = v_data, updated_at = now() where id = v_id;
  return v_data;
end $f$;

-- 3) Erasing stats is no longer possible from the game (the teacher can remove a profile instead).
revoke execute on function public.tts_profile_reset(text) from public, anon, authenticated;

-- 4) Teacher tools: see which profiles are locked to a device, and unlock one so the student can claim it on a new device.
create or replace function public.tts_admin_list(p_code text, p_pin text) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin);
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('handle', left(id,12), 'name', data->>'name', 'rounds', (data->>'rounds')::int,
            'best', (data->>'bestScore')::int, 'me', id = v_id, 'owned', owner_hash is not null) order by created_at) from tts.profiles), '[]'::jsonb);
end $f$;

create or replace function public.tts_admin_unclaim(p_code text, p_pin text, p_handle text) returns int
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin); n int;
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  if p_handle is null or char_length(p_handle) <> 12 then raise exception 'bad_handle'; end if;
  update tts.profiles set owner_hash = null where left(id,12) = p_handle;
  get diagnostics n = row_count;
  return n;
end $f$;

grant execute on function public.tts_profile_claim(text), public.tts_profile_rename(text,text,integer,text),
  public.tts_profile_set_identity(text,text,integer), public.tts_profile_apply_round(text,jsonb),
  public.tts_admin_list(text,text), public.tts_admin_unclaim(text,text,text) to anon, authenticated;
