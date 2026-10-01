# Videos

Both videos are generated from this folder, so they can be rebuilt after any change.

- **Pitch Video:** `./build-pitch.sh out <TorqueMarket> <TorqueVault>` renders `pitch/slides.html` (1920×1080) with narration from `pitch-narration.json`.
- **Demo Video:** `SITE_URL=<site> RPC=<rpc> PK=<demo wallet key> ./build-demo.sh out` drives the live site with real transactions (deposit, open, close) and narrates each step from `demo-narration.json`.

Narration uses macOS `say` (voice `Samantha`; set `VOICE=` to change). To use your own voice, record each line of the narration JSON files to `out/n_<id>.aiff` (demo) or `out/p_<id>.aiff` (pitch) and re-run the mux step.

Setup: `npm install` here, then `npx playwright install chromium`. You also need `ffmpeg`.
