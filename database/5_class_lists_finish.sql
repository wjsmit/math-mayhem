-- Math Mayhem: finishing touches for class lists (run after 4_class_lists.sql). Safe to run twice.
-- 1) A student's class link follows them when they change their name, and is freed if the teacher removes the profile.
alter table tts.roster drop constraint if exists roster_profile_fk;
alter table tts.roster add constraint roster_profile_fk foreign key (profile_id) references tts.profiles(id) on update cascade on delete set null;

-- 2) Teacher can take a name off a class list.
create or replace function public.tts_admin_roster_remove(p_code text, p_pin text, p_rid bigint) returns int
language plpgsql security definer set search_path='' as $f$
declare v_id text := tts.admin_ok(p_code, p_pin); n int;
begin
  if v_id is null then raise exception 'not_allowed'; end if;
  delete from tts.roster where id = p_rid;
  get diagnostics n = row_count;
  return n;
end $f$;
revoke execute on function public.tts_admin_roster_remove(text,text,bigint) from public, anon, authenticated;
grant execute on function public.tts_admin_roster_remove(text,text,bigint) to anon, authenticated;
