## Deployments

| Robinhood Chain mainnet (4663) | Address |
|---|---|
| TorqueMarket | [`{{MARKET}}`]({{explorer}}/address/{{MARKET}}) |
| TorqueVault (USDG LP) | [`{{VAULT}}`]({{explorer}}/address/{{VAULT}}) |

Deployed at block {{deployBlockFmt}} on {{deployedAt}} by `script/go-live.sh` (`script/Deploy.s.sol`) from [`{{deployer}}`]({{explorer}}/address/{{deployer}}). Both contracts are an exact match on [Sourcify](https://repo.sourcify.dev/{{chainId}}/{{MARKET}}) ([vault](https://repo.sourcify.dev/{{chainId}}/{{VAULT}})).

| First transactions on mainnet | Tx |
|---|---|
| Deploy TorqueVault | [`{{tx_vaultCreate_s}}`]({{explorer}}/tx/{{tx_vaultCreate}}) |
| Deploy TorqueMarket | [`{{tx_marketCreate_s}}`]({{explorer}}/tx/{{tx_marketCreate}}) |
| Wire the vault to the market (one-shot `setMarket`) | [`{{tx_setMarket_s}}`]({{explorer}}/tx/{{tx_setMarket}}) |
| Seed the vault with 15 USDG (same run) | [`{{tx_seed_s}}`]({{explorer}}/tx/{{tx_seed}}) |
| Fill the vault to its $20 cap | [`{{tx_capFill_s}}`]({{explorer}}/tx/{{tx_capFill}}) |
| Open position #1: $2 at 5×, real NVDA bought in the pool | [`{{tx_open_s}}`]({{explorer}}/tx/{{tx_open}}) |
| Close position #1: vault repaid in full, 1.98 USDG back to the trader | [`{{tx_close_s}}`]({{explorer}}/tx/{{tx_close}}) |
