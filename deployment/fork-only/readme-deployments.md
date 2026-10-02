## Deployments

**Not deployed to mainnet.** `script/Deploy.s.sol` targets Robinhood Chain mainnet (chain 4663) and seeds the vault in the same run; `script/go-live.sh` runs it with preflight checks. Until then, the contracts' evidence is the six fork tests against live mainnet state and the [fork rehearsal](#fork-rehearsal).
