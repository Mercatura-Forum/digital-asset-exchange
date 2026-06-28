/// MatchTypes.mo — types for the frequent-batch-auction CLOB matching engine.
///
/// The matching engine is a pure ORCHESTRATOR: it runs a price-time-priority order book, a
/// frequent batch-auction uniform-price clear, and emits per-match SETTLEMENT OBLIGATIONS that
/// settle through the EXISTING, UNCHANGED DvP core (a cleared (buyer,seller,price,qty) → a DvP
/// trade between seller=maker and buyer=taker, both-or-neither). It holds NO custody: escrow is
/// an ICRC-2 approval-to-core + an engine-side reservation (see Matching.mo).
///
/// The clearing math lives in the PURE module MatchLogic.mo, exercised by BOTH this actor and the
/// `mops test --mode interpreter` battery (same discipline as DvpLogic.mo).

module {

  public type Side = { #buy; #sell };

  // Open      : resting, awaiting (this or a later) window's clear.
  // PartiallyFilled : some qty filled, remainder rests with the ORIGINAL id (priority preserved).
  // Filled    : fully filled.
  // Cancelled : owner cancelled; reservation released.
  public type OrderStatus = { #Open; #PartiallyFilled; #Filled; #Cancelled };

  public type Order = {
    id : Nat;              // global, strictly-monotonic intake sequence — the price-TIME priority key
    owner : Principal;
    side : Side;
    limitPrice : Nat;      // cash base units PER share (buy: max it will pay; sell: min it will accept)
    qty : Nat;             // whole shares, original
    var remaining : Nat;   // unfilled shares
    window : Nat;          // clearing-window id this order belongs to
    allOrNone : Bool;      // FOK/AON: fill completely at p* this window or be KILLED (book untouched)
    var status : OrderStatus;
    createdAt : Nat64;
  };

  // Sorted, filtered, immutable view fed to the pure clearing planner.
  public type EligibleOrder = { id : Nat; qty : Nat };

  // A single micro-fill produced by the resumable planner.
  public type Fill = {
    buyId : Nat;
    sellId : Nat;
    price : Nat;           // == p* (uniform clearing price for the window)
    qty : Nat;             // whole shares moved in this micro-fill
  };

  // A settlement obligation = a cleared (buyer, seller, price, qty) → ONE DvP trade.
  // The engine emits it; it settles through the UNCHANGED DvP core (seller=maker, buyer=taker).
  public type Obligation = {
    seq : Nat;             // global obligation sequence
    window : Nat;
    buyId : Nat;  sellId : Nat;
    buyer : Principal;  seller : Principal;
    price : Nat;  qty : Nat;
    var dvpTradeId : ?Nat; // set once the DvP trade is opened (settlement linkage)
    var settled : Bool;
  };

  // Resumable chunked-clear cursor (mirrors CLMM PendingSwap). The eligible id/qty arrays + V + p*
  // are FIXED at window close (orders arriving during the chunking gap go to the NEXT window), so
  // chunk K reconstructs byte-identically to an unbounded reference run.
  public type PendingClear = {
    window : Nat;
    clearingPrice : Nat;   // p*, fixed at window close, reused across ALL chunks
    eligBids : [EligibleOrder];  // limitPrice >= p*, sorted (limitPrice desc, id asc)
    eligAsks : [EligibleOrder];  // limitPrice <= p*, sorted (limitPrice asc, id asc)
    targetVolume : Nat;    // V = min(demand(p*), supply(p*)) — total shares to cross
    var i : Nat;           // resume index into eligBids
    var j : Nat;           // resume index into eligAsks
    var carryBid : Nat;    // remaining qty of the boundary bid (0 => (re)load from eligBids[i].qty)
    var carryAsk : Nat;    // remaining qty of the boundary ask
    var filled : Nat;      // shares crossed so far this clear
    createdAt : Nat64;
  };

  // ── Public call/query result views ──────────────────────────────────────────────────────
  public type SubmitResult = {
    orderId : Nat;
    status : OrderStatus;
    reservedShares : Nat;  // asks: shares reserved against allowance-to-core
    reservedCash : Nat;    // bids: cash reserved against allowance-to-core
    note : Text;
  };

  public type ClearResult = {
    window : Nat;
    clearingPrice : ?Nat;  // null => no cross this window
    targetVolume : Nat;
    fillsThisCall : Nat;   // micro-fills applied in THIS message
    totalFilled : Nat;     // cumulative across chunks
    complete : Bool;       // true => clear fully done; false => a Timer resumes it next round
    chunks : Nat;          // how many chunk-messages this clear has used so far
    note : Text;
  };

  public type OrderView = {
    id : Nat; owner : Principal; side : Side;
    limitPrice : Nat; qty : Nat; remaining : Nat;
    window : Nat; allOrNone : Bool; status : OrderStatus; createdAt : Nat64;
  };

  public type ObligationView = {
    seq : Nat; window : Nat;
    buyId : Nat; sellId : Nat;
    buyer : Principal; seller : Principal;
    price : Nat; qty : Nat;
    dvpTradeId : ?Nat; settled : Bool;
  };

  public func orderView(o : Order) : OrderView {
    { id = o.id; owner = o.owner; side = o.side; limitPrice = o.limitPrice;
      qty = o.qty; remaining = o.remaining; window = o.window; allOrNone = o.allOrNone;
      status = o.status; createdAt = o.createdAt };
  };

  public func obligationView(b : Obligation) : ObligationView {
    { seq = b.seq; window = b.window; buyId = b.buyId; sellId = b.sellId;
      buyer = b.buyer; seller = b.seller; price = b.price; qty = b.qty;
      dvpTradeId = b.dvpTradeId; settled = b.settled };
  };
};
