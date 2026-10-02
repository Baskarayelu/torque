# Deployment state

`deployment.json` is the one switch. `status` is either `fork-only` or `mainnet`; every surface that says where
TORQUE runs is generated from it by `python3 script/apply-deployment.py`:

| Output | From |
|---|---|
| `README.md` status block and Deployments section | `deployment/<status>/readme-status.md`, `readme-deployments.md` |
| `submission/SUBMISSION.md` (HackQuest text and the 300-character contract field) | `deployment/<status>/submission.md` |
| `video/narration/*-elevenlabs.txt` and `video/*-narration.json` | `deployment/<status>/demo.txt`, `pitch.txt` |
| `app/public/config.json` (dashboard) | `deployment.json` |
| `../torque-landing/config.json` (landing page, private repo) | `deployment.json` |

`script/go-live.sh` sets `status` to `mainnet` with the new addresses and runs the apply step itself. To flip by
hand, edit `deployment.json` and run the script. The script refuses `mainnet` without both addresses having code on
chain 4663, and refuses `fork-only` output that claims mainnet.
