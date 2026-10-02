#!/bin/bash
cd "$(dirname "$0")/.."
LOG="${LOG:-/tmp/torque-planted-bugs.log}"; exec > >(tee "$LOG") 2>&1
cp src/TorqueMarket.sol /tmp/tm.bak; cp src/TorqueVault.sol /tmp/tv.bak
mut() { name="$1"; file="$2"; from="$3"; to="$4"
  python3 - "$file" "$from" "$to" <<'EOF' || { echo "$name -> PATTERN NOT FOUND"; return; }
import sys; f,a,b=sys.argv[1:4]; s=open(f).read()
if a not in s: sys.exit(1)
open(f,'w').write(s.replace(a,b,1))
EOF
  rm -rf cache/invariant cache/fuzz
  out=$(FOUNDRY_INVARIANT_RUNS=256 forge test --no-match-path "test/fork/*" 2>&1)
  if echo "$out" | grep -q "Compiler run failed"; then echo "$name -> COMPILE ERROR"; else
  units=$(echo "$out" | grep -E '^\[FAIL' | grep -oE '(test|testFuzz)_[A-Za-z0-9_]+' | sort -u | wc -l | tr -d ' ')
  invs=$(echo "$out" | grep -E '^\[FAIL' | grep -vE '(test|testFuzz)_' | sort -u | wc -l | tr -d ' ')
  if [ "$units" = "0" ] && [ "$invs" = "0" ]; then echo "$name -> SURVIVED"; else echo "$name -> caught (unit/adversarial tests failing: $units, invariants failing: $invs)"; fi; fi
  cp /tmp/tm.bak src/TorqueMarket.sol; cp /tmp/tv.bak src/TorqueVault.sol; }
M=src/TorqueMarket.sol; V=src/TorqueVault.sol
mut2() { name="$1"; file="$2"; a1="$3"; b1="$4"; a2="$5"; b2="$6"
  python3 - "$file" "$a1" "$b1" "$a2" "$b2" <<'EOF2' || { echo "$name -> PATTERN NOT FOUND"; return; }
import sys; f,a1,b1,a2,b2=sys.argv[1:6]; s=open(f).read()
if a1 not in s or a2 not in s: sys.exit(1)
open(f,'w').write(s.replace(a1,b1,1).replace(a2,b2,1))
EOF2
  rm -rf cache/invariant cache/fuzz
  out=$(FOUNDRY_INVARIANT_RUNS=256 forge test --no-match-path "test/fork/*" 2>&1)
  units=$(echo "$out" | grep -E '^\[FAIL' | grep -oE '(test|testFuzz)_[A-Za-z0-9_]+' | sort -u | wc -l | tr -d ' ')
  invs=$(echo "$out" | grep -E '^\[FAIL' | grep -vE '(test|testFuzz)_' | sort -u | wc -l | tr -d ' ')
  if [ "$units" = "0" ] && [ "$invs" = "0" ]; then echo "$name -> SURVIVED"; else echo "$name -> caught (unit/adversarial tests failing: $units, invariants failing: $invs)"; fi
  cp /tmp/tm.bak src/TorqueMarket.sol; cp /tmp/tv.bak src/TorqueVault.sol; }
mut "M1 knock-out ignores stale feed" $M "        if (!feedFresh) revert StaleFeed();
        // A Chainlink" "        // A Chainlink"
mut "M2 no utilization cap" $M "revert UtilizationCap();" "{}"
mut "M3a vault cap check in _deposit removed" $V "        if (totalAssets() + assets > VAULT_CAP) revert CapExceeded();
" ""
mut2 "M3b vault cap removed (both checks)" $V "        if (totalAssets() + assets > VAULT_CAP) revert CapExceeded();
" "" "        uint256 assets = totalAssets();
        return assets >= VAULT_CAP ? 0 : VAULT_CAP - assets;" "        return type(uint256).max;"
mut "M4 mark loans at face value" $M "marked += debt < value ? debt : value;" "marked += debt; value;"
mut "M5 vault shorted on knock-out" $M "uint256 repaid = proceeds < debt ? proceeds : debt;
        payout = proceeds - repaid;
        uint256 badDebt = debt - repaid;
        totalBadDebt += badDebt;

        usdg.safeTransfer(address(vault), repaid);
        if (payout > 0) {
            claimable[p.owner] += payout;
            totalClaimable += payout;
        }
        emit KnockedOut" "uint256 repaid = proceeds < debt ? proceeds : debt; if (proceeds > 0) { repaid = repaid * 99 / 100; }
        payout = proceeds - repaid;
        uint256 badDebt = debt - repaid;
        totalBadDebt += badDebt;

        usdg.safeTransfer(address(vault), repaid);
        if (payout > 0) {
            claimable[p.owner] += payout;
            totalClaimable += payout;
        }
        emit KnockedOut"
