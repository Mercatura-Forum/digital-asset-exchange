/// MatchLogic.mo — the PURE decision core of the frequent batch-auction CLOB.
///
/// Referentially transparent (no awaits, no state, no I/O): exhaustively testable under
/// `mops test --mode interpreter` with no replica. The actor (Matching.mo) and the battery both
/// call these, so the tests exercise production code. This is where the M1 (chunked == unbounded),
/// M2 (Kill-before-mutate), M3 (priority), M4 (conservation) guarantees are proven at the logic level.
///
/// Microstructure: frequent batch auction, single uniform clearing price p* per window
/// (Budish–Cramton–Shim). p* maximises executable volume; ties broken to minimum imbalance, then
/// lowest price (deterministic ⇒ identical p* on all 4 nodes ⇒ INV-E2/INV-C2).

import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Order "mo:core/Order";
import List "mo:core/List";
import Map "mo:core/Map";
import T "MatchTypes";

module {

  // Raw order projection fed to the clearing math.
  public type BookOrder = { id : Nat; limitPrice : Nat; qty : Nat };

  public type Result_<X> = { #ok : X; #err : Text };

  // ── Demand / supply curves ───────────────────────────────────────────────────────────────
  // demand(p) = Σ qty over bids whose limit >= p (willing to buy AT p).
  public func demand(bids : [BookOrder], p : Nat) : Nat {
    var s = 0; for (b in bids.vals()) { if (b.limitPrice >= p) s += b.qty }; s
  };
  // supply(p) = Σ qty over asks whose limit <= p (willing to sell AT p).
  public func supply(asks : [BookOrder], p : Nat) : Nat {
    var s = 0; for (a in asks.vals()) { if (a.limitPrice <= p) s += a.qty }; s
  };

  // Executable volume at price p (the standard call-auction objective).
  public func executable(bids : [BookOrder], asks : [BookOrder], p : Nat) : Nat {
    Nat.min(demand(bids, p), supply(asks, p))
  };

  // Candidate clearing prices = the union of all limit prices (the executable-volume function
  // is piecewise-constant and only changes at limit prices, so the optimum is attained at one).
  func candidatePrices(bids : [BookOrder], asks : [BookOrder]) : [Nat] {
    let acc = List.empty<Nat>();
    let seen = List.empty<Nat>();
    func push(p : Nat) {
      for (x in List.values(seen)) { if (x == p) return };
      List.add(seen, p); List.add(acc, p);
    };
    for (b in bids.vals()) push(b.limitPrice);
    for (a in asks.vals()) push(a.limitPrice);
    List.toArray(acc)
  };

  // ── Uniform clearing price p* ────────────────────────────────────────────────────────────
  // argmax executable; tie → min |demand−supply| (imbalance); tie → lowest price. Deterministic.
  // Returns null when no price crosses any volume (executable == 0 everywhere).
  public func clearingPrice(bids : [BookOrder], asks : [BookOrder]) : ?Nat {
    let cands = candidatePrices(bids, asks);
    var best : ?Nat = null;
    var bestExec : Nat = 0;
    var bestImb : Nat = 0;
    for (p in cands.vals()) {
      let d = demand(bids, p);
      let s = supply(asks, p);
      let ex = Nat.min(d, s);
      if (ex > 0) {
        let imb = if (d > s) d - s else s - d;
        let take = switch (best) {
          case null true;
          case (?bp) {
            if (ex > bestExec) true
            else if (ex < bestExec) false
            else if (imb < bestImb) true
            else if (imb > bestImb) false
            else p < bp;          // lowest price tie-break
          };
        };
        if (take) { best := ?p; bestExec := ex; bestImb := imb };
      };
    };
    best
  };

  // Total shares to cross at p* = min(demand, supply).
  public func targetVolume(bids : [BookOrder], asks : [BookOrder], pStar : Nat) : Nat {
    executable(bids, asks, pStar)
  };

  // ── Eligible, priority-sorted sides at p* ──────────────────────────────────────────────────
  // Bids eligible at p*: limit >= p*, sorted (limitPrice desc, id asc) — best price first, then
  // earliest arrival (time priority). Asks: limit <= p*, sorted (limitPrice asc, id asc).
  public func eligibleBids(bids : [BookOrder], pStar : Nat) : [T.EligibleOrder] {
    let f = Array.filter<BookOrder>(bids, func b = b.limitPrice >= pStar);
    let s = Array.sort<BookOrder>(f, func(x, y) {
      if (x.limitPrice > y.limitPrice) #less        // higher price = higher priority
      else if (x.limitPrice < y.limitPrice) #greater
      else Nat.compare(x.id, y.id)                  // earlier id = higher priority
    });
    Array.map<BookOrder, T.EligibleOrder>(s, func b = { id = b.id; qty = b.qty })
  };
  public func eligibleAsks(asks : [BookOrder], pStar : Nat) : [T.EligibleOrder] {
    let f = Array.filter<BookOrder>(asks, func a = a.limitPrice <= pStar);
    let s = Array.sort<BookOrder>(f, func(x, y) {
      if (x.limitPrice < y.limitPrice) #less        // lower price = higher priority
      else if (x.limitPrice > y.limitPrice) #greater
      else Nat.compare(x.id, y.id)
    });
    Array.map<BookOrder, T.EligibleOrder>(s, func a = { id = a.id; qty = a.qty })
  };

  // ── Resumable fill planner (the M1 crux) ─────────────────────────────────────────────────
  // One greedy micro-fill: fill min(boundary bid remaining, boundary ask remaining, V−filled)
  // between eligBids[i] and eligAsks[j], all at p*. PURE: returns the next cursor + an optional
  // fill. carryBid/carryAsk == 0 means "(re)load from the order's qty" (a fresh boundary order).
  // Iterating step() from (0,0,0,0,0) reproduces the full schedule; ANY chunk boundary (the actor
  // stops on instruction budget, the test stops on a count) yields the SAME concatenated schedule —
  // that is the chunked == unbounded equivalence.
  public type StepState = {
    fill : ?T.Fill;
    i : Nat; j : Nat;
    carryBid : Nat; carryAsk : Nat;
    filled : Nat;
  };

  public func step(
    eligBids : [T.EligibleOrder],
    eligAsks : [T.EligibleOrder],
    price : Nat,
    targetV : Nat,
    i0 : Nat, j0 : Nat, carryBid0 : Nat, carryAsk0 : Nat, filled0 : Nat,
  ) : StepState {
    if (filled0 >= targetV or i0 >= eligBids.size() or j0 >= eligAsks.size()) {
      return { fill = null; i = i0; j = j0; carryBid = carryBid0; carryAsk = carryAsk0; filled = filled0 };
    };
    let cb = if (carryBid0 == 0) eligBids[i0].qty else carryBid0;
    let ca = if (carryAsk0 == 0) eligAsks[j0].qty else carryAsk0;
    let f = Nat.min(Nat.min(cb, ca), targetV - filled0);
    let fill : T.Fill = { buyId = eligBids[i0].id; sellId = eligAsks[j0].id; price; qty = f };
    let cb2 : Nat = cb - f;
    let ca2 : Nat = ca - f;
    var i1 = i0; var j1 = j0; var carryB = cb2; var carryA = ca2;
    if (cb2 == 0) { i1 += 1; carryB := 0 };
    if (ca2 == 0) { j1 += 1; carryA := 0 };
    { fill = ?fill; i = i1; j = j1; carryBid = carryB; carryAsk = carryA; filled = filled0 + f }
  };

  // Unbounded reference: the full fill schedule (used as the M1 ground truth and by the actor's
  // own off-chain reference; the actor itself NEVER materialises this — it streams step() under a
  // perf-counter budget so a pathologically deep book never blows one message, M5).
  public func fillSchedule(
    eligBids : [T.EligibleOrder],
    eligAsks : [T.EligibleOrder],
    price : Nat,
    targetV : Nat,
  ) : [T.Fill] {
    let out = List.empty<T.Fill>();
    var i = 0; var j = 0; var cb = 0; var ca = 0; var filled = 0;
    label loop_ while (true) {
      let st = step(eligBids, eligAsks, price, targetV, i, j, cb, ca, filled);
      switch (st.fill) {
        case null break loop_;
        case (?fl) { List.add(out, fl); i := st.i; j := st.j; cb := st.carryBid; ca := st.carryAsk; filled := st.filled };
      };
    };
    List.toArray(out)
  };

  // ── All-or-none (FOK) resolution — Kill-before-mutate (mission M2) ──────────────────────────
  // An AON order must fill its FULL qty at p* this window or be KILLED. Standard call-auction
  // fixpoint: clear; if any AON order is under-filled, remove the LOWEST-priority such order and
  // re-clear; repeat until stable. PURE & read-only — it computes the KILL set WITHOUT mutating any
  // book (the actor mutates only afterwards), which IS Oisy's Kill-before-mutate. Returns the final
  // p* over survivors and the killed id set. Skips schedule materialisation entirely when there are
  // no AON orders (the deep-crossing M5 path stays O(book), never O(fills)).
  public type BookOrderA = { id : Nat; limitPrice : Nat; qty : Nat; aon : Bool; isBid : Bool };

  func anyAon(os : [BookOrderA]) : Bool { for (o in os.vals()) { if (o.aon) return true }; false };
  func toBO(os : [BookOrderA]) : [BookOrder] = Array.map<BookOrderA, BookOrder>(os, func o = { id = o.id; limitPrice = o.limitPrice; qty = o.qty });

  // total filled per order id for the current survivor set, via one unbounded reference schedule
  func fillByIdFor(orders : [BookOrderA], pStar : Nat) : Map.Map<Nat, Nat> {
    let bids = Array.filter<BookOrderA>(orders, func o = o.isBid);
    let asks = Array.filter<BookOrderA>(orders, func o = not o.isBid);
    let eb = eligibleBids(toBO(bids), pStar);
    let ea = eligibleAsks(toBO(asks), pStar);
    let V = targetVolume(toBO(bids), toBO(asks), pStar);
    let sched = fillSchedule(eb, ea, pStar, V);
    let m = Map.empty<Nat, Nat>();
    for (f in sched.vals()) {
      Map.add(m, Nat.compare, f.buyId, (switch (Map.get(m, Nat.compare, f.buyId)) { case (?x) x; case null 0 }) + f.qty);
      Map.add(m, Nat.compare, f.sellId, (switch (Map.get(m, Nat.compare, f.sellId)) { case (?x) x; case null 0 }) + f.qty);
    };
    m
  };

  public func clearAON(ordersIn : [BookOrderA]) : { pStar : ?Nat; killed : [Nat] } {
    // fast path: no AON orders → single clearingPrice, no schedule materialised (M5-safe)
    if (not anyAon(ordersIn)) {
      let bids = Array.filter<BookOrderA>(ordersIn, func o = o.isBid);
      let asks = Array.filter<BookOrderA>(ordersIn, func o = not o.isBid);
      return { pStar = clearingPrice(toBO(bids), toBO(asks)); killed = [] };
    };
    aonFix(ordersIn, List.empty<Nat>())
  };

  // Recursive fixpoint: clear; if an AON order is under-filled, KILL the lowest-priority one and
  // re-clear over the rest. Terminates (the survivor set strictly shrinks each step). Read-only.
  func aonFix(orders : [BookOrderA], killed : List.List<Nat>) : { pStar : ?Nat; killed : [Nat] } {
    let bids = Array.filter<BookOrderA>(orders, func o = o.isBid);
    let asks = Array.filter<BookOrderA>(orders, func o = not o.isBid);
    switch (clearingPrice(toBO(bids), toBO(asks))) {
      case null { { pStar = null; killed = List.toArray(killed) } };
      case (?pStar) {
        let fills = fillByIdFor(orders, pStar);
        // Deterministic victim = under-filled AON order with the HIGHEST id (latest arrival = lowest
        // time priority): the newest order yields first, so established orders keep their priority.
        var victim : ?Nat = null;
        for (o in orders.vals()) {
          if (o.aon) {
            let got = switch (Map.get(fills, Nat.compare, o.id)) { case (?x) x; case null 0 };
            if (got < o.qty) {
              switch (victim) { case null victim := ?o.id; case (?vid) { if (o.id > vid) victim := ?o.id } };
            };
          };
        };
        switch (victim) {
          case null { { pStar = ?pStar; killed = List.toArray(killed) } }; // stable: all AON fully fill
          case (?vid) {
            List.add(killed, vid);
            aonFix(Array.filter<BookOrderA>(orders, func o = o.id != vid), killed)
          };
        };
      };
    };
  };

  // ── Conservation predicate (M4) ────────────────────────────────────────────────────────────
  // Across a fill schedule at uniform price p*: total shares moved == Σ qty == V, and total cash
  // moved == V·p*. Per buyer/seller the share and cash legs net exactly (q shares ⇄ q·p* cash).
  public func scheduleConserves(schedule : [T.Fill], pStar : Nat, targetV : Nat) : Bool {
    var shares = 0; var cash = 0;
    for (f in schedule.vals()) {
      if (f.price != pStar) return false;
      shares += f.qty; cash += f.qty * pStar;
    };
    shares == targetV and cash == targetV * pStar
  };
};
