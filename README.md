# Math Mayhem

A times-table race game (tables up to 12) for the classroom. Play it at **https://wjsmit.github.io/math-mayhem/**.

- Live rooms with a 4-letter code, solo practice, a racetrack, live standings and a catch-up boost for players who fall behind.
- Every round is 60 seconds, up to the 12 times table.
- Profiles: a student's name is their profile code. Type it on any device to get your stats back.
- Leaderboard on the opening page; teacher tools (PIN protected) at the bottom.

## One site, two games
The site at **https://wjsmit.github.io/math-mayhem/** is a home page with both games:
- `index.html` - the home page ("Mayhem Games") with a button for each game.
- `maths/index.html` - Math Mayhem (its own Supabase project, schema `tts`).
- `science/index.html` - Science Mayhem. Copied from the `wjsmit/science-mayhem` repo; edit it here from now on.

Both games use the SAME Supabase project (`Math Mayhem`): one profile (name, colour, avatar) per student, one class list, one teacher PIN. Maths progress is in `tts.profiles`, science progress in `sci.profiles` (same id). Each student has a maths level and a science topic + stage on the shared class list. The leaderboards stay separate per game. See `database/7_shared_with_science.sql`. (`5_class_lists_finish.sql` is no longer needed: renaming now carries the class link across, and Remove name works.)

## How it is built
- `index.html` — the whole game in one file. It talks to a Supabase database from the browser using the public key.
- `database/` — the SQL that sets up the Supabase database, in the order it was run.
  The tables can't be read directly; the browser can only call the game's own functions.

## Updating
Edit `index.html` and push to `main`; GitHub Pages republishes the site within a minute.
