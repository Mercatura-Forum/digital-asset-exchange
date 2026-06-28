/// DvpCore.mo — Delivery-versus-Payment atomic-swap core (BIS DvP Model 1).
///
/// Gross, simultaneous, both-or-neither settlement of an asset leg against a cash leg,
/// over two ICRC ledgers. Two-phase escrow state machine (the canonical IC
/// deposit-then-settle pattern): each party funds its leg INTO this canister's own
/// account; settlement fires only when BOTH legs are escrowed and pays out from the
/// balance the core already custodies (so a payout cannot fail for allowance reasons and
/// a transient ledger failure is safely retried, never double-paid). If both legs are not
/// escrowed by the deadline, each funded party reclaims its escrow in full.
///
/// The 5 INV-DVP invariants are enforced in-canister: conservation (DVP-1), DvP-gate
/// (DVP-2), no-double-resolve (DVP-3) trap on violation; no-stranding (DVP-4) logged;
/// idempotent settlement (DVP-5) enforced by per-leg markers + ledger created_at_time
/// dedup. Every order/fund/settle/abort is appended to a Merkle-Mountain-Range audit
/// trail whose root re-derives externally.
///
/// Funding primitive: ICRC-2 approve + transfer_from (core pulls into its own account).
/// Pay-out / refund primitive: ICRC-1 transfer from the core. Leg-agnostic: the state
/// machine never branches on leg kind — only the ledger-dispatch helpers do, so the same
/// proven core settles both a fungible share-for-cash trade and a non-fungible land-title sale.

import Principal "mo:core/Principal";
import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Time "mo:core/Time";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

import ICRC "ICRC";
import ICRC7 "ICRC7";
import MMR "MerkleMMR";
import Guards "Guards";
import T "DvpTypes";
import L "DvpLogic";

