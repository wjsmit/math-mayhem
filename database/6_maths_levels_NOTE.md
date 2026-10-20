Maths levels were installed directly into the Supabase project as a migration named `maths_tracks`:
- `tts.roster.track` column (default 'tables'; values tables, addsub, bodmas, frac, alg1, alg2, alg3)
- `tts_class_mine` and `tts_class_claim` return the track
- `tts_admin_import(..., p_track)`, `tts_admin_roster` (returns track), new `tts_admin_set_track`
- `tts_profile_apply_round` accepts `tk` and keeps personal bests per kind of maths
Later migration `maths_tracks_alg4_ineq` added two more kinds of maths, `alg4` (squares and roots) and `ineq` (inequalities),
to the allowed list inside `tts_admin_import`, `tts_admin_set_track` and `tts_profile_apply_round`.
Migration `maths_tracks_muldiv_fracs` added `muldiv` (multiply and divide, mixed) and `fracs` (fractions) to the same allowed list.
Migration `maths_tracks_mixed` added `mixed` (a bit of everything) to the same allowed list.
