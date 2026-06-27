#!/usr/bin/env bash
# FLAGSHIP FLOW 1 — Share trade settles T+0.
# A buyer's order clears in a batch window and shares appear + CBDC is debited ATOMICALLY in the same
# block, with a verifiable settlement receipt (core trade Settled + audit SETTLED) — no T+2 pending.
# Re-runnable. 2 proofs: (1) balance deltas reconcile; (2) verifiable settlement receipt.
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/demo.env"
call(){ $TD call --manifest $MAN $NET --identity "$1" "$2" "$3" --arg "$4" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -1; }
q(){ $TD query --manifest $MAN $NET "$1" "$2" --arg "$3" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
bal(){ q "$1" icrc1_balance_of "$(acct $2)" | grep -oE '[0-9_]+ : nat' | head -1 | tr -d '_ ' | sed 's/ *: *nat//'; }
win(){ q $EN getCurrentWindow '()' | grep -oE '[0-9_]+ : nat' | head -1 | tr -d '_ ' | sed 's/ *: *nat//'; }
approve(){ call "$1" "$2" icrc2_approve "(record { spender = record { owner = principal \"$3\"; subaccount = null }; amount = $4 : nat; from_subaccount = null; expected_allowance = null; expires_at = null; fee = null; memo = null; created_at_time = null })" >/dev/null; }
QTY=100; PRICE=50   # buyer wants 100 ACME @ 50 CEGP/share = 5000 CEGP

echo "############ FLOW 1 — Share trade settles T+0 (seller mx-s1, buyer mx-b1) ############"
approve mx-s1 shares $CORE 1000000
approve mx-b1 cash   $CORE 10000000
s_sh0=$(bal shares $S1); s_c0=$(bal cash $S1); b_sh0=$(bal shares $B1); b_c0=$(bal cash $B1)
echo "pre:  seller shares=$s_sh0 cash=$s_c0 | buyer shares=$b_sh0 cash=$b_c0"
W=$(win); echo "open batch window: $W"
echo "-- seller submits ASK 100@50 ; buyer submits BID 100@50 (same window) --"
call mx-s1 $EN submitOrder "(record { side = variant { sell }; limitPrice = $PRICE : nat; qty = $QTY : nat; allOrNone = false })" >/dev/null
call mx-b1 $EN submitOrder "(record { side = variant { buy };  limitPrice = $PRICE : nat; qty = $QTY : nat; allOrNone = false })" >/dev/null
echo "-- batch clears at uniform price p* --"
call dvp-relayer $EN clearWindow '()' >/dev/null
for i in 1 2 3; do q $EN pendingClearStatus "($W : nat)" | grep -q null && break; call dvp-relayer $EN continueClear "($W : nat)" >/dev/null; done
SEQ=$(q $EN allObligations '()' | python3 $PAR --window $W --unsettled | awk '{print $1}' | head -1)
echo "cleared obligation seq=$SEQ ; engine obligation: $(q $EN obligationSummary '()' | grep -oE '\"[^\"]*\"' | tail -1)"
echo "-- autonomous settlement (no trader action): relayer drives settleObligation --"
RCPT=$(call dvp-relayer $EN settleObligation "($SEQ : nat, 3600 : nat)" | grep -oE '\"[^\"]*\"')
echo "settlement note: $RCPT"

TID=$(q $EN allObligations '()' | python3 $PAR --window $W | awk -v s=$SEQ '$1==s{print}' >/dev/null; $TD query --manifest $MAN $NET $CN tradeIdForMatch --arg "(principal \"$XCHG\", $SEQ : nat)" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'opt \([0-9]+' | grep -oE '[0-9]+')
s_sh1=$(bal shares $S1); s_c1=$(bal cash $S1); b_sh1=$(bal shares $B1); b_c1=$(bal cash $B1)
echo ""
echo "PROOF 1 — atomic balance reconciliation:"
echo "  buyer  shares $b_sh0 -> $b_sh1  (delta +$((b_sh1-b_sh0)), expect +$QTY)"
echo "  buyer  cash   $b_c0 -> $b_c1    (delta $((b_c1-b_c0)), expect -$((QTY*PRICE+10)) = price*qty + escrow fee)"
echo "  seller shares $s_sh0 -> $s_sh1  (delta $((s_sh1-s_sh0)), expect -$QTY)"
echo "  seller cash   $s_c0 -> $s_c1    (delta +$((s_c1-s_c0)), expect +$((QTY*PRICE-10)) = price*qty - payout fee)"
echo "  core dust: shares=$(bal shares $CORE) cash=$(bal cash $CORE) (expect 0/0 — both legs moved, nothing held)"
echo ""
echo "PROOF 2 — verifiable T+0 settlement receipt (DvP trade $TID):"
echo "  trade status hash (4_110_108_761 = Settled): $(q $CN getTrade "($TID : nat)" | grep -oE '4_110_108_761' | head -1)"
echo "  audit receipt: $(q $CN auditEvents "($TID : nat)" | grep -oE 'SETTLED[^"]*' | head -1)"
echo "  T+0 confirmation — unsettled obligations in window $W: $(q $EN allObligations '()' | python3 $PAR --window $W --unsettled | wc -l) (expect 0 — settled same batch, NO T+2 pending)"
echo "  core invariantLog: $(q $CN invariantLog '()' | tail -1)"
echo "############ FLOW 1 DONE ############"
