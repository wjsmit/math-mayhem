-- Math Mayhem: class lists. Paste ALL of this into Supabase > SQL Editor and press Run (safe to run twice).
-- Teacher pastes a class list once. Each student picks a fun username, then picks their own name from the list.
-- Real names are only ever shown (a) to the teacher, with the PIN, and (b) to someone who knows the class code, as an
-- unclaimed-names pick list. Tip: enter names as "Anna S." (first name and last initial).

create table if not exists tts.classes (
  id bigserial primary key,
  label text not null,
  code text not null unique,
  created_at timestamptz not null default now()
);
create unique index if not exists classes_label_key on tts.classes (lower(label));
alter table tts.classes enable row level security;

create table if not exists tts.roster (
  id bigserial primary key,
  class_id bigint not null references tts.classes(id) on delete cascade,
  real_name text not null,
  profile_id text references tts.profiles(id) on update cascade on delete set null,
  created_at timestamptz not null default now()
);
create unique index if not exists roster_name_key on tts.roster (class_id, lower(real_name));
create unique index if not exists roster_profile_key on tts.roster (profile_id) where profile_id is not null;
alter table tts.roster enable row level security;

-- student: open a class with its code; returns the names nobody has picked yet
create or replace function public.tts_class_open(p_class text, p_code text) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_pid text := tts.code_id(p_code); v_class tts.classes; v_up text := upper(regexp_replace(coalesce(p_class,''), '[^A-Za-z]', '', 'g'));
begin
  if v_pid is null or not exists (select 1 from tts.profiles where id = v_pid) then raise exception 'not_found'; end if;
  select * into v_class from tts.classes where code = v_up;
  if v_class.id is null then perform pg_sleep(1); raise exception 'no_class'; end if;
  return jsonb_build_object('label', v_class.label,
    'names', coalesce((select jsonb_agg(jsonb_build_object('rid', r.id, 'name', r.real_name) order by r.real_name)
                         from tts.roster r where r.class_id = v_class.id and r.profile_id is null), '[]'::jsonb));
end $f$;

-- student: pick my name (only a free name, and only if I have not picked one yet)
create or replace function public.tts_class_claim(p_class text, p_code text, p_rid bigint) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_pid text := tts.code_id(p_code); v_class tts.classes; v_up text := upper(regexp_replace(coalesce(p_class,''), '[^A-Za-z]', '', 'g')); n int;
begin
  if v_pid is null or not exists (select 1 from tts.profiles where id = v_pid) then raise exception 'not_found'; end if;
  select * into v_class from tts.classes where code = v_up;
  if v_class.id is null then raise exception 'no_class'; end if;
  if exists (select 1 from tts.roster where profile_id = v_pid) then raise exception 'already_linked'; end if;
  update tts.roster set profile_id = v_pid where id = p_rid and class_id = v_class.id and profile_id is null;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'name_taken'; end if;
  return jsonb_build_object('class', v_class.label);
end $f$;

-- student: am I linked? (returns only the class label, never the real name)
create or replace function public.tts_class_mine(p_code text) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_pid text := tts.code_id(p_code); v_label text;
begin
  if v_pid is null then return null; end if;
  select c.label into v_label from tts.roster r join tts.classes c on c.id = r.class_id where r.profile_id = v_pid;
  if v_label is null then return null; end if;
  return jsonb_build_object('class', v_label);
end $f$;

-- teacher: add names to a class (creates the class and its code if new)
create or replace function public.tts_admin_import(p_code text, p_pin text, p_label text, p_names text[]) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin); v_label text := left(btrim(coalesce(p_label,'')), 20); v_cid bigint; v_cc text; v_n text; v_add int := 0; n int; i int;
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
    insert into tts.roster (class_id, real_name) values (v_cid, v_n) on conflict do nothing;
    get diagnostics n = row_count;
    v_add := v_add + n;
  end loop;
  return jsonb_build_object('class', v_label, 'code', v_cc, 'added', v_add);
end $f$;

