/// run_tests.mo — interpreter battery for the DvP core's pure logic (agenda F + T6 property).
///
/// Run with the moc interpreter (no replica):
///   moc -r --package core <core/src> --package sha2 <sha2/src> test/run_tests.mo
/// Exit code is non-zero on any failed check (Runtime.trap), so it is a hard CI gate.
///
/// PART 1 — DvpLogic unit checks (conservation arithmetic, cat monotonicity, lifecycle
///   gates, double-resolve predicate); each bound to an exact expected value.
/// PART 2 — property simulation (N >= 10_000): a faithful pure mock of the IndexedLedger
///   fee/dedup semantics + the SAME idempotent settle/reclaim algorithm DvpCore uses
///   (per-leg markers + stored created_at_time), with randomized amounts, lifecycle paths,
///   and injected ledger failures (clean-transient AND lost-reply-after-commit). Asserts
///   conservation, exactly-once payout (no double-pay), and no-stranding on EVERY trial.

import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Map "mo:core/Map";

import L "../src/DvpLogic";

// ── test harness ────────────────────────────────────────────────────────────────────────
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
func isOk<X>(r : L.Result_<X>) : Bool { switch (r) { case (#ok(_)) true; case (#err(_)) false } };
func isErr<X>(r : L.Result_<X>) : Bool { not isOk(r) };

// ── mock ledger (mirrors Bal.transfer + IndexedLedger.checkDedupAndTime) ──────────────────
type Ledger = {
  bal : Map.Map<Text, Nat>;
  fee : Nat;
  var burned : Nat;
  dedup : Map.Map<Nat64, Nat>;
  var nextIdx : Nat;
};
func newLedger(fee : Nat) : Ledger { { bal = Map.empty<Text, Nat>(); fee; var burned = 0; dedup = Map.empty<Nat64, Nat>(); var nextIdx = 1 } };
func bget(lg : Ledger, a : Text) : Nat { switch (Map.get(lg.bal, Text.compare, a)) { case (?b) b; case null 0 } };
func bset(lg : Ledger, a : Text, v : Nat) { if (v == 0) ignore Map.delete(lg.bal, Text.compare, a) else Map.add(lg.bal, Text.compare, a, v) };
func credit(lg : Ledger, a : Text, v : Nat) { if (v > 0) bset(lg, a, bget(lg, a) + v) };
func totalSupply(lg : Ledger) : Nat { var s = lg.burned; for ((_, v) in Map.entries(lg.bal)) { s += v }; s };

type TxResult = { #Ok : Nat; #Duplicate : Nat; #InsufficientFunds; #TransientNoCommit; #TransientLostReply : Nat };

// transfer(from,to,amount): debit amount+fee, credit amount, burn fee; cat dedup. `fail`
// injects a clean transient (no commit) or a lost-reply (COMMITS but signals failure).
func transfer(lg : Ledger, from : Text, to : Text, amount : Nat, cat : Nat64, fail : { #none; #clean; #lost }) : TxResult {
  switch (Map.get(lg.dedup, Nat64.compare, cat)) { case (?idx) { return #Duplicate(idx) }; case null {} };
  let total = amount + lg.fee;
  if (bget(lg, from) < total) return #InsufficientFunds;
  switch (fail) {
    case (#clean) { #TransientNoCommit };
    case (_) {
      bset(lg, from, bget(lg, from) - total);
      credit(lg, to, amount);
      lg.burned += lg.fee;
      let idx = lg.nextIdx; lg.nextIdx += 1;
      Map.add(lg.dedup, Nat64.compare, cat, idx);
      switch (fail) { case (#lost) { #TransientLostReply(idx) }; case (_) { #Ok(idx) } };
    };
  };
};

// deterministic xorshift64 RNG
var rng : Nat64 = 88172645463325252;
func rnd() : Nat64 {
  var x = rng;
  x := x ^ (x << 13);
  x := x ^ (x >> 7);
  x := x ^ (x << 17);
  rng := x;
  x;
};
func rndRange(lo : Nat, hi : Nat) : Nat { lo + Nat64.toNat(rnd() % Nat64.fromNat(hi - lo + 1)) };
// injected failure: 60% none, 25% clean-transient, 15% lost-reply-after-commit
func injFail() : { #none; #clean; #lost } { let r = rnd() % 100; if (r < 60) #none else if (r < 85) #clean else #lost };
func unwrap(r : L.Result_<Nat>) : Nat { switch (r) { case (#ok(n)) n; case (#err(e)) Runtime.trap("unwrap err: " # e) } };

// ── PART 1: UNIT ───────────────────────────────────────────────────────────────────────
Debug.print("PART 1 — DvpLogic unit checks");

switch (L.netAfterFee(1000, 10)) { case (#ok(n)) checkEqNat("netAfterFee 1000-10", n, 990); case (#err(_)) check("netAfterFee 1000-10 ok", false) };
switch (L.netAfterFee(11, 10)) { case (#ok(n)) checkEqNat("netAfterFee 11-10", n, 1); case (#err(_)) check("netAfterFee 11-10 ok", false) };
switch (L.netAfterFee(10, 10)) { case (#ok(_)) check("netAfterFee 10-10 must reject (==fee)", false); case (#err(_)) check("netAfterFee 10-10 rejects", true) };
switch (L.netAfterFee(5, 10)) { case (#ok(_)) check("netAfterFee 5-10 must reject (<fee)", false); case (#err(_)) check("netAfterFee 5-10 rejects", true) };
switch (L.netAfterFee(1000, 0)) { case (#ok(n)) checkEqNat("netAfterFee fee=0", n, 1000); case (#err(_)) check("netAfterFee fee=0 ok", false) };

check("legAmountValid 11>10", L.legAmountValid(11, 10));
check("legAmountValid 10>10 false", not L.legAmountValid(10, 10));

var cur : Nat64 = 0;
cur := L.nextCat(cur, 100); checkEqNat("cat first", Nat64.toNat(cur), 100);
cur := L.nextCat(cur, 100); checkEqNat("cat same-now +1", Nat64.toNat(cur), 101);
cur := L.nextCat(cur, 100); checkEqNat("cat same-now +1 again", Nat64.toNat(cur), 102);
cur := L.nextCat(cur, 500); checkEqNat("cat clock-jump tracks now", Nat64.toNat(cur), 500);
cur := L.nextCat(cur, 500); checkEqNat("cat same-now after jump +1", Nat64.toNat(cur), 501);
var prevCat : Nat64 = cur;
var monoOk = true;
var bi = 0;
while (bi < 1000) { let c = L.nextCat(prevCat, 500); if (not (c > prevCat)) monoOk := false; prevCat := c; bi += 1 };
check("cat strictly monotonic over 1000-call frozen-clock burst", monoOk);

check("canFund Open in-window", isOk(L.canFund(#Open, 100, 200)));
check("canFund Open past-deadline rejects", isErr(L.canFund(#Open, 300, 200)));
check("canFund Funded rejects", isErr(L.canFund(#Funded, 100, 200)));
check("canSettle Funded+both ok", isOk(L.canSettle(#Funded, true, true)));
check("canSettle Funded missing leg rejects", isErr(L.canSettle(#Funded, true, false)));
check("canSettle Open rejects (gate closed)", isErr(L.canSettle(#Open, true, true)));
check("canSettle Aborted rejects", isErr(L.canSettle(#Aborted, true, true)));
check("canReclaim Open past-deadline ok", isOk(L.canReclaim(#Open, 300, 200)));
check("canReclaim Open pre-deadline rejects", isErr(L.canReclaim(#Open, 100, 200)));
check("canReclaim Funded rejects", isErr(L.canReclaim(#Funded, 300, 200)));
check("canReclaim Settled rejects (INV-DVP-3)", isErr(L.canReclaim(#Settled, 300, 200)));

check("legSingleResolution none", L.legSingleResolution(null, null));
check("legSingleResolution paid-only", L.legSingleResolution(?5, null));
check("legSingleResolution refund-only", L.legSingleResolution(null, ?7));
check("legSingleResolution BOTH rejected", not L.legSingleResolution(?5, ?7));
check("isTerminal Settled", L.isTerminal(#Settled));
check("isTerminal Aborted", L.isTerminal(#Aborted));
check("isTerminal Open false", not L.isTerminal(#Open));

// ── PART 2: PROPERTY ───────────────────────────────────────────────────────────────────
Debug.print("PART 2 — property simulation (N=10000 randomized trials)");
var trial = 0;
let N = 10_000;
var catCursor : Nat64 = 1_000_000;
var clock : Nat64 = 1_000_000;
while (trial < N) {
  let assetFee = rndRange(0, 5);
  let cashFee = rndRange(0, 5);
  let asset = newLedger(assetFee);
  let cash = newLedger(cashFee);
  let amountA = rndRange(assetFee + 1, assetFee + 5000);
  let amountB = rndRange(cashFee + 1, cashFee + 5000);
  let maker = "maker"; let taker = "taker"; let core = "core";
  credit(asset, maker, amountA + assetFee + rndRange(0, 100));
  credit(cash, taker, amountB + cashFee + rndRange(0, 100));
  let assetTotal0 = totalSupply(asset);
  let cashTotal0 = totalSupply(cash);
  let makerAsset0 = bget(asset, maker);
  let takerCash0 = bget(cash, taker);

  // escrow both legs into core (always commits in setup)
  catCursor := L.nextCat(catCursor, clock); clock += 1;
  switch (transfer(asset, maker, core, amountA, catCursor, #none)) { case (#Ok(_)) {}; case (_) Runtime.trap("escrowA setup failed") };
  catCursor := L.nextCat(catCursor, clock); clock += 1;
  switch (transfer(cash, taker, core, amountB, catCursor, #none)) { case (#Ok(_)) {}; case (_) Runtime.trap("escrowB setup failed") };
  check("escrow: core holds asset", bget(asset, core) == amountA);
  check("escrow: core holds cash", bget(cash, core) == amountB);

  let abortPath = (rnd() % 5) == 0;

  if (abortPath) {
    var refA : ?Nat = null; var refB : ?Nat = null;
    var catRA : ?Nat64 = null; var catRB : ?Nat64 = null;
    var guard = 0;
    while ((refA == null or refB == null) and guard < 80) {
      guard += 1;
      if (refA == null) {
        let c = switch (catRA) { case (?cc) cc; case null { catCursor := L.nextCat(catCursor, clock); clock += 1; catRA := ?catCursor; catCursor } };
        switch (transfer(asset, core, maker, unwrap(L.netAfterFee(amountA, asset.fee)), c, injFail())) {
          case (#Ok(i) or #Duplicate(i) or #TransientLostReply(i)) { refA := ?i }; case (_) {};
        };
      };
      if (refB == null) {
        let c = switch (catRB) { case (?cc) cc; case null { catCursor := L.nextCat(catCursor, clock); clock += 1; catRB := ?catCursor; catCursor } };
        switch (transfer(cash, core, taker, unwrap(L.netAfterFee(amountB, cash.fee)), c, injFail())) {
          case (#Ok(i) or #Duplicate(i) or #TransientLostReply(i)) { refB := ?i }; case (_) {};
        };
      };
    };
    check("abort converged", refA != null and refB != null);
    // maker bore BOTH the inbound escrow fee and the outbound refund fee (the two unavoidable
    // ledger fees on a fully-aborted trade), so the principal returns minus 2*fee.
    checkEqNat("abort: maker asset restored minus 2 fees", bget(asset, maker), makerAsset0 - 2 * asset.fee);
    checkEqNat("abort: taker cash restored minus 2 fees", bget(cash, taker), takerCash0 - 2 * cash.fee);
  } else {
    var payA : ?Nat = null; var payB : ?Nat = null;
    var catPA : ?Nat64 = null; var catPB : ?Nat64 = null;
    var guard = 0;
    while ((payA == null or payB == null) and guard < 80) {
      guard += 1;
      if (payA == null) {
        let c = switch (catPA) { case (?cc) cc; case null { catCursor := L.nextCat(catCursor, clock); clock += 1; catPA := ?catCursor; catCursor } };
        switch (transfer(asset, core, taker, unwrap(L.netAfterFee(amountA, asset.fee)), c, injFail())) {
          case (#Ok(i) or #Duplicate(i) or #TransientLostReply(i)) { payA := ?i }; case (_) {};
        };
      };
      if (payB == null) {
        let c = switch (catPB) { case (?cc) cc; case null { catCursor := L.nextCat(catCursor, clock); clock += 1; catPB := ?catCursor; catCursor } };
        switch (transfer(cash, core, maker, unwrap(L.netAfterFee(amountB, cash.fee)), c, injFail())) {
          case (#Ok(i) or #Duplicate(i) or #TransientLostReply(i)) { payB := ?i }; case (_) {};
        };
      };
    };
    check("settle converged", payA != null and payB != null);
    checkEqNat("settle: taker got asset net fee", bget(asset, taker), amountA - asset.fee);
    checkEqNat("settle: maker got cash net fee", bget(cash, maker), amountB - cash.fee);
  };

  checkEqNat("conservation asset supply", totalSupply(asset), assetTotal0);
  checkEqNat("conservation cash supply", totalSupply(cash), cashTotal0);
  checkEqNat("no-stranding: core asset == 0", bget(asset, core), 0);
  checkEqNat("no-stranding: core cash == 0", bget(cash, core), 0);

  trial += 1;
};

// explicit no-double-pay: replay the SAME cat — 2nd is a #Duplicate that moves nothing.
do {
  let lg = newLedger(10);
  credit(lg, "core", 1000);
  let cat : Nat64 = 9_999_999;
  let r1 = transfer(lg, "core", "rcpt", 500, cat, #none);
  let r2 = transfer(lg, "core", "rcpt", 500, cat, #none);
  check("idempotent: first is Ok", switch (r1) { case (#Ok(_)) true; case (_) false });
  check("idempotent: replay is Duplicate", switch (r2) { case (#Duplicate(_)) true; case (_) false });
  checkEqNat("idempotent: recipient credited once (500)", bget(lg, "rcpt"), 500);
  checkEqNat("idempotent: core debited once (510)", bget(lg, "core"), 490);
};

// ── verdict ───────────────────────────────────────────────────────────────────────────
Debug.print("checks=" # Nat.toText(checks) # " failures=" # Nat.toText(failures));
if (failures > 0) { Runtime.trap("BATTERY RED: " # Nat.toText(failures) # " failed checks") } else { Debug.print("BATTERY GREEN: all " # Nat.toText(checks) # " checks passed") };
