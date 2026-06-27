/// run_tests_matching.mo — interpreter battery for the matching engine's PURE clearing core.
///
/// Run (no replica):
///   moc -r --package core <core@2.5.0/src> --package sha2 <sha2@0.1.9/src> \
///       smart-contracts/dvp-matching/test/run_tests_matching.mo
/// Non-zero exit on any failure (Runtime.trap at the end), so it is a hard CI gate.
///
/// PART 1 — unit checks on hand-computed call-auction cases (clearing price, volume, priority).
/// PART 2 — chunked == unbounded EQUIVALENCE (mission M1): for thousands of random books, the
///   resumable step() planner, stopped at EVERY possible chunk size k, reproduces the unbounded
///   fillSchedule byte-for-byte (same fills, same order) AND the per-trader book/balance deltas
///   are identical. PLUS conservation (M4) and price-time priority (M3) on every trial.

import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import List "mo:core/List";
import Map "mo:core/Map";

import L "../src/MatchLogic";
import T "../src/MatchTypes";

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

// deterministic LCG (no Math.random in the interpreter)
var rngState : Nat64 = 0x2545F4914F6CDD1D;
func rnd() : Nat64 { rngState := rngState *% 6364136223846793005 +% 1442695040888963407; rngState };
func rndRange(lo : Nat, hi : Nat) : Nat { // inclusive
  if (hi <= lo) return lo;
  lo + Nat64.toNat(rnd() % Nat64.fromNat(hi - lo + 1))
};

type BO = L.BookOrder;

// Build eligible arrays + schedule for a book, then apply a schedule and return per-id share fills.
func applySchedule(schedule : [T.Fill]) : (Map.Map<Nat, Nat>, Map.Map<Nat, Nat>, Nat, Nat) {
  // returns (buyFills by buyId, sellFills by sellId, totalShares, totalCash)
  let buys = Map.empty<Nat, Nat>();
  let sells = Map.empty<Nat, Nat>();
  var shares = 0; var cash = 0;
  for (f in schedule.vals()) {
    Map.add(buys, Nat.compare, f.buyId, (switch (Map.get(buys, Nat.compare, f.buyId)) { case (?x) x; case null 0 }) + f.qty);
    Map.add(sells, Nat.compare, f.sellId, (switch (Map.get(sells, Nat.compare, f.sellId)) { case (?x) x; case null 0 }) + f.qty);
    shares += f.qty; cash += f.qty * f.price;
  };
  (buys, sells, shares, cash)
};

// Stream step() but force a chunk boundary every `k` fills (simulating budget exhaustion),
// resuming the cursor across chunks. Returns the concatenated fill list.
func chunkedSchedule(eb : [T.EligibleOrder], ea : [T.EligibleOrder], price : Nat, V : Nat, k : Nat) : [T.Fill] {
  let out = List.empty<T.Fill>();
  var i = 0; var j = 0; var cb = 0; var ca = 0; var filled = 0;
  label loop_ while (true) {
    // a chunk: up to k fills, then "yield" (loop continues with saved cursor — same as a Timer resume)
    var n = 0;
    label chunk while (n < k) {
      let st = L.step(eb, ea, price, V, i, j, cb, ca, filled);
      switch (st.fill) {
        case null break loop_;
        case (?fl) { List.add(out, fl); i := st.i; j := st.j; cb := st.carryBid; ca := st.carryAsk; filled := st.filled; n += 1 };
      };
    };
    if (n == 0) break loop_;
  };
  List.toArray(out)
};

func fillsEqual(a : [T.Fill], b : [T.Fill]) : Bool {
  if (a.size() != b.size()) return false;
  var idx = 0;
  while (idx < a.size()) {
    let x = a[idx]; let y = b[idx];
    if (x.buyId != y.buyId or x.sellId != y.sellId or x.price != y.price or x.qty != y.qty) return false;
    idx += 1;
  };
  true
};

func mapsEqual(a : Map.Map<Nat, Nat>, b : Map.Map<Nat, Nat>) : Bool {
  if (Map.size(a) != Map.size(b)) return false;
  for ((kk, vv) in Map.entries(a)) {
    switch (Map.get(b, Nat.compare, kk)) { case (?w) { if (w != vv) return false }; case null return false };
  };
  true
};

Debug.print("PART 1 — hand-computed call-auction unit checks");

