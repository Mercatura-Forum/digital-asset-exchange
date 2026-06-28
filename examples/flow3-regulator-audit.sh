#!/usr/bin/env bash
# FLAGSHIP FLOW 3 — Regulator audit stream.
# Every order -> match -> settle is observable in real time, and the DvP core's audit-MMR root is
# re-derivable EXTERNALLY (sovereign + verifiable, differentiator #3). 2 proofs:
# (1) the full lifecycle event stream is observable for the demo trades (share + land);
# (2) the audit-MMR root re-derived off-chain == the canister's auditRootHex (tamper-evident).
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/demo.env"
MMR="$(dirname "$0")/mmr_rederive.py"
EVP="$(dirname "$0")/parse_events.py"
q(){ $TD query --manifest $MAN $NET "$1" "$2" --arg "$3" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }

echo "############ FLOW 3 — Regulator audit stream (observer: dvp-regulator) ############"
echo "== matching engine — orders + matches observable =="
echo "  total orders on the venue: $(q $EN orderCount '()' | grep -oE '[0-9_]+ : nat' | head -1)"
echo "  cleared obligations (buyId>sellId@price:qty): $(q $EN obligationSummary '()' | grep -oE '\"[^\"]*\"' | tail -1)"
echo ""
echo "== PROOF 1 — DvP core lifecycle event stream (every order->fund->settle observable) =="
q $CN allEvents '()' | python3 $EVP | sed 's/^/  /'
echo ""
echo "== PROOF 2 — external audit-MMR re-derivation (tamper-evident, sovereign) =="
ROOT=$(q $CN auditRootHex '()' | grep -oE '[0-9a-f]{64}' | head -1)
q $CN allEvents '()' | python3 $EVP | python3 "$MMR" "$ROOT"
echo "############ FLOW 3 DONE ############"
