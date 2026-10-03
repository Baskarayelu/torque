# Videos

The submitted Demo and Pitch videos are edited from raw mainnet captures in a separate video project (final narration: `narration/mainnet/`). The scripts here are the earlier rehearsal pipeline: `build-demo.sh` drives the dashboard on a fork for a guide-voice preview.

Both videos are built from this folder for the state in `../deployment.json` (see `../deployment/README.md`).
`script/apply-deployment.py` writes the narration for that state to `demo-narration.json` / `pitch-narration.json`
and the paste-ready ElevenLabs text to `narration/*-elevenlabs.txt`. Text for both states is always in
`narration/fork-only/` and `narration/mainnet/`, so either voice track can be generated before the switch.

- **Pitch Video:** `NARRATION_MP3=<pitch mp3> ./build-pitch.sh out` renders `pitch/slides.html` (1920×1080). The status slide follows `deployment.json`.
- **Demo Video:** `NARRATION_MP3=<demo mp3> ./build-demo.sh out` opens the landing page, then drives the dashboard with an injected wallet and real transactions, one shot per narration line, paced by the voice track.
  - fork-only: needs `./script/rehearse-fork.sh up`; records the fork dashboard build (with its "Local mainnet-fork rehearsal" banner) using anvil test wallet 2, and includes the knock-out shot with a test feed.
  - mainnet: `RPC=<rpc> PK=<demo wallet key> NARRATION_MP3=... ./build-demo.sh out` records app.torque.0xo.in. `script/go-live.sh` runs this itself with `FILM=1`.

Without `NARRATION_MP3` the scripts use macOS `say` as a guide track. Frames come from the browser's screencast with their timestamps, so the video plays at real time and the voice stays in sync.

Setup: `npm install` here, then `npx playwright install chromium`. You also need `ffmpeg` and Foundry.