mut "M6 open allowed on stale feed" $M "        if (!feedFresh) revert StaleFeed();
        if (!poolAgrees) revert PoolPriceMismatch();" "        if (!poolAgrees) revert PoolPriceMismatch();"
mut "M7 financing not accrued" $M "return p.principal + Math.mulDiv(p.principal, FINANCING_APR_BPS * dt, BPS * YEAR, Math.Rounding.Ceil);" "dt; return p.principal;"
mut "M8 barrier without buffer" $M "return Math.mulDiv(level, BPS + KO_BUFFER_BPS, BPS, Math.Rounding.Ceil);" "return level;"
mut "M10 close allowed underwater" $M "        if (proceeds < debt) revert Underwater();
        payout = proceeds - debt;" "        uint256 repay = proceeds < debt ? proceeds : debt; payout = proceeds - repay; debt = repay;"
mut "M11 open fill guard removed" $M "if (q < minNvdaOut || q < notional * 1e18 / price6 * (BPS - MAX_SLIPPAGE_BPS) / BPS) revert Slippage();" "if (q < minNvdaOut) revert Slippage();"
mut "M12 OI cap removed" $M "revert OpenInterestCap();" "{}"
mut "M13 opens skip pool check" $M "        if (!feedFresh) revert StaleFeed();
        if (!poolAgrees) revert PoolPriceMismatch();" "        if (!feedFresh) revert StaleFeed();
        poolAgrees;"
mut "M14 knock-outs skip pool check" $M "        if (!poolAgrees && feedAge > TWAP_WINDOW) revert PoolPriceMismatch();" "        poolAgrees; feedAge;"
mut "M15 LP flows skip pool check" $M "        (,,,, bool feedFresh, bool poolAgrees) = priceStatus();
        return feedFresh && poolAgrees;" "        (,,,, bool feedFresh, bool poolAgrees) = priceStatus();
        poolAgrees; return feedFresh;"
mut "M16 mark ignores pool average" $M "        if (twap6 < price6) price6 = twap6;" "        twap6;"
mut "M17 strict knock-out (no recency exemption)" $M "        if (!poolAgrees && feedAge > TWAP_WINDOW) revert PoolPriceMismatch();" "        if (!poolAgrees) revert PoolPriceMismatch(); feedAge;"
mut "M18 band 10x wider" $M "uint256 public constant MAX_POOL_DEVIATION_BPS = 150;" "uint256 public constant MAX_POOL_DEVIATION_BPS = 1500;"
mut "M19 tick math sign flipped" $M "        if (tick < 0) r = Math.mulDiv(1e18, 1e18, r);
        // USDG" "        // USDG"
mut "M20 unwind without dead-feed check" $M "        if (!isFeedDead()) revert FeedNotDead();" ""
mut "M21 LP exits ignore price checks with loans open" $V "        if (market == address(0) || ITorqueMarket(market).openPositionCount() == 0) return true;" "        return true;"
mut "M22 dead-feed clock never resets on report" $M "        if (price6 > 0) feedDownSince = 0;
        else if" "        if (price6 > 0) {}
        else if"
mut "M23 feed read reverts instead of 'no price'" $M "        } catch {
            return (0, type(uint256).max);
        }" "        } catch {
            revert(\"feed\");
        }"
mut "M24 open does not clear dead-feed clock" $M "        if (feedDownSince != 0) feedDownSince = 0; // a healthy print just read: clear any dead-feed clock" ""
mut "M25 reentrancy guard removed from open+close" $M "function open(uint256 margin, uint256 leverageBps, uint256 minNvdaOut) external nonReentrant returns" "function open(uint256 margin, uint256 leverageBps, uint256 minNvdaOut) external returns"
diff -q /tmp/tm.bak $M && diff -q /tmp/tv.bak $V && echo "sources restored"
echo "summary: $(grep -c ' -> caught' "$LOG") of $(grep -cE ' -> (caught|SURVIVED)' "$LOG") planted bugs caught"
