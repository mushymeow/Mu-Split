# Mu Split race server

Races are rooms with a code. The server only passes split times between runners; every
timer still runs on each runner's own PC.

It's a Cloudflare Worker with a Durable Object per room, and it all fits in Cloudflare's
**free** plan (100,000 requests a day; one race of 4 runners with 30 splits uses a few
hundred).

## Put it online (once)

1. Install Node.js (LTS) from https://nodejs.org if you haven't.
2. Double-click `deploy.bat`. It signs you in to Cloudflare (free account), uploads the
   server and asks for the address it printed (`https://musplit-race.<you>.workers.dev`).
3. Run `build.ps1`. The address is built into Mu Split, so friends you send it to are
   ready to race.

To update the server later, run `deploy.bat` again.

## Files

- `worker.js`: the server (protocol described at the top)
- `wrangler.toml`: Cloudflare settings
- Test: `node ../tests/test_worker.mjs worker.js`
