// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TorqueVault} from "../src/TorqueVault.sol";
import {TorqueMarket} from "../src/TorqueMarket.sol";
import {IAggregatorV3, IUniswapV3PoolMinimal} from "../src/interfaces/IExternal.sol";

/// @notice Deploys Torque to Robinhood Chain mainnet (4663).
///
///   Dry run (no broadcast):
///     forge script script/Deploy.s.sol --rpc-url $RH_RPC_URL --account <keystore>
///   Broadcast + verify on Sourcify:
///     forge script script/Deploy.s.sol --rpc-url $RH_RPC_URL --account <keystore> --broadcast \
///       --verify --verifier sourcify --chain 4663
contract Deploy is Script {
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IERC20 constant NVDA = IERC20(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);
    IUniswapV3PoolMinimal constant POOL = IUniswapV3PoolMinimal(0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3);
    IAggregatorV3 constant FEED = IAggregatorV3(0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15);

    function run() external returns (TorqueVault vault, TorqueMarket market) {
        require(block.chainid == 4663, "Robinhood Chain mainnet only");

        vm.startBroadcast();
        vault = new TorqueVault(USDG);
        market = new TorqueMarket(USDG, NVDA, POOL, FEED, vault);
        vault.setMarket(address(market));
        vm.stopBroadcast();

        require(vault.market() == address(market), "wiring");
        (uint256 p6, bool fresh) = market.oraclePrice();

        console.log("TorqueVault ", address(vault));
        console.log("TorqueMarket", address(market));
        console.log("NVDA (Chainlink, 6dp):", p6, fresh ? "fresh" : "STALE");
        console.log("");
        console.log("HackQuest contract field (one per line):");
        console.log(string.concat("Robinhood Chain: ", vm.toString(address(market)), unicode" — TorqueMarket"));
        console.log(string.concat("Robinhood Chain: ", vm.toString(address(vault)), unicode" — TorqueVault (USDG LP)"));
    }
}
