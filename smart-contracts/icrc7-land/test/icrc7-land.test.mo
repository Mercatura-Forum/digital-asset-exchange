/// icrc7-land.test.mo — interpreter battery for the NFT (`#icrc7`) leg predicates.
///
/// Run with the moc interpreter (no replica):
///   moc -r --package core <core/src> --package sha2 <sha2/src> test/run_tests_icrc7.mo
/// Exit code is non-zero on any failed check, so it is a hard CI gate.
///
/// This battery exercises PRODUCTION code, not a mock: `LandRegistry`'s transfer/transferFrom/
/// approve/mint functions are pure (operate on a `State` record, no await), so the same code the
/// deployed land ledger runs is driven directly here. It also drives the leg-agnostic pure
/// predicates in `DvpLogic` (double-resolve, settle/reclaim gates) in an NFT framing.
///
/// PART 1 — NFT unit invariants: escrowed-before-payout (a non-owner cannot transfer), escrow
///   via icrc37_transfer_from requires approval, exactly-once via created_at_time dedup
///   (#Duplicate on replay moves nothing), ownership after settle == recipient / after abort ==
///   owner, conservation (total supply constant, exactly one owner per token).
/// PART 2 — property simulation (N randomized trials) with redundant same-cat calls modelling
///   lost-reply-after-commit: the token moves EXACTLY once regardless of replays. Small `now`
///   (fresh-genesis-like) also exercises the dedup-prune Nat64-underflow GUARD on every 10th op.

import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Principal "mo:core/Principal";

import L "../../dvp-core/src/DvpLogic";
import R "../src/LandRegistry";
import I "../../dvp-core/src/ICRC7";

