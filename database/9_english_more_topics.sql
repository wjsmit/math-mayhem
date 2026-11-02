-- Allow the extra English topics in the three functions that validate a topic id.
do $$
declare r record; d text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('eng_profile_apply_round','eng_admin_import','eng_admin_set_level')
  loop
    d := pg_get_functiondef(r.oid);
    d := replace(d, $a$array['figures','synonyms','antonyms','punct','grammar','mixed']$a$,
      $a$array['figures','synonyms','antonyms','punct','grammar','spelling','vocab','pos','tenses','affixes','idioms','clauses','tone','poetry','inference','plurals','mixed']$a$);
    execute d;
  end loop;
end $$;
