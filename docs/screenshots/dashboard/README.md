# Dashboard screenshots

Captured with Playwright at 1440×900 and 390×844, in the light and dark themes.

| Set | Source | What it shows |
|---|---|---|
| `dashboard-mainnet-*` | The production build after deployment (`deployment.json` status mainnet), reading TorqueMarket `0xbee6…8096` and TorqueVault `0xb4dB…96Bf` on Robinhood Chain mainnet | Live Chainlink price and both checks; the real vault at its $20 cap with nothing lent; hedge 1:1; open interest $0 of $30. The fork-only versions of these shots are in git history |
| `dashboard-normal-*` | Local mainnet-fork rehearsal (`script/rehearse-fork.sh up`) | Two real positions on the fork, wallet connected, both checks passing; on phones the one-row top bar, stacked position cards and the scrolling payoff chart; `*-drawer-open` shows the drawer |
| `dashboard-failed-check-*` | The same fork, with the fork's feed set 18% below the pool (`rehearse-fork.sh feed 192.76`) | Check 2 failing, opens paused with the reason, the phone status card's ✕, and position #1 eligible for a permissionless knock-out |

Every fork screenshot carries the "Local mainnet-fork rehearsal" banner. None of it is on mainnet.
