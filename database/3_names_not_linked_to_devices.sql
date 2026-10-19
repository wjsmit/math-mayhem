-- Times Table Showdown: names are no longer linked to a device. Anyone who opens a profile can rename it.
-- Paste ALL of this into Supabase > SQL Editor and press Run. Safe to run more than once.
create or replace function public.tts_profile_rename(p_code text, p_name text, p_color integer, p_token text default null) returns jsonb
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
grant execute on function public.tts_profile_rename(text,text,integer,text) to anon, authenticated;
