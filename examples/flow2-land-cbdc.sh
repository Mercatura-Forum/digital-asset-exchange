#!/usr/bin/env bash
# FLAGSHIP FLOW 2 — Land<->CBDC atomic swap (RFQ / both-or-neither).
# A land-title NFT and its CBDC payment change hands atomically through the DvP core: maker (land
# owner) escrows the title, taker (buyer) escrows + auto-settles. Both-or-neither.
# Re-runnable (mints a fresh title each run). 2 proofs: (1) title + cash both moved; (2) Settled
# receipt + invariantLog empty (atomicity).
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/demo.env"
call(){ $TD call --manifest $MAN $NET --identity "$1" "$2" "$3" --arg "$4" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -1; }
q(){ $TD query --manifest $MAN $NET "$1" "$2" --arg "$3" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
bal(){ q "$1" icrc1_balance_of "$(acct $2)" | grep -oE '[0-9_]+ : nat' | head -1 | tr -d '_ ' | sed 's/ *: *nat//'; }
PRICE=300000   # 300,000 CEGP for the parcel
# fresh token id per run (chain-time based, avoids collisions); mint to LANDOWNER
TOK=$(( 200 + RANDOM % 100000 ))

echo "############ FLOW 2 — Land<->CBDC atomic swap (owner dvp-landowner -> buyer mx-b2) ############"
echo "-- mint a fresh land title #$TOK to the land owner --"
call dvp-relayer land mint "(record { owner = principal \"$LANDOWNER\"; subaccount = null }, $TOK : nat, vec {})" >/dev/null
echo "owner of #$TOK before: $(q land icrc7_owner_of "(vec { $TOK : nat })" | grep -oE 'apqza[a-z0-9-]*|eadba[a-z0-9-]*' | head -1) (expect landowner apqza...)"

echo "-- owner icrc37_approves the DvP core for the title; buyer approves the core for cash --"
call dvp-landowner land icrc37_approve_tokens "(vec { record { token_id = $TOK : nat; approval_info = record { spender = record { owner = principal \"$CORE\"; subaccount = null }; from_subaccount = null; expires_at = null; created_at_time = null; memo = null } } })" >/dev/null
call mx-b2 cash icrc2_approve "(record { spender = record { owner = principal \"$CORE\"; subaccount = null }; amount = 1000000 : nat; from_subaccount = null; expected_allowance = null; expires_at = null; fee = null; memo = null; created_at_time = null })" >/dev/null
# snapshot AFTER approvals so the buyer's one-time approve fee (10) is OUTSIDE the conservation window:
# inside the window the only buyer-cash movement is the trade (price + escrow fee).
lo_c0=$(bal cash $LANDOWNER); b_c0=$(bal cash $B2)
echo "pre (post-approval): landowner cash=$lo_c0 ; buyer(mx-b2) cash=$b_c0"

echo "-- owner opens the land<->CBDC trade (escrows the title inline) --"
OPEN=$(call dvp-landowner $CN openLandTrade "(record { taker = opt principal \"$B2\"; landLedger = principal \"$LAND_P\"; tokenId = $TOK : nat; cashLedger = principal \"$CASH_P\"; cashAmount = $PRICE : nat; deadlineSecs = 3600 : nat })")
TID=$(echo "$OPEN" | grep -oE '109_009_321 = [0-9]+|tradeId = [0-9]+' | grep -oE '[0-9]+' | head -1)
[ -z "$TID" ] && TID=$($TD query --manifest $MAN $NET $CN tradeCount --arg "()" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -oE '[0-9_]+ : nat' | tr -d '_ ' | sed 's/ *: *nat//')
echo "opened DvP trade id=$TID"
echo "-- buyer funds the cash leg -> auto-settle (both-or-neither) --"
call mx-b2 $CN fundTaker "($TID : nat)" >/dev/null

owner_after=$(q land icrc7_owner_of "(vec { $TOK : nat })" | grep -oE 'eadba[a-z0-9-]*|apqza[a-z0-9-]*' | head -1)
lo_c1=$(bal cash $LANDOWNER); b_c1=$(bal cash $B2)
echo ""
echo "PROOF 1 — title + payment both moved (atomic):"
echo "  title #$TOK owner: $owner_after  (expect buyer mx-b2 = eadba...)"
echo "  landowner cash $lo_c0 -> $lo_c1 (delta +$((lo_c1-lo_c0)), expect +$((PRICE-10)) = price - payout fee)"
echo "  buyer     cash $b_c0 -> $b_c1 (delta $((b_c1-b_c0)), expect -$((PRICE+10)) = price + escrow fee)"
echo "  core dust: land balance_of(core)=$(q land icrc7_balance_of "(vec { $(acct $CORE) })" | grep -oE '[0-9]+ : nat' | head -1) cash=$(bal cash $CORE) (expect 0 / 0)"
echo ""
echo "PROOF 2 — atomicity receipt (both-or-neither):"
echo "  trade status hash (4_110_108_761 = Settled): $(q $CN getTrade "($TID : nat)" | grep -oE '4_110_108_761' | head -1)"
echo "  audit: $(q $CN auditEvents "($TID : nat)" | grep -oE 'SETTLED[^"]*' | head -1)"
echo "  core invariantLog (empty => no half-settle, both-or-neither held): $(q $CN invariantLog '()' | tail -1)"
echo "############ FLOW 2 DONE (token #$TOK) ############"