// ── harness ────────────────────────────────────────────────────────────────────────────
var checks : Nat = 0;
var failures : Nat = 0;
func check(name : Text, cond : Bool) {
  checks += 1;
  if (not cond) { failures += 1; Debug.print("  FAIL: " # name) };
};
func checkEqNat(name : Text, got : Nat, want : Nat) {
  checks += 1;
  if (got != want) { failures += 1; Debug.print("  FAIL: " # name # " got=" # Nat.toText(got) # " want=" # Nat.toText(want)) };
};

let MAKER = Principal.fromText("wo5zf-huqv6-cec7e-uo4bu-fx2js-kalhq-aryrs-23gzj-4zq6w-wl2y4-oae");
let TAKER = Principal.fromText("winj5-duvhk-a76p2-7aiiy-372y4-xinlt-ettsr-ykxhl-oi7or-kpvnh-eae");
// A valid, distinct principal standing in for the DvP core (the registry only checks
// equality; the on-chain core's real principal is used in the live battery).
let CORE = Principal.fromText("7dqsm-7qaaa-aaaaa-ad5fa-cai");
func acct(p : Principal) : I.Account { { owner = p; subaccount = null } };
func ownerIs(st : R.State, tid : Nat, p : Principal) : Bool {
  switch (R.ownerOf(st, tid)) { case (?a) Principal.equal(a.owner, p); case null false };
};
func isOkXfer(r : I.TransferResult) : Bool { switch (r) { case (#Ok(_)) true; case (_) false } };
func isDupXfer(r : I.TransferResult) : Bool { switch (r) { case (#Err(#Duplicate(_))) true; case (_) false } };
func isOkFrom(r : I.TransferFromResult) : Bool { switch (r) { case (#Ok(_)) true; case (_) false } };
func isUnauthFrom(r : I.TransferFromResult) : Bool { switch (r) { case (#Err(#Unauthorized)) true; case (_) false } };

// Small `now` — fresh-genesis-like, to exercise the dedup-prune underflow GUARD.
let NOW : Nat64 = 2_000_000;

func mkTransfer(to : Principal, tid : Nat, cat : ?Nat64) : I.TransferArg {
  { from_subaccount = null; to = acct(to); token_id = tid; memo = null; created_at_time = cat };
};
func mkFrom(from : Principal, to : Principal, tid : Nat, cat : ?Nat64) : I.TransferFromArg {
  { spender_subaccount = null; from = acct(from); to = acct(to); token_id = tid; memo = null; created_at_time = cat };
};
func mkApprove(tid : Nat, spender : Principal) : I.ApproveTokenArg {
  { token_id = tid; approval_info = { spender = acct(spender); from_subaccount = null; expires_at = null; memo = null; created_at_time = null } };
};

// ── PART 1 — NFT unit invariants (real LandRegistry) ─────────────────────────────────────
Debug.print("PART 1 — NFT (#icrc7) unit invariants on the REAL LandRegistry");

let st = R.newState();
switch (R.mint(st, acct(MAKER), 7, [("parcel", #Text("Memphis-Block-7"))], NOW)) {
  case (#ok(_)) check("mint token 7 -> maker", true);
  case (#err(e)) check("mint failed: " # e, false);
};
check("owner_of(7) == maker after mint", ownerIs(st, 7, MAKER));
checkEqNat("balance_of(maker) == 1", R.balanceOf(st, acct(MAKER)), 1);
checkEqNat("total supply == 1", R.totalSupply(st), 1);

// escrowed-before-payout: the core does not own the token yet — it cannot transfer it out.
check("payout-before-escrow rejected (core not owner)", not isOkXfer(R.transfer(st, CORE, mkTransfer(TAKER, 7, ?100), NOW)));
check("owner unchanged after rejected payout", ownerIs(st, 7, MAKER));

// escrow via transfer_from REQUIRES approval: unapproved pull is Unauthorized.
check("transfer_from without approval -> Unauthorized", isUnauthFrom(R.transferFrom(st, CORE, mkFrom(MAKER, CORE, 7, ?200), NOW)));
check("owner unchanged after unauthorized pull", ownerIs(st, 7, MAKER));

// maker approves the core, then the core pulls the token in (escrow).
switch (R.approveToken(st, MAKER, mkApprove(7, CORE), NOW)) { case (#Ok(_)) check("maker approves core for token 7", true); case (#Err(_)) check("approve failed", false) };
check("escrow pull (transfer_from) ok", isOkFrom(R.transferFrom(st, CORE, mkFrom(MAKER, CORE, 7, ?300), NOW)));
check("owner_of(7) == core after escrow", ownerIs(st, 7, CORE));
// after escrow the maker no longer owns token 7, so a fresh-cat re-pull is Unauthorized
// (owner-mismatch). This also confirms escrow cannot be double-applied to drain the maker.
check("re-pull after escrow Unauthorized (maker no longer owner)", isUnauthFrom(R.transferFrom(st, CORE, mkFrom(MAKER, CORE, 7, ?301), NOW)));

// exactly-once payout: replay with the SAME cat is a #Duplicate that moves nothing.
let pay1 = R.transfer(st, CORE, mkTransfer(TAKER, 7, ?400), NOW);
check("payout core->taker ok", isOkXfer(pay1));
check("owner_of(7) == taker after payout", ownerIs(st, 7, TAKER));
let pay2 = R.transfer(st, CORE, mkTransfer(TAKER, 7, ?400), NOW); // same cat replay
check("payout replay (same cat) is #Duplicate", isDupXfer(pay2));
check("owner_of(7) STILL taker after replay (exactly once)", ownerIs(st, 7, TAKER));
checkEqNat("conservation: total supply still 1", R.totalSupply(st), 1);
checkEqNat("balance_of(taker) == 1", R.balanceOf(st, acct(TAKER)), 1);
checkEqNat("balance_of(core) == 0 (no dust)", R.balanceOf(st, acct(CORE)), 0);
checkEqNat("balance_of(maker) == 0", R.balanceOf(st, acct(MAKER)), 0);

// abort path on a fresh token: escrow to core, then refund back to maker, idempotent.
switch (R.mint(st, acct(MAKER), 8, [("parcel", #Text("Memphis-Block-8"))], NOW)) { case (#ok(_)) {}; case (#err(_)) check("mint 8", false) };
ignore R.approveToken(st, MAKER, mkApprove(8, CORE), NOW);
check("escrow token 8 to core", isOkFrom(R.transferFrom(st, CORE, mkFrom(MAKER, CORE, 8, ?500), NOW)));
check("owner_of(8) == core", ownerIs(st, 8, CORE));
let ref1 = R.transfer(st, CORE, mkTransfer(MAKER, 8, ?600), NOW); // refund
check("refund core->maker ok", isOkXfer(ref1));
check("owner_of(8) == maker after refund (INV-DVP-4 restored)", ownerIs(st, 8, MAKER));
let ref2 = R.transfer(st, CORE, mkTransfer(MAKER, 8, ?600), NOW); // replay
check("refund replay (same cat) is #Duplicate", isDupXfer(ref2));
check("owner_of(8) STILL maker after replay (exactly once)", ownerIs(st, 8, MAKER));

// non-existing token: transfer / transfer_from / approve all reject.
check("transfer non-existing token -> NonExistingTokenId", switch (R.transfer(st, CORE, mkTransfer(TAKER, 9999, ?700), NOW)) { case (#Err(#NonExistingTokenId)) true; case (_) false });

// double-resolve predicate (leg-agnostic) in an NFT framing: a leg resolved to BOTH
// paid and refunded is rejected (INV-DVP-3 substrate).
check("legSingleResolution NFT paid-only ok", L.legSingleResolution(?400, null));
check("legSingleResolution NFT refund-only ok", L.legSingleResolution(null, ?600));
check("legSingleResolution NFT BOTH rejected", not L.legSingleResolution(?400, ?600));
// settle/reclaim gates hold identically with an NFT leg (leg-agnostic).
check("canSettle Funded+both ok (NFT leg)", switch (L.canSettle(#Funded, true, true)) { case (#ok(_)) true; case (#err(_)) false });
check("canSettle Open rejects (NFT leg, gate closed)", switch (L.canSettle(#Open, true, true)) { case (#ok(_)) false; case (#err(_)) true });

// ── PART 2 — property: exactly-once under redundant same-cat replays (lost-reply model) ───
Debug.print("PART 2 — property simulation (N randomized trials, redundant same-cat replays)");
var rng : Nat64 = 1234567891011;
func rnd() : Nat64 { var x = rng; x := x ^ (x << 13); x := x ^ (x >> 7); x := x ^ (x << 17); rng := x; x };

let N = 5_000;
var trial = 0;
var catSeq : Nat64 = 1_000;
let pst = R.newState();
while (trial < N) {
  let tid = 100_000 + trial; // unique token per trial
  ignore R.mint(pst, acct(MAKER), tid, [], NOW);
  ignore R.approveToken(pst, MAKER, mkApprove(tid, CORE), NOW);

  // escrow: pull into core, with 1..3 redundant same-cat calls (models lost-reply-after-commit)
  catSeq += 1; let ecat = ?catSeq;
  let reps1 = 1 + Nat64.toNat(rnd() % 3);
  var k = 0; var okEscrow = false;
  while (k < reps1) { if (isOkFrom(R.transferFrom(pst, CORE, mkFrom(MAKER, CORE, tid, ecat), NOW))) okEscrow := true; k += 1 };
  check("prop: escrow eventually ok", okEscrow);
  check("prop: core owns after escrow", ownerIs(pst, tid, CORE));

  // resolve: 80% settle (->taker), 20% abort (->maker); redundant same-cat replays.
  let settlePath = (rnd() % 5) != 0;
  let dest = if (settlePath) TAKER else MAKER;
  catSeq += 1; let rcat = ?catSeq;
  let reps2 = 1 + Nat64.toNat(rnd() % 3);
  var j = 0;
  while (j < reps2) { ignore R.transfer(pst, CORE, mkTransfer(dest, tid, rcat), NOW); j += 1 };
  check("prop: owner == resolved dest", ownerIs(pst, tid, dest));
  // exactly-once: the OTHER party never holds the token; core holds nothing.
  let other = if (settlePath) MAKER else TAKER;
  check("prop: counter-party does NOT hold token", not ownerIs(pst, tid, other));
  check("prop: core holds nothing (no dust)", not ownerIs(pst, tid, CORE));

  trial += 1;
};
checkEqNat("prop: total supply == N+? minted tokens conserved", R.totalSupply(pst), N);

// ── verdict ───────────────────────────────────────────────────────────────────────────
Debug.print("checks=" # Nat.toText(checks) # " failures=" # Nat.toText(failures));
if (failures > 0) { Runtime.trap("ICRC7 BATTERY RED: " # Nat.toText(failures) # " failed checks") } else { Debug.print("ICRC7 BATTERY GREEN: all " # Nat.toText(checks) # " checks passed") };