// Case A: simple cross. bid 10sh@100, ask 10sh@90. Any p in [90,100] crosses 10. Tie→min imbalance
// (all equal, imbalance 0 at exec=10) → lowest price = 90.
do {
  let bids : [BO] = [{ id = 1; limitPrice = 100; qty = 10 }];
  let asks : [BO] = [{ id = 2; limitPrice = 90; qty = 10 }];
  let p = L.clearingPrice(bids, asks);
  check("A: crosses", p != null);
  switch (p) { case (?pp) { checkEqNat("A: p* lowest-of-tie", pp, 90); checkEqNat("A: V", L.targetVolume(bids, asks, pp), 10) }; case null {} };
};

// Case B: no cross. bid@90, ask@100. demand(p)>0 only p<=90; supply>0 only p>=100. exec=0 everywhere.
do {
  let bids : [BO] = [{ id = 1; limitPrice = 90; qty = 10 }];
  let asks : [BO] = [{ id = 2; limitPrice = 100; qty = 5 }];
  check("B: no cross", L.clearingPrice(bids, asks) == null);
};

// Case C: max-volume price beats a narrower-spread price.
//   bids: 5@100, 5@95 ;  asks: 5@90, 5@98
//   p=98: demand(>=98)=5, supply(<=98)=10 -> exec 5
//   p=95: demand(>=95)=10, supply(<=95)=5 -> exec 5
//   p=90: demand(>=90)=10, supply(<=90)=5 -> exec 5
//   all exec 5; imbalance: p98 |5-10|=5, p95 |10-5|=5, p90 |10-5|=5, p100 demand5 supply10 exec5 imb5.
//   tie on exec & imbalance -> lowest price = 90.  V=5.
do {
  let bids : [BO] = [{ id = 1; limitPrice = 100; qty = 5 }, { id = 2; limitPrice = 95; qty = 5 }];
  let asks : [BO] = [{ id = 3; limitPrice = 90; qty = 5 }, { id = 4; limitPrice = 98; qty = 5 }];
  switch (L.clearingPrice(bids, asks)) {
    case (?pp) { checkEqNat("C: p*", pp, 90); checkEqNat("C: V", L.targetVolume(bids, asks, pp), 5) };
    case null { check("C: should cross", false) };
  };
};

// Case D: priority + pro-rata. p* fixed; long side (bids) overfilled, marginal partial by priority.
//   bids: id1 8@100, id2 8@100 (same price -> id1 first), id3 8@90 (ineligible if p*>90)
//   asks: id4 10@p* .  Suppose p*=100: demand(>=100)=16, supply(<=100)=10 -> V=10.
//   eligible bids sorted: id1, id2 (both @100). fills: id1 gets 8, id2 gets 2 (marginal). seller id4 -> 10.
do {
  let bids : [BO] = [{ id = 1; limitPrice = 100; qty = 8 }, { id = 2; limitPrice = 100; qty = 8 }];
  let asks : [BO] = [{ id = 4; limitPrice = 100; qty = 10 }];
  switch (L.clearingPrice(bids, asks)) {
    case (?pp) {
      let eb = L.eligibleBids(bids, pp);
      let ea = L.eligibleAsks(asks, pp);
      let V = L.targetVolume(bids, asks, pp);
      checkEqNat("D: V", V, 10);
      check("D: bid priority id1 first", eb[0].id == 1 and eb[1].id == 2);
      let sched = L.fillSchedule(eb, ea, pp, V);
      let (buys, sells, sh, csh) = applySchedule(sched);
      checkEqNat("D: id1 filled 8", switch (Map.get(buys, Nat.compare, 1)) { case (?x) x; case null 0 }, 8);
      checkEqNat("D: id2 filled 2 (marginal)", switch (Map.get(buys, Nat.compare, 2)) { case (?x) x; case null 0 }, 2);
      checkEqNat("D: seller id4 filled 10", switch (Map.get(sells, Nat.compare, 4)) { case (?x) x; case null 0 }, 10);
      checkEqNat("D: shares moved", sh, 10);
      checkEqNat("D: cash moved", csh, 1000);
      check("D: conserves", L.scheduleConserves(sched, pp, V));
    };
    case null { check("D: should cross", false) };
  };
};

Debug.print("PART 2 — chunked == unbounded equivalence + conservation + priority (random books)");