shared (initMsg) persistent actor class DvpCore() = self {

  // Silence unused-binding warning for the install message; the core has no admin gate
  // (settle/reclaim route funds only to predetermined destinations, so they are
  // permissionless among authenticated principals).
  ignore initMsg;

  // ── The core installer (deployer/controller). Used ONLY to authorize the matched-settlement
  // relayer surface below (setMatchingEngine); it does NOT gate any lifecycle function —
  // openTrade/fund*/settle/reclaim stay permissionless among authenticated principals. Captured
  // from the install message; on a state-preserving upgrade it is re-derived from the upgrade caller.
  transient let installer : Principal = initMsg.caller;

  // ── State ──────────────────────────────────────────────────────────────────────
  var nextTradeId : Nat = 1;
  let trades = Map.empty<Nat, T.Trade>();

  // Strictly-monotonic created_at_time allocator. Guarantees a globally-unique timestamp
  // per ledger call (even for trades funded in the same block, where Time.now() is equal),
  // while never drifting more than the number of same-instant allocations ahead of real
  // time. Stored per leg and REUSED on retry so a true replay hits the ledger dedup window.
  var catCursor : Nat64 = 0;

  // Audit-MMR over all lifecycle events.
  let mmr : MMR.State = MMR.newState();
  let auditLog = List.empty<T.AuditEvent>();
  var auditSeq : Nat = 0;

  // Diagnostic invariant log (INV-DVP-4 no-stranding). Safety invariants (1/2/3) trap.
  let invLog = List.empty<Text>();

  // ── Authorized-relayer surface for autonomous matched settlement ──────────────────────────────
  // The controller-set matching engine principal. ONLY this principal may call settleMatchFor
  // (which pairs two independent ICRC-2 approvals into one trade at a chosen price — a power that
  // must not be open to arbitrary callers). null until the installer binds it via setMatchingEngine.
  var matchingEngine : ?Principal = null;
  // Idempotency / lost-reply key: (calling matching engine, obligation seq) -> the trade id created
  // for it. A repeat settleMatchFor with a known key re-drives the SAME trade (never a second), so a
  // lost reply can be retried safely (exactly-once trade creation per cleared match). The key is
  // SCOPED TO THE CALLING ENGINE ("<enginePrincipal>|<seq>") so two different matching engines that
  // share this core never collide on each other's per-engine seq counters (which both start at 0).
  let matchSettlements = Map.empty<Text, Nat>();
  func matchKey(engine : Principal, seq : Nat) : Text { Principal.toText(engine) # "|" # Nat.toText(seq) };
  // Admin/relayer event log, kept OUT of the audit-MMR so the MMR stays lifecycle-only and its
  // root re-derives from the public event log alone. Diagnostic.
  let adminLog = List.empty<Text>();

  transient let mutex = Guards.MutexManager();
  transient let selfPrincipal = Principal.fromActor(self);

  type Side = { #A; #B };

  // ── Small helpers ────────────────────────────────────────────────────────────────
  func now64() : Nat64 { Nat64.fromNat(Int.abs(Time.now())) };

  func allocCat() : Nat64 {
    catCursor := L.nextCat(catCursor, now64());
    catCursor
  };

  func ledgerOf(p : Principal) : ICRC.Ledger { actor (Principal.toText(p)) };

  func requireAuth(caller : Principal) {
    if (Principal.isAnonymous(caller)) Runtime.trap("anonymous principal not allowed");
  };

  func acquire(id : Nat, op : Text) : Bool { mutex.tryAcquire(op # ":" # Nat.toText(id)) };
  func release(id : Nat, op : Text) { mutex.release(op # ":" # Nat.toText(id)) };

  func legState(t : T.Trade, s : Side) : T.LegState {
    switch (s) { case (#A) t.legAState; case (#B) t.legBState };
  };
  func leg(t : T.Trade, s : Side) : T.Leg {
    switch (s) { case (#A) t.legA; case (#B) t.legB };
  };
  func sideText(s : Side) : Text { switch (s) { case (#A) "A"; case (#B) "B" } };

  let HEX = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
  func hex(b : Blob) : Text {
    var out = "";
    for (byte in b.vals()) {
      let n = Nat8.toNat(byte);
      out := out # HEX[n / 16] # HEX[n % 16];
    };
    out
  };

  // ── Audit-MMR ──────────────────────────────────────────────────────────────────────
  func appendEvent(tradeId : Nat, encoded : Text) {
    let leaf = MMR.hashLeaf(Text.encodeUtf8(encoded));
    ignore MMR.append(mmr, leaf);
    List.add(auditLog, { seq = auditSeq; tradeId; encoded; leafHex = hex(leaf) });
    auditSeq += 1;
  };

  func logInv(msg : Text) { List.add(invLog, msg) };

  // ── Ledger dispatch (the only place that knows a leg's kind) ─────────────────────────
  // ESCROW: pull `owner`'s leg INTO the core's account (ICRC-2 transfer_from). Idempotent:
  // if already escrowed, returns the recorded block. Reuses a stored created_at_time so a
  // lost-reply replay is deduped (#Duplicate) rather than double-pulled.
  func escrowLeg(trade : T.Trade, s : Side, owner : Principal) : async* Result.Result<Nat, Text> {
    let st = legState(trade, s);
    let l = leg(trade, s);
    switch (st.escrowBlock) { case (?b) { return #ok(b) }; case null {} };
    let cat = switch (st.escrowCat) { case (?c) c; case null { let c = allocCat(); st.escrowCat := ?c; c } };
    switch (l.kind) {
      case (#icrc1 { amount }) {
        try {
          let r = await ledgerOf(l.ledger).icrc2_transfer_from({
            spender_subaccount = null;
            from = { owner; subaccount = null };
            to = { owner = selfPrincipal; subaccount = null };
            amount;
            fee = null;
            memo = null;
            created_at_time = ?cat;
          });
          switch (r) {
            case (#Ok(idx)) { recordEscrow(trade, s, idx, amount); #ok(idx) };
            case (#Err(#Duplicate({ duplicate_of }))) { recordEscrow(trade, s, duplicate_of, amount); #ok(duplicate_of) };
            case (#Err(#InsufficientAllowance({ allowance }))) #err("insufficient allowance: " # Nat.toText(allowance));
            case (#Err(#InsufficientFunds({ balance }))) #err("insufficient funds: " # Nat.toText(balance));
            case (#Err(#TooOld)) #err("escrow created_at_time too old");
            case (#Err(_)) #err("escrow transfer_from rejected");
          };
        } catch (_e) { #err("escrow call trapped/rejected") };
      };
      case (#icrc7 { tokenId }) {
        // ICRC-37 escrow-pull: the maker approved the core for this token_id; pull it into
        // the core's account. Batch call -> read element 0; #Ok or dedup #Duplicate => escrowed.
        // NFT is indivisible: escrowedAmount = 1 (the unit token), no fee arithmetic.
        try {
          let nft : ICRC7.Ledger7 = actor (Principal.toText(l.ledger));
          let res = await nft.icrc37_transfer_from([{
            spender_subaccount = null;
            from = { owner; subaccount = null };
            to = { owner = selfPrincipal; subaccount = null };
            token_id = tokenId;
            memo = null;
            created_at_time = ?cat;
          }]);
          let r0 = if (res.size() > 0) res[0] else null;
          switch (r0) {
            case (?#Ok(idx)) { recordEscrow(trade, s, idx, 1); #ok(idx) };
            case (?#Err(#Duplicate({ duplicate_of }))) { recordEscrow(trade, s, duplicate_of, 1); #ok(duplicate_of) };
            case (?#Err(#Unauthorized)) #err("icrc37 transfer_from unauthorized — approve the core for token " # Nat.toText(tokenId));
            case (?#Err(#NonExistingTokenId)) #err("icrc7 token does not exist: " # Nat.toText(tokenId));
            case (?#Err(#TooOld)) #err("icrc7 escrow created_at_time too old");
            case (?#Err(_)) #err("icrc37 transfer_from rejected");
            case (null) #err("icrc37 transfer_from returned null/short vec");
          };
        } catch (_e) { #err("icrc7 escrow call trapped/rejected") };
      };
    };
  };

  // Records a fresh escrow (sets flags + appends FUND event exactly once on the transition).
  func recordEscrow(trade : T.Trade, s : Side, idx : Nat, amount : Nat) {
    let st = legState(trade, s);
    if (st.escrowed) return; // idempotent — already recorded
    st.escrowed := true;
    st.escrowBlock := ?idx;
    st.escrowedAmount := amount;
    appendEvent(trade.id, "FUND_" # sideText(s) # "|id=" # Nat.toText(trade.id)
      # "|block=" # Nat.toText(idx) # "|amount=" # Nat.toText(amount));
  };

  // PAYOUT: send the escrowed leg OUT to `recipient` (ICRC-1 transfer), net of the ledger
  // fee (the recipient bears the outbound fee; the core's per-leg balance returns to 0).
  // Idempotent via the per-leg marker + a stored created_at_time (replay -> #Duplicate).
  func payoutLeg(trade : T.Trade, s : Side, recipient : Principal) : async* Result.Result<Nat, Text> {
    let st = legState(trade, s);
    let l = leg(trade, s);
    if (st.refund != null) Runtime.trap("INV-DVP-3: payout attempted on refunded leg " # sideText(s) # " of trade " # Nat.toText(trade.id));
    switch (st.payout) { case (?b) { return #ok(b) }; case null {} };
    if (not st.escrowed) return #err("cannot pay out a leg that is not escrowed");
    switch (l.kind) {
      case (#icrc1 _) {
        let fee = try { await ledgerOf(l.ledger).icrc1_fee() } catch (_e) { return #err("payout fee read failed") };
        let payAmt = switch (L.netAfterFee(st.escrowedAmount, fee)) { case (#ok(n)) n; case (#err(e)) return #err(e) };
        let cat = switch (st.payoutCat) { case (?c) c; case null { let c = allocCat(); st.payoutCat := ?c; c } };
        try {
          let r = await ledgerOf(l.ledger).icrc1_transfer({
            from_subaccount = null;
            to = { owner = recipient; subaccount = null };
            amount = payAmt;
            fee = ?fee;
            memo = null;
            created_at_time = ?cat;
          });
          switch (r) {
            case (#Ok(idx)) { recordPayout(trade, s, idx, payAmt); #ok(idx) };
            case (#Err(#Duplicate({ duplicate_of }))) { recordPayout(trade, s, duplicate_of, payAmt); #ok(duplicate_of) };
            case (#Err(#TemporarilyUnavailable)) #err("ledger temporarily unavailable");
            case (#Err(_)) #err("payout transfer rejected");
          };
        } catch (_e) { #err("payout call trapped/rejected") };
      };
      case (#icrc7 { tokenId }) {
        // ICRC-7 payout: the core (current owner) transfers the escrowed token to `recipient`.
        // An NFT carries no fee field and is indivisible — no netAfterFee, transfer the whole
        // token. Idempotent via the stored payoutCat (replay -> #Duplicate => already paid).
        let cat = switch (st.payoutCat) { case (?c) c; case null { let c = allocCat(); st.payoutCat := ?c; c } };
        try {
          let nft : ICRC7.Ledger7 = actor (Principal.toText(l.ledger));
          let res = await nft.icrc7_transfer([{
            from_subaccount = null;
            to = { owner = recipient; subaccount = null };
            token_id = tokenId;
            memo = null;
            created_at_time = ?cat;
          }]);
          let r0 = if (res.size() > 0) res[0] else null;
          switch (r0) {
            case (?#Ok(idx)) { recordPayout(trade, s, idx, 1); #ok(idx) };
            case (?#Err(#Duplicate({ duplicate_of }))) { recordPayout(trade, s, duplicate_of, 1); #ok(duplicate_of) };
            case (?#Err(_)) #err("icrc7 payout transfer rejected");
            case (null) #err("icrc7 payout returned null/short vec");
          };
        } catch (_e) { #err("icrc7 payout call trapped/rejected") };
      };
    };
  };

  func recordPayout(trade : T.Trade, s : Side, idx : Nat, amount : Nat) {
    let st = legState(trade, s);
    if (st.payout != null) return;
    st.payout := ?idx;
    st.payoutAmount := amount;
  };

  // REFUND: send an escrowed leg back to its `owner` after the deadline (ICRC-1 transfer,
  // net of fee). Idempotent. A leg that was never escrowed is a no-op.
  func refundLeg(trade : T.Trade, s : Side, owner : Principal) : async* Result.Result<Nat, Text> {
    let st = legState(trade, s);
    let l = leg(trade, s);
    if (st.payout != null) Runtime.trap("INV-DVP-3: refund attempted on paid-out leg " # sideText(s) # " of trade " # Nat.toText(trade.id));
    switch (st.refund) { case (?b) { return #ok(b) }; case null {} };
    if (not st.escrowed) return #ok(0); // nothing escrowed -> nothing to refund
    switch (l.kind) {
      case (#icrc1 _) {
        let fee = try { await ledgerOf(l.ledger).icrc1_fee() } catch (_e) { return #err("refund fee read failed") };
        let refAmt = switch (L.netAfterFee(st.escrowedAmount, fee)) { case (#ok(n)) n; case (#err(e)) return #err(e) };
        let cat = switch (st.refundCat) { case (?c) c; case null { let c = allocCat(); st.refundCat := ?c; c } };
        try {
          let r = await ledgerOf(l.ledger).icrc1_transfer({
            from_subaccount = null;
            to = { owner; subaccount = null };
            amount = refAmt;
            fee = ?fee;
            memo = null;
            created_at_time = ?cat;
          });
          switch (r) {
            case (#Ok(idx)) { recordRefund(trade, s, idx, refAmt); #ok(idx) };
            case (#Err(#Duplicate({ duplicate_of }))) { recordRefund(trade, s, duplicate_of, refAmt); #ok(duplicate_of) };
            case (#Err(#TemporarilyUnavailable)) #err("ledger temporarily unavailable");
            case (#Err(_)) #err("refund transfer rejected");
          };
        } catch (_e) { #err("refund call trapped/rejected") };
      };
      case (#icrc7 { tokenId }) {
        // ICRC-7 refund: the core returns the escrowed token to its `owner` after the
        // deadline. Same indivisible-token semantics as payout. Idempotent via refundCat.
        let cat = switch (st.refundCat) { case (?c) c; case null { let c = allocCat(); st.refundCat := ?c; c } };
        try {
          let nft : ICRC7.Ledger7 = actor (Principal.toText(l.ledger));
          let res = await nft.icrc7_transfer([{
            from_subaccount = null;
            to = { owner; subaccount = null };
            token_id = tokenId;
            memo = null;
            created_at_time = ?cat;
          }]);
          let r0 = if (res.size() > 0) res[0] else null;
          switch (r0) {
            case (?#Ok(idx)) { recordRefund(trade, s, idx, 1); #ok(idx) };
            case (?#Err(#Duplicate({ duplicate_of }))) { recordRefund(trade, s, duplicate_of, 1); #ok(duplicate_of) };
            case (?#Err(_)) #err("icrc7 refund transfer rejected");
            case (null) #err("icrc7 refund returned null/short vec");
          };
        } catch (_e) { #err("icrc7 refund call trapped/rejected") };
      };
    };
  };

  func recordRefund(trade : T.Trade, s : Side, idx : Nat, amount : Nat) {
    let st = legState(trade, s);
    if (st.refund != null) return;
    st.refund := ?idx;
    st.refundAmount := amount;
  };

  // ── The invariant oracle ───────────────────────────────────────────────────────────
  func checkInvariants(trade : T.Trade, phase : Text) {
    let a = trade.legAState;
    let b = trade.legBState;
    // INV-DVP-3 (no double-resolve) — safety, trap.
    if (a.payout != null and a.refund != null) Runtime.trap("INV-DVP-3 fail @" # phase # ": legA paid AND refunded, trade " # Nat.toText(trade.id));
    if (b.payout != null and b.refund != null) Runtime.trap("INV-DVP-3 fail @" # phase # ": legB paid AND refunded, trade " # Nat.toText(trade.id));
    // INV-DVP-1 (conservation) — outbound can never exceed what was escrowed. Safety, trap.
    if (a.payout != null and a.payoutAmount > a.escrowedAmount) Runtime.trap("INV-DVP-1 fail @" # phase # ": legA payout>escrow, trade " # Nat.toText(trade.id));
    if (b.payout != null and b.payoutAmount > b.escrowedAmount) Runtime.trap("INV-DVP-1 fail @" # phase # ": legB payout>escrow, trade " # Nat.toText(trade.id));
    if (a.refund != null and a.refundAmount > a.escrowedAmount) Runtime.trap("INV-DVP-1 fail @" # phase # ": legA refund>escrow, trade " # Nat.toText(trade.id));
    if (b.refund != null and b.refundAmount > b.escrowedAmount) Runtime.trap("INV-DVP-1 fail @" # phase # ": legB refund>escrow, trade " # Nat.toText(trade.id));
    // INV-DVP-2 (DvP gate) — a payout implies BOTH legs were escrowed. Safety, trap.
    if ((a.payout != null or b.payout != null) and not (a.escrowed and b.escrowed)) {
      Runtime.trap("INV-DVP-2 fail @" # phase # ": payout without both legs escrowed, trade " # Nat.toText(trade.id));
    };
    // INV-DVP-4 (no-stranding) — terminal status implies every escrowed leg is resolved. Diagnostic, log.
    switch (trade.status) {
      case (#Settled) {
        if (a.payout == null or b.payout == null) logInv("[ORACLE-FAIL] INV-DVP-4 @" # phase # ": Settled but a leg unpaid, trade " # Nat.toText(trade.id));
      };
      case (#Aborted) {
        let aOk = (not a.escrowed) or a.refund != null;
        let bOk = (not b.escrowed) or b.refund != null;
        if (not (aOk and bOk)) logInv("[ORACLE-FAIL] INV-DVP-4 @" # phase # ": Aborted but an escrowed leg unrefunded, trade " # Nat.toText(trade.id));
      };
      case (_) {};
    };
  };

  // ── Lifecycle internals ──────────────────────────────────────────────────────────────
  // After an escrow lands, promote to Funded when both legs are in and auto-attempt settle.
  func afterEscrow(trade : T.Trade) : async* Text {
    if (trade.legAState.escrowed and trade.legBState.escrowed) {
      switch (trade.status) {
        case (#Open) {
          trade.status := #Funded;
          appendEvent(trade.id, "FUNDED|id=" # Nat.toText(trade.id));
        };
        case (_) {};
      };
      let r = await* settleInner(trade);
      "both legs escrowed; " # r.note;
    } else { "leg escrowed; awaiting counterparty" };
  };

  func settleResultOf(trade : T.Trade, note : Text) : T.SettleResult {
    {
      tradeId = trade.id;
      status = trade.status;
      legAPaid = trade.legAState.payout != null;
      legBPaid = trade.legBState.payout != null;
      legAPayoutAmount = trade.legAState.payoutAmount;
      legBPayoutAmount = trade.legBState.payoutAmount;
      note;
    };
  };

  func reclaimResultOf(trade : T.Trade, note : Text) : T.ReclaimResult {
    {
      tradeId = trade.id;
      status = trade.status;
      legARefunded = trade.legAState.refund != null;
      legBRefunded = trade.legBState.refund != null;
      note;
    };
  };

  // Settle: pay legA -> taker, legB -> maker. DvP gate enforced first. Each payout
  // idempotent. Only when BOTH are paid does the trade become Settled (single SETTLED event).
  func settleInner(trade : T.Trade) : async* T.SettleResult {
    if (not (trade.legAState.escrowed and trade.legBState.escrowed)) {
      Runtime.trap("INV-DVP-2: settleInner without both legs escrowed, trade " # Nat.toText(trade.id));
    };
    let taker = switch (trade.taker) { case (?t) t; case null Runtime.trap("settle without bound taker, trade " # Nat.toText(trade.id)) };
    let aNote = switch (await* payoutLeg(trade, #A, taker)) { case (#ok(_)) "legA->taker paid"; case (#err(e)) "legA pending: " # e };
    let bNote = switch (await* payoutLeg(trade, #B, trade.maker)) { case (#ok(_)) "legB->maker paid"; case (#err(e)) "legB pending: " # e };
    if (trade.legAState.payout != null and trade.legBState.payout != null) {
      switch (trade.status) {
        case (#Settled) {};
        case (_) {
          trade.status := #Settled;
          appendEvent(trade.id, "SETTLED|id=" # Nat.toText(trade.id)
            # "|legA_to_taker=" # Nat.toText(trade.legAState.payoutAmount)
            # "|legB_to_maker=" # Nat.toText(trade.legBState.payoutAmount));
        };
      };
    };
    checkInvariants(trade, "settle");
    settleResultOf(trade, aNote # "; " # bNote);
  };

  func reclaimInner(trade : T.Trade) : async* T.ReclaimResult {
    let aNote = switch (await* refundLeg(trade, #A, trade.maker)) { case (#ok(_)) "legA refund ok"; case (#err(e)) "legA refund pending: " # e };
    let bNote = switch (trade.taker) {
      case (?taker) { switch (await* refundLeg(trade, #B, taker)) { case (#ok(_)) "legB refund ok"; case (#err(e)) "legB refund pending: " # e } };
      case null "legB never funded";
    };
    let aResolved = (not trade.legAState.escrowed) or trade.legAState.refund != null;
    let bResolved = (not trade.legBState.escrowed) or trade.legBState.refund != null;
    if (aResolved and bResolved) {
      switch (trade.status) {
        case (#Aborted) {};
        case (_) { trade.status := #Aborted; appendEvent(trade.id, "ABORTED|id=" # Nat.toText(trade.id)) };
      };
    };
    checkInvariants(trade, "reclaim");
    reclaimResultOf(trade, aNote # "; " # bNote);
  };

  // ── Public API ──────────────────────────────────────────────────────────────────────

  /// Maker opens a trade and (inline) escrows the asset leg. Maker must have approved this
  /// canister on the asset ledger for `assetAmount + fee`. The trade record is created
  /// BEFORE the escrow pull, so any funds that reach the core are always tracked (no
  /// stranding) and re-drivable via fundMaker even if this call's reply is lost.
  public shared ({ caller }) func openTrade(args : {
    taker : ?Principal;
    assetLedger : Principal;
    assetAmount : Nat;
    cashLedger : Principal;
    cashAmount : Nat;
    deadlineSecs : Nat;
  }) : async Result.Result<T.OpenResult, Text> {
    requireAuth(caller);
    if (args.assetAmount == 0 or args.cashAmount == 0) return #err("zero amount");
    if (args.deadlineSecs == 0) return #err("deadline must be > 0 seconds");
    switch (args.taker) { case (?t) { if (Principal.equal(t, caller)) return #err("maker and taker must differ") }; case null {} };
    if (Principal.equal(args.assetLedger, args.cashLedger)) return #err("asset and cash ledgers must differ");

    let feeA = try { await ledgerOf(args.assetLedger).icrc1_fee() } catch (_e) { return #err("asset ledger unreachable") };
    let feeB = try { await ledgerOf(args.cashLedger).icrc1_fee() } catch (_e) { return #err("cash ledger unreachable") };
    if (args.assetAmount <= feeA) return #err("asset amount must exceed the asset ledger fee");
    if (args.cashAmount <= feeB) return #err("cash amount must exceed the cash ledger fee");

    let id = nextTradeId;
    nextTradeId += 1;
    let deadline = now64() + Nat64.fromNat(args.deadlineSecs) * 1_000_000_000;
    let trade : T.Trade = {
      id;
      maker = caller;
      var taker = args.taker;
      legA = { ledger = args.assetLedger; kind = #icrc1({ amount = args.assetAmount }) };
      legB = { ledger = args.cashLedger; kind = #icrc1({ amount = args.cashAmount }) };
      legAState = T.newLegState();
      legBState = T.newLegState();
      deadline;
      var status = #Open;
      createdAt = now64();
    };
    Map.add(trades, Nat.compare, id, trade);
    appendEvent(id, "ORDER|id=" # Nat.toText(id) # "|maker=" # Principal.toText(caller)
      # "|legA=" # Principal.toText(args.assetLedger) # ":" # Nat.toText(args.assetAmount)
      # "|legB=" # Principal.toText(args.cashLedger) # ":" # Nat.toText(args.cashAmount)
      # "|deadline=" # Nat64.toText(deadline));

    let note = switch (await* escrowLeg(trade, #A, caller)) {
      case (#ok(idx)) "asset leg escrowed at ledger block " # Nat.toText(idx);
      case (#err(e)) "asset escrow not yet in — " # e # " (approve the core, then call fundMaker)";
    };
    checkInvariants(trade, "openTrade");
    #ok({ tradeId = id; status = trade.status; makerEscrowed = trade.legAState.escrowed; note });
  };

  /// Open a land⇄CBDC trade: legA is a non-fungible land title (`#icrc7 { tokenId }`,
  /// maker → taker), legB is fungible CBDC cash (`#icrc1 { amount }`, taker → maker). This
  /// is the additive constructor for a mixed-kind trade: `openTrade`'s Candid args carry
  /// only fungible amounts and cannot express a `tokenId`, so a separate entrypoint is
  /// required to build the `#icrc7` leg WITHOUT editing the frozen lifecycle. It feeds the
  /// Trade into the SAME unchanged state machine (escrow/fund/settle/reclaim/checkInvariants/
  /// MMR) — which is what proves the leg-agnostic guarantee in practice. The maker must `icrc37_approve`
  /// this core for `tokenId`; the inline escrow pulls the title into the core's account.
  public shared ({ caller }) func openLandTrade(args : {
    taker : ?Principal;
    landLedger : Principal;
    tokenId : Nat;
    cashLedger : Principal;
    cashAmount : Nat;
    deadlineSecs : Nat;
  }) : async Result.Result<T.OpenResult, Text> {
    requireAuth(caller);
    if (args.cashAmount == 0) return #err("zero cash amount");
    if (args.deadlineSecs == 0) return #err("deadline must be > 0 seconds");
    switch (args.taker) { case (?t) { if (Principal.equal(t, caller)) return #err("maker and taker must differ") }; case null {} };
    if (Principal.equal(args.landLedger, args.cashLedger)) return #err("land and cash ledgers must differ");

    let feeB = try { await ledgerOf(args.cashLedger).icrc1_fee() } catch (_e) { return #err("cash ledger unreachable") };
    if (args.cashAmount <= feeB) return #err("cash amount must exceed the cash ledger fee");

    let id = nextTradeId;
    nextTradeId += 1;
    let deadline = now64() + Nat64.fromNat(args.deadlineSecs) * 1_000_000_000;
    let trade : T.Trade = {
      id;
      maker = caller;
      var taker = args.taker;
      legA = { ledger = args.landLedger; kind = #icrc7({ tokenId = args.tokenId }) };
      legB = { ledger = args.cashLedger; kind = #icrc1({ amount = args.cashAmount }) };
      legAState = T.newLegState();
      legBState = T.newLegState();
      deadline;
      var status = #Open;
      createdAt = now64();
    };
    Map.add(trades, Nat.compare, id, trade);
    appendEvent(id, "ORDER|id=" # Nat.toText(id) # "|maker=" # Principal.toText(caller)
      # "|legA=" # Principal.toText(args.landLedger) # ":#icrc7:" # Nat.toText(args.tokenId)
      # "|legB=" # Principal.toText(args.cashLedger) # ":" # Nat.toText(args.cashAmount)
      # "|deadline=" # Nat64.toText(deadline));

    let note = switch (await* escrowLeg(trade, #A, caller)) {
      case (#ok(idx)) "land title escrowed at ledger block " # Nat.toText(idx);
      case (#err(e)) "land escrow not yet in — " # e # " (icrc37_approve the core, then call fundMaker)";
    };
    checkInvariants(trade, "openLandTrade");
    #ok({ tradeId = id; status = trade.status; makerEscrowed = trade.legAState.escrowed; note });
  };

  /// Re-drive the maker's asset-leg escrow (idempotent). For when openTrade's inline pull
  /// did not land (e.g. insufficient allowance at open) or its reply was lost.
  public shared ({ caller }) func fundMaker(tradeId : Nat) : async Result.Result<T.FundResult, Text> {
    requireAuth(caller);
    let trade = switch (Map.get(trades, Nat.compare, tradeId)) { case (?t) t; case null return #err("no such trade") };
    if (not Principal.equal(caller, trade.maker)) return #err("only the maker funds the asset leg");
    switch (trade.status) { case (#Open) {}; case (_) return #err("trade is not Open") };
    if (now64() > trade.deadline) return #err("past funding deadline");
    if (not acquire(tradeId, "fund")) return #err("operation already in progress for this trade");
    let res = await* fundMakerInner(trade);
    release(tradeId, "fund");
    res;
  };

  func fundMakerInner(trade : T.Trade) : async* Result.Result<T.FundResult, Text> {
    switch (await* escrowLeg(trade, #A, trade.maker)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        let settleNote = await* afterEscrow(trade);
        #ok({
          tradeId = trade.id;
          status = trade.status;
          legEscrowed = trade.legAState.escrowed;
          bothEscrowed = trade.legAState.escrowed and trade.legBState.escrowed;
          settleNote;
        });
      };
    };
  };

  /// Taker escrows the cash leg. Binds the caller as taker on first success (open RFQ) or
  /// requires the pre-named taker. Auto-attempts settlement once both legs are in.
  public shared ({ caller }) func fundTaker(tradeId : Nat) : async Result.Result<T.FundResult, Text> {
    requireAuth(caller);
    let trade = switch (Map.get(trades, Nat.compare, tradeId)) { case (?t) t; case null return #err("no such trade") };
    if (Principal.equal(caller, trade.maker)) return #err("the maker cannot also be the taker");
    switch (trade.taker) { case (?t) { if (not Principal.equal(t, caller)) return #err("trade is reserved for another taker") }; case null {} };
    switch (trade.status) { case (#Open) {}; case (_) return #err("trade is not Open") };
    if (now64() > trade.deadline) return #err("past funding deadline");
    if (not acquire(tradeId, "fund")) return #err("operation already in progress for this trade");
    let res = await* fundTakerInner(trade, caller);
    release(tradeId, "fund");
    res;
  };

  func fundTakerInner(trade : T.Trade, caller : Principal) : async* Result.Result<T.FundResult, Text> {
    switch (await* escrowLeg(trade, #B, caller)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        // Bind taker only on a successful escrow (prevents a never-funding taker from locking the trade).
        switch (trade.taker) { case (null) { trade.taker := ?caller }; case (?_) {} };
        let settleNote = await* afterEscrow(trade);
        #ok({
          tradeId = trade.id;
          status = trade.status;
          legEscrowed = trade.legBState.escrowed;
          bothEscrowed = trade.legAState.escrowed and trade.legBState.escrowed;
          settleNote;
        });
      };
    };
  };

  /// Settle a fully-escrowed trade. Permissionless among authenticated principals (payouts
  /// go only to the predetermined taker/maker). Idempotent and re-drivable: resends only the
  /// unsent leg, never double-pays.
  public shared ({ caller }) func settle(tradeId : Nat) : async Result.Result<T.SettleResult, Text> {
    requireAuth(caller);
    let trade = switch (Map.get(trades, Nat.compare, tradeId)) { case (?t) t; case null return #err("no such trade") };
    switch (trade.status) {
      case (#Settled) return #ok(settleResultOf(trade, "already settled"));
      case (#Aborted) return #err("trade is aborted — cannot settle (INV-DVP-3)");
      case (#Open) return #err("trade is not fully escrowed — DvP gate closed (INV-DVP-2)");
      case (#Funded) {};
    };
    if (not acquire(tradeId, "settle")) return #err("operation already in progress for this trade");
    let res = await* settleInner(trade);
    release(tradeId, "settle");
    #ok(res);
  };

  /// Reclaim escrow after the deadline for a trade that never reached both-escrowed.
  /// Callable by the maker or the bound taker. Refunds go only to the legs' owners.
  public shared ({ caller }) func reclaim(tradeId : Nat) : async Result.Result<T.ReclaimResult, Text> {
    requireAuth(caller);
    let trade = switch (Map.get(trades, Nat.compare, tradeId)) { case (?t) t; case null return #err("no such trade") };
    let isParty = Principal.equal(caller, trade.maker) or (switch (trade.taker) { case (?t) Principal.equal(t, caller); case null false });
    if (not isParty) return #err("only the maker or bound taker may reclaim");
    switch (trade.status) {
      case (#Aborted) return #ok(reclaimResultOf(trade, "already aborted"));
      case (#Settled) return #err("trade is settled — cannot reclaim (INV-DVP-3)");
      case (#Funded) return #err("both legs escrowed — this trade settles, it cannot be reclaimed");
      case (#Open) {};
    };
    if (now64() <= trade.deadline) return #err("funding deadline not yet reached");
    if (not acquire(tradeId, "reclaim")) return #err("operation already in progress for this trade");
    let res = await* reclaimInner(trade);
    release(tradeId, "reclaim");
    #ok(res);
  };

  // ══ Authorized-relayer autonomous matched settlement ══════════════════════════════════════════
  //
  // `settleMatchFor` lets the controller-set matching engine settle a cleared (seller S, buyer B,
  // price p*, qty q) match with NO trader action at settle: it builds a Trade with maker = S and
  // taker = B, escrows leg A (the asset, S→core) and leg B (the cash, B→core) — both traders have
  // pre-`approve`d the core (the engine verified the allowances at order intake) — then runs the
  // SAME unchanged escrow → afterEscrow → settleInner → checkInvariants → MMR pipeline. The core
  // pays leg A → taker = B (B gets the asset) and leg B → maker = S (S gets the cash): exactly the
  // match, both-or-neither, with every INV-DVP guarantee verbatim.
  //
  // Same shape as `openLandTrade`: a new entrypoint plus new state, with no edits
  // to any lifecycle function. The only behavioural difference from
  // openTrade is WHO escrows: here the relayer drives BOTH legs' escrow-pulls from their owners,
  // instead of maker-then-taker self-funding. The both-or-neither property is unchanged because it
  // lives in settleInner's DvP gate (a payout fires only when both legs are escrowed), not in who
  // initiated the escrow.
  //
  // Idempotent + lost-reply-safe via `matchSeq`: a repeat call for a known seq re-drives the SAME
  // trade (re-escrows any unsent leg from the recorded owners, re-attempts settle) and NEVER creates
  // a second trade — so the matching engine can retry on a lost reply without double-settling.

  /// Controller-only: bind (or rotate) the authorized matching-engine relayer. Gated to the core
  /// installer (the deployer/controller). Does not touch any lifecycle function.
  public shared ({ caller }) func setMatchingEngine(p : Principal) : async Result.Result<Text, Text> {
    requireAuth(caller);
    if (not Principal.equal(caller, installer)) return #err("only the core installer may set the matching engine");
    matchingEngine := ?p;
    List.add(adminLog, "SET_MATCHING_ENGINE|engine=" # Principal.toText(p) # "|at=" # Nat64.toText(now64()));
    #ok("matching engine set to " # Principal.toText(p))
  };

  public shared ({ caller }) func settleMatchFor(args : {
    matchSeq : Nat;          // matching-engine obligation seq — idempotency / lost-reply key
    maker : Principal;       // seller S — delivers the asset leg
    taker : Principal;       // buyer B — delivers the cash leg
    assetLedger : Principal;
    assetAmount : Nat;
    cashLedger : Principal;
    cashAmount : Nat;
    deadlineSecs : Nat;
  }) : async Result.Result<T.SettleResult, Text> {
    requireAuth(caller);
    // authorized-relayer gate
    switch (matchingEngine) {
      case (?m) { if (not Principal.equal(caller, m)) return #err("only the authorized matching engine may call settleMatchFor") };
      case null { return #err("matching engine not set — controller must call setMatchingEngine first") };
    };

    let mkey = matchKey(caller, args.matchSeq);
    // Fast path: a known match re-drives its existing trade (idempotent retry).
    switch (Map.get(matchSettlements, Text.compare, mkey)) {
      case (?existingId) {
        let trade = switch (Map.get(trades, Nat.compare, existingId)) { case (?t) t; case null return #err("internal: matchSeq maps to a missing trade") };
        if (not acquire(existingId, "settleMatchFor")) return #err("operation already in progress for this trade");
        let r = await* settleMatchForInner(trade);
        release(existingId, "settleMatchFor");
        return #ok(r);
      };
      case null {};
    };

    // Validation (same shape + fee semantics as openTrade).
    if (args.assetAmount == 0 or args.cashAmount == 0) return #err("zero amount");
    if (args.deadlineSecs == 0) return #err("deadline must be > 0 seconds");
    if (Principal.equal(args.maker, args.taker)) return #err("maker and taker must differ");
    if (Principal.equal(args.assetLedger, args.cashLedger)) return #err("asset and cash ledgers must differ");
    let feeA = try { await ledgerOf(args.assetLedger).icrc1_fee() } catch (_e) { return #err("asset ledger unreachable") };
    let feeB = try { await ledgerOf(args.cashLedger).icrc1_fee() } catch (_e) { return #err("cash ledger unreachable") };
    if (args.assetAmount <= feeA) return #err("asset amount must exceed the asset ledger fee");
    if (args.cashAmount <= feeB) return #err("cash amount must exceed the cash ledger fee");

    // Atomic create section (NO await between the re-check and the inserts) — closes the
    // concurrent-duplicate race: if another call created this seq during the fee-read awaits above,
    // re-drive that trade instead of creating a second.
    let trade = switch (Map.get(matchSettlements, Text.compare, mkey)) {
      case (?existingId) { switch (Map.get(trades, Nat.compare, existingId)) { case (?t) t; case null return #err("internal: matchSeq maps to a missing trade") } };
      case null {
        let id = nextTradeId;
        nextTradeId += 1;
        let deadline = now64() + Nat64.fromNat(args.deadlineSecs) * 1_000_000_000;
        let t : T.Trade = {
          id;
          maker = args.maker;            // seller S
          var taker = ?args.taker;       // buyer B — bound up-front (the relayer pairs both approvals)
          legA = { ledger = args.assetLedger; kind = #icrc1({ amount = args.assetAmount }) };  // asset S→B
          legB = { ledger = args.cashLedger; kind = #icrc1({ amount = args.cashAmount }) };    // cash  B→S
          legAState = T.newLegState();
          legBState = T.newLegState();
          deadline;
          var status = #Open;
          createdAt = now64();
        };
        Map.add(trades, Nat.compare, id, t);
        Map.add(matchSettlements, Text.compare, mkey, id);
        appendEvent(id, "ORDER|id=" # Nat.toText(id) # "|maker=" # Principal.toText(args.maker)
          # "|legA=" # Principal.toText(args.assetLedger) # ":" # Nat.toText(args.assetAmount)
          # "|legB=" # Principal.toText(args.cashLedger) # ":" # Nat.toText(args.cashAmount)
          # "|deadline=" # Nat64.toText(deadline) # "|matchSeq=" # Nat.toText(args.matchSeq));
        t
      };
    };

    if (not acquire(trade.id, "settleMatchFor")) return #err("operation already in progress for this trade");
    let r = await* settleMatchForInner(trade);
    release(trade.id, "settleMatchFor");
    #ok(r)
  };

  // Drive a relayer-created trade: escrow leg A from maker = S and leg B from taker = B (both
  // pre-`approve`d the core), then run the SAME unchanged afterEscrow → settleInner. Both-or-neither
  // is preserved by settleInner's DvP gate: if a leg cannot escrow, the other stays escrowed and
  // reclaimable and NEITHER party is paid. Fully idempotent (escrowLeg/payoutLeg reuse stored cats,
  // so a re-drive resends only the unsent leg and never double-moves funds).
  func settleMatchForInner(trade : T.Trade) : async* T.SettleResult {
    let taker = switch (trade.taker) { case (?t) t; case null Runtime.trap("settleMatchFor trade without taker, id " # Nat.toText(trade.id)) };
    let aRes = await* escrowLeg(trade, #A, trade.maker);
    let bRes = await* escrowLeg(trade, #B, taker);
    let note = switch (aRes, bRes) {
      case (#ok(_), #ok(_)) { "both legs escrowed; " # (await* afterEscrow(trade)) };
      case (#err(ea), #ok(_)) "legB (cash) escrowed; legA (asset) escrow failed: " # ea # " (no payout — reclaimable / re-drivable)";
      case (#ok(_), #err(eb)) "legA (asset) escrowed; legB (cash) escrow failed: " # eb # " (no payout — reclaimable / re-drivable)";
      case (#err(ea), #err(eb)) "no leg escrowed (A: " # ea # "; B: " # eb # ")";
    };
    checkInvariants(trade, "settleMatchFor");
    settleResultOf(trade, note)
  };

  // ── Queries ────────────────────────────────────────────────────────────────────────
  public query func matchingEnginePrincipal() : async ?Principal { matchingEngine };
  public query func tradeIdForMatch(engine : Principal, matchSeq : Nat) : async ?Nat { Map.get(matchSettlements, Text.compare, matchKey(engine, matchSeq)) };
  public query func adminEvents() : async [Text] { List.toArray(adminLog) };

  public query func getTrade(id : Nat) : async ?T.TradeView {
    switch (Map.get(trades, Nat.compare, id)) { case (?t) ?T.tradeView(t); case null null };
  };

  public query func tradeCount() : async Nat { if (nextTradeId == 0) 0 else nextTradeId - 1 };

  public query func corePrincipal() : async Principal { selfPrincipal };
  public query func coreAccount() : async T.Account { { owner = selfPrincipal; subaccount = null } };

  public query func auditRoot() : async ?Blob { MMR.rootHash(mmr) };
  public query func auditRootHex() : async ?Text { switch (MMR.rootHash(mmr)) { case (?r) ?hex(r); case null null } };

  public query func auditEvents(tradeId : Nat) : async [T.AuditEvent] {
    List.toArray(List.filter<T.AuditEvent>(auditLog, func(e) { e.tradeId == tradeId }));
  };
  public query func allEvents() : async [T.AuditEvent] { List.toArray(auditLog) };
  public query func auditLength() : async Nat { auditSeq };

  public query func invariantLog() : async [Text] { List.toArray(invLog) };
};