-- teacher: everything in one list (class code, real name, username, progress)
create or replace function public.tts_admin_roster(p_code text, p_pin text) returns jsonb
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin);
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  return jsonb_build_object(
    'classes', coalesce((select jsonb_agg(jsonb_build_object('label', label, 'code', code) order by label) from tts.classes), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'rid', r.id, 'class', c.label, 'real', r.real_name, 'user', p.data->>'name',
        'rounds', (p.data->>'rounds')::int, 'right', (p.data->>'right')::int, 'wrong', (p.data->>'wrong')::int,
        'best', (p.data->>'bestScore')::int, 'last', (p.data->>'updated')::bigint, 'facts', p.data->'facts')
        order by c.label, r.real_name)
      from tts.roster r join tts.classes c on c.id = r.class_id left join tts.profiles p on p.id = r.profile_id), '[]'::jsonb));
end $f$;

-- teacher: undo a wrong pick (the name becomes free again)
create or replace function public.tts_admin_unlink(p_code text, p_pin text, p_rid bigint) returns int
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin); n int;
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  update tts.roster set profile_id = null where id = p_rid;
  get diagnostics n = row_count;
  return n;
end $f$;

-- teacher: take a name off the list
create or replace function public.tts_admin_roster_remove(p_code text, p_pin text, p_rid bigint) returns int
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin); n int;
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  delete from tts.roster where id = p_rid;
  get diagnostics n = row_count;
  return n;
end $f$;

revoke execute on function public.tts_class_open(text,text), public.tts_class_claim(text,text,bigint), public.tts_class_mine(text),
  public.tts_admin_import(text,text,text,text[]), public.tts_admin_roster(text,text), public.tts_admin_unlink(text,text,bigint),
  public.tts_admin_roster_remove(text,text,bigint) from public, anon, authenticated;
grant execute on function public.tts_class_open(text,text), public.tts_class_claim(text,text,bigint), public.tts_class_mine(text),
  public.tts_admin_import(text,text,text,text[]), public.tts_admin_roster(text,text), public.tts_admin_unlink(text,text,bigint),
  public.tts_admin_roster_remove(text,text,bigint) to anon, authenticated;

-- overall leaderboard: students who picked their name from a class list show under that name;
-- everyone else still shows their username. (Live game rooms always show usernames.)
create or replace function public.tts_leaderboard(p_code text default null) returns jsonb
language plpgsql security definer set search_path='' stable as $f$
declare v_id text := tts.code_id(p_code); v_top jsonb; v_me jsonb; v_total int;
begin
  select count(*) into v_total from tts.profiles where coalesce((data->>'rounds')::int,0) > 0;
  select coalesce(jsonb_agg(x order by (x->>'rank')::int), '[]'::jsonb) into v_top from (
    select jsonb_build_object('rank', row_number() over (order by (p.data->>'bestScore')::int desc, (p.data->>'rounds')::int desc),
      'name', coalesce(r.real_name, p.data->>'name'), 'color', (p.data->>'color')::int, 'best', (p.data->>'bestScore')::int, 'streak', (p.data->>'bestStreak')::int,
      'rounds', (p.data->>'rounds')::int,
      'acc', case when (p.data->>'right')::int + (p.data->>'wrong')::int > 0 then round(100.0*(p.data->>'right')::int/((p.data->>'right')::int+(p.data->>'wrong')::int)) else 0 end) as x
    from tts.profiles p left join tts.roster r on r.profile_id = p.id where coalesce((p.data->>'rounds')::int,0) > 0
    order by (p.data->>'bestScore')::int desc, (p.data->>'rounds')::int desc limit 10) t;
  if v_id is not null then
    select jsonb_build_object('rank', rk) into v_me from (
      select id, row_number() over (order by (data->>'bestScore')::int desc, (data->>'rounds')::int desc) as rk
      from tts.profiles where coalesce((data->>'rounds')::int,0) > 0) q where id = v_id;
  end if;
  return jsonb_build_object('total', v_total, 'top', v_top, 'me', v_me);
end $f$;
revoke execute on function public.tts_leaderboard(text) from public, anon, authenticated;
grant execute on function public.tts_leaderboard(text) to anon, authenticated;