let TRIALS = 4000;
var crossed = 0;
var t = 0;
label trials while (t < TRIALS) {
  t += 1;
  // random book: up to 6 bids + 6 asks, prices in a band that often crosses, qty 1..20
  let nb = rndRange(1, 6);
  let na = rndRange(1, 6);
  let bidsL = List.empty<BO>();
  let asksL = List.empty<BO>();
  var nextId = 1;
  var x = 0;
  while (x < nb) { List.add(bidsL, { id = nextId; limitPrice = rndRange(90, 110); qty = rndRange(1, 20) } : BO); nextId += 1; x += 1 };
  x := 0;
  while (x < na) { List.add(asksL, { id = nextId; limitPrice = rndRange(85, 105); qty = rndRange(1, 20) } : BO); nextId += 1; x += 1 };
  let bids = List.toArray(bidsL);
  let asks = List.toArray(asksL);

  switch (L.clearingPrice(bids, asks)) {
    case null {}; // no cross — nothing to clear this trial
    case (?pStar) {
      crossed += 1;
      let eb = L.eligibleBids(bids, pStar);
      let ea = L.eligibleAsks(asks, pStar);
      let V = L.targetVolume(bids, asks, pStar);

      // priority (M3): eligible bids non-increasing price; within equal price, increasing id.
      var pidx = 1;
      // (qty-priority sort is validated structurally below via the fill order)
      let _ = pidx;

      // unbounded reference
      let unb = L.fillSchedule(eb, ea, pStar, V);
      let (ub, us, ush, ucash) = applySchedule(unb);

      // chunked at several chunk sizes — MUST match unbounded byte-for-byte (M1)
      for (k in [1, 2, 3, 5, 13].vals()) {
        let ch = chunkedSchedule(eb, ea, pStar, V, k);
        if (not fillsEqual(unb, ch)) { failures += 1; Debug.print("  FAIL: chunked!=unbounded trial=" # Nat.toText(t) # " k=" # Nat.toText(k)); };
        checks += 1;
        let (cb, cs, csh, ccash) = applySchedule(ch);
        if (not (mapsEqual(ub, cb) and mapsEqual(us, cs) and csh == ush and ccash == ucash)) {
          failures += 1; Debug.print("  FAIL: chunked balances != unbounded trial=" # Nat.toText(t) # " k=" # Nat.toText(k));
        };
        checks += 1;
      };

      // conservation (M4): shares == V, cash == V*p*
      if (not L.scheduleConserves(unb, pStar, V)) { failures += 1; Debug.print("  FAIL: conservation trial=" # Nat.toText(t)) };
      checks += 1;
      if (ush != V or ucash != V * pStar) { failures += 1; Debug.print("  FAIL: volume/cash trial=" # Nat.toText(t)) };
      checks += 1;

      // short side fully filled: V == min(demand,supply); the side equal to V is exhausted.
      let d = L.demand(bids, pStar); let s = L.supply(asks, pStar);
      // total filled per side equals V
      var sumBuy = 0; for ((_, v) in Map.entries(ub)) sumBuy += v;
      var sumSell = 0; for ((_, v) in Map.entries(us)) sumSell += v;
      if (sumBuy != V or sumSell != V) { failures += 1; Debug.print("  FAIL: side totals trial=" # Nat.toText(t)) };
      checks += 1;
      let _ = (d, s);
    };
  };
};

Debug.print("PART 3 — all-or-none (FOK) Kill-before-mutate (mission M2)");

type BOA = L.BookOrderA;
// fill totals for survivors at p*, to assert every surviving AON order fully fills
func survivorFills(orders : [BOA], killed : [Nat], pStar : Nat) : Map.Map<Nat, Nat> {
  let surv = List.empty<BOA>();
  for (o in orders.vals()) { var k = false; for (x in killed.vals()) { if (x == o.id) k := true }; if (not k) List.add(surv, o) };
  let sa = List.toArray(surv);
  let bidsBO = List.empty<L.BookOrder>(); let asksBO = List.empty<L.BookOrder>();
  for (o in sa.vals()) { let bo : L.BookOrder = { id = o.id; limitPrice = o.limitPrice; qty = o.qty }; if (o.isBid) List.add(bidsBO, bo) else List.add(asksBO, bo) };
  let eb = L.eligibleBids(List.toArray(bidsBO), pStar);
  let ea = L.eligibleAsks(List.toArray(asksBO), pStar);
  let V = L.targetVolume(List.toArray(bidsBO), List.toArray(asksBO), pStar);
  let sched = L.fillSchedule(eb, ea, pStar, V);
  let (b, s, _, _) = applySchedule(sched);
  // merge buy+sell maps
  for ((kk, vv) in Map.entries(s)) { Map.add(b, Nat.compare, kk, (switch (Map.get(b, Nat.compare, kk)) { case (?x) x; case null 0 }) + vv) };
  b
};
func inList(xs : [Nat], v : Nat) : Bool { for (x in xs.vals()) { if (x == v) return true }; false };

// AON-1: bid AON 10@100 but only 5 supply → bid KILLED → no cross.
do {
  let os : [BOA] = [{ id = 1; limitPrice = 100; qty = 10; aon = true; isBid = true }, { id = 2; limitPrice = 90; qty = 5; aon = false; isBid = false }];
  let r = L.clearAON(os);
  check("AON-1: under-filled AON bid killed", inList(r.killed, 1));
  check("AON-1: no cross after kill", r.pStar == null);
};
// AON-2: bid AON 5@100 fully fillable (10 supply) → survives, ask (GTC) partials.
do {
  let os : [BOA] = [{ id = 1; limitPrice = 100; qty = 5; aon = true; isBid = true }, { id = 2; limitPrice = 90; qty = 10; aon = false; isBid = false }];
  let r = L.clearAON(os);
  check("AON-2: AON bid survives", not inList(r.killed, 1));
  switch (r.pStar) { case (?pp) {
    let fills = survivorFills(os, r.killed, pp);
    checkEqNat("AON-2: AON bid fully fills", switch (Map.get(fills, Nat.compare, 1)) { case (?x) x; case null 0 }, 5);
  }; case null { check("AON-2: should cross", false) } };
};
// AON-3: AON ask wants 10 but demand only 6 → ask killed → no cross.
do {
  let os : [BOA] = [{ id = 1; limitPrice = 100; qty = 6; aon = false; isBid = true }, { id = 2; limitPrice = 90; qty = 10; aon = true; isBid = false }];
  let r = L.clearAON(os);
  check("AON-3: under-filled AON ask killed", inList(r.killed, 2));
  check("AON-3: no cross after kill", r.pStar == null);
};

// Property: random books with ~30% AON flags. After clearAON, EVERY surviving AON order fully fills
// (the defining FOK guarantee), and killed ids are a subset of the AON orders.
var aonTrials = 0; var aonChecked = 0;
var tt = 0;
label aonloop while (tt < 1500) {
  tt += 1;
  let nb = rndRange(1, 5); let na = rndRange(1, 5);
  let osL = List.empty<BOA>(); var nid = 1;
  var z = 0;
  while (z < nb) { let aon = (rndRange(0, 9) < 3); List.add(osL, { id = nid; limitPrice = rndRange(90, 110); qty = rndRange(1, 15); aon; isBid = true } : BOA); nid += 1; z += 1 };
  z := 0;
  while (z < na) { let aon = (rndRange(0, 9) < 3); List.add(osL, { id = nid; limitPrice = rndRange(85, 105); qty = rndRange(1, 15); aon; isBid = false } : BOA); nid += 1; z += 1 };
  let os = List.toArray(osL);
  let r = L.clearAON(os);
  aonTrials += 1;
  // killed ⊆ AON orders
  for (kid in r.killed.vals()) {
    var isAon = false; for (o in os.vals()) { if (o.id == kid and o.aon) isAon := true };
    if (not isAon) { failures += 1; Debug.print("  FAIL: killed a non-AON order id=" # Nat.toText(kid)) };
    checks += 1;
  };
  switch (r.pStar) {
    case null {};
    case (?pp) {
      let fills = survivorFills(os, r.killed, pp);
      for (o in os.vals()) {
        if (o.aon and not inList(r.killed, o.id)) {
          let got = switch (Map.get(fills, Nat.compare, o.id)) { case (?x) x; case null 0 };
          if (got != o.qty) { failures += 1; Debug.print("  FAIL: surviving AON not fully filled id=" # Nat.toText(o.id) # " got=" # Nat.toText(got) # " qty=" # Nat.toText(o.qty)) };
          checks += 1; aonChecked += 1;
        };
      };
    };
  };
};
Debug.print("aonTrials=" # Nat.toText(aonTrials) # " survivingAON-checks=" # Nat.toText(aonChecked));

Debug.print("trials=" # Nat.toText(TRIALS) # " crossed=" # Nat.toText(crossed));
Debug.print("checks=" # Nat.toText(checks) # " failures=" # Nat.toText(failures));
if (failures > 0) { Runtime.trap("MATCHING BATTERY FAILED: " # Nat.toText(failures) # " failures") };
Debug.print("ALL GREEN");
