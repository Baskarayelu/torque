# Dashboard screenshots

Captured with Playwright at 1440×900 and 390×844, in the light and dark themes.

| Set | Source | What it shows |
|---|---|---|
| `dashboard-production-*` | The production build with `config.json` in the fork-only state (`deployment.json`) | Live Chainlink price and both safety checks read from Robinhood Chain mainnet; every TORQUE value shown as "—"; the legend, sidebar card and empty states say "Not deployed to mainnet"; `*-drawer-open` shows the phone drawer |
| `dashboard-normal-*` | Local mainnet-fork rehearsal (`script/rehearse-fork.sh up`) | Two real positions on the fork, wallet connected, both checks passing; on phones the one-row top bar, stacked position cards and the scrolling payoff chart; `*-drawer-open` shows the drawer |
| `dashboard-failed-check-*` | The same fork, with the fork's feed set 18% below the pool (`rehearse-fork.sh feed 192.76`) | Check 2 failing, opens paused with the reason, the phone status card's ✕, and position #1 eligible for a permissionless knock-out |

Every fork screenshot carries the "Local mainnet-fork rehearsal" banner. None of it is on mainnet.
