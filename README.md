# Math Mayhem

A times-table race game (tables up to 12) for the classroom. Play it at **https://wjsmit.github.io/math-mayhem/**.

- Live rooms with a 4-letter code, solo practice, a racetrack, live standings and a catch-up boost for players who fall behind.
- Every round is 60 seconds, up to the 12 times table.
- Profiles: a student's name is their profile code. Type it on any device to get your stats back.
- Leaderboard on the opening page; teacher tools (PIN protected) at the bottom.

## How it is built
- `index.html` — the whole game in one file. It talks to a Supabase database from the browser using the public key.
- `database/` — the SQL that sets up the Supabase database, in the order it was run.
  The tables can't be read directly; the browser can only call the game's own functions.

## Updating
Edit `index.html` and push to `main`; GitHub Pages republishes the site within a minute.
