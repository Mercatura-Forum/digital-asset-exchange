/// LandRegistry.mo — the pure, stable-state core of the ICRC-7/37 land-title ledger.
///
/// A parcel of land = one `token_id` + immutable metadata. This module holds ALL the
/// registry logic (ownership, transfer, approvals, dedup) operating on an externalized
/// `State` record, so two actors share ONE source of truth: `LandLedger` (the clean
/// production ledger) and `FlakyLandLedger` (the same logic + a controller-gated
/// clean-transient injector used ONLY as a throwaway test fixture for the DvP core's
/// idempotent-retry acceptance test — mission L3). Keeping the registry in one tested
/// module is the production-grade alternative to copy-pasting the ledger (cf. how the
/// fungible side copied IndexedLedger → FlakyLedger).
///
/// Conformance: ICRC-7 (icrc7_transfer/owner_of/tokens/balance_of) + ICRC-37
/// (icrc37_transfer_from/approve_tokens/approve_collection), batch `vec`/`vec opt Result`
/// shapes exact. created_at_time dedup window mirrors IndexedLedger.checkDedupAndTime, with
/// the fresh-genesis Nat64-underflow GUARD baked in (the P1 finding: `now − 24h` underflows
/// when Time.now() is small on a freshly-genesis'd egypt chain).

import Principal "mo:core/Principal";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Map "mo:core/Map";
import List "mo:core/List";

import I "../ICRC7";

module {

  public type Account = I.Account;
  public type Value = I.Value;

  // A single approval grant (token-level or collection-level).
  public type Approval = { spender : Account; expires_at : ?Nat64 };

  // A minimal transaction record for the audit log / block index.
  public type TxRecord = {
    index : Nat;
    kind : Text; // "mint" | "xfer" | "xfer_from" | "approve_token" | "approve_collection"
    token_id : ?Nat;
    from : ?Account;
    to : ?Account;
    spender : ?Account;
    timestamp : Nat64;
  };

  public type State = {
    var nextTxId : Nat;
    var totalTokens : Nat;
    owners : Map.Map<Nat, Account>; // token_id -> current owner
    metadata : Map.Map<Nat, [(Text, Value)]>; // token_id -> immutable attributes
    tokenApprovals : Map.Map<Nat, List.List<Approval>>; // token_id -> approvals
    collectionApprovals : Map.Map<Text, List.List<Approval>>; // owner-key -> approvals
    recentTxs : Map.Map<Nat64, Nat>; // created_at_time -> tx index (dedup)
    var dedupPruneCounter : Nat;
    txLog : List.List<TxRecord>;
  };

  public func newState() : State {
    {
      var nextTxId = 0;
      var totalTokens = 0;
      owners = Map.empty<Nat, Account>();
      metadata = Map.empty<Nat, [(Text, Value)]>();
      tokenApprovals = Map.empty<Nat, List.List<Approval>>();
      collectionApprovals = Map.empty<Text, List.List<Approval>>();
      recentTxs = Map.empty<Nat64, Nat>();
      var dedupPruneCounter = 0;
      txLog = List.empty<TxRecord>();
    };
  };

  let TX_WINDOW_NS : Nat64 = 86_400_000_000_000; // 24h
  let PERMITTED_DRIFT_NS : Nat64 = 60_000_000_000; // 60s
  let PRUNE_MARGIN_NS : Nat64 = 60_000_000_000; // 60s
  let MAX_MEMO : Nat = 32;
  let MAX_TAKE : Nat = 10_000;

  // ── account helpers ────────────────────────────────────────────────────────────────
  public func accountsEqual(a : Account, b : Account) : Bool {
    Principal.equal(a.owner, b.owner) and subEqual(a.subaccount, b.subaccount);
  };

  func subEqual(a : ?Blob, b : ?Blob) : Bool {
    switch (a, b) {
      case (null, null) true;
      case (?x, ?y) x == y;
      case (_, _) false;
    };
  };

  let HEX = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
  func subHex(s : ?Blob) : Text {
    switch (s) {
      case null "";
      case (?b) {
        var out = "";
        for (byte in b.vals()) {
          let n = Nat8.toNat(byte);
          out := out # HEX[n / 16] # HEX[n % 16];
        };
        out;
      };
    };
  };

  func acctKey(a : Account) : Text { Principal.toText(a.owner) # "|" # subHex(a.subaccount) };

  func valid(approval : Approval, now : Nat64) : Bool {
    switch (approval.expires_at) { case null true; case (?e) e > now };
  };

  // ── dedup (mirrors IndexedLedger, with the fresh-genesis underflow GUARD) ─────────────
  func pruneDedup(state : State, now : Nat64) {
    state.dedupPruneCounter += 1;
    if (state.dedupPruneCounter % 10 != 0) return;
    // GUARD: until the chain clock exceeds the full window, `now − window` would underflow
    // Nat64 (trap "arithmetic overflow"). On a freshly-genesis'd egypt chain Time.now() is
    // small (~1e13 ns) — skip pruning entirely until it is safe. This is the P1 finding's fix.
    let threshold = TX_WINDOW_NS + PERMITTED_DRIFT_NS + PRUNE_MARGIN_NS;
    if (now <= threshold) return;
    let cutoff = now - threshold;
    let toDelete = List.empty<Nat64>();
    var count : Nat = 0;
    label scan for ((ts, _) in Map.entries(state.recentTxs)) {
      if (count >= 20) break scan;
      if (ts < cutoff) { List.add(toDelete, ts); count += 1 };
    };
    for (ts in List.values(toDelete)) { ignore Map.delete(state.recentTxs, Nat64.compare, ts) };
  };

  public type DedupVerdict = { #fresh; #tooOld; #inFuture : Nat64; #dup : Nat };

  func dedupLookup(state : State, cat : ?Nat64, now : Nat64) : DedupVerdict {
    pruneDedup(state, now);
    switch (cat) {
      case null #fresh;
      case (?ts) {
        if (ts + TX_WINDOW_NS + PERMITTED_DRIFT_NS < now) return #tooOld;
        if (ts > now + PERMITTED_DRIFT_NS) return #inFuture(now);
        switch (Map.get(state.recentTxs, Nat64.compare, ts)) {
          case (?idx) #dup(idx);
          case null #fresh;
        };
      };
    };
  };

  func recordDedup(state : State, cat : ?Nat64, idx : Nat) {
    switch (cat) { case (?ts) Map.add(state.recentTxs, Nat64.compare, ts, idx); case null {} };
  };

  func memoOk(memo : ?Blob) : Bool {
    switch (memo) { case null true; case (?m) m.size() <= MAX_MEMO };
  };

  // ── queries ──────────────────────────────────────────────────────────────────────────
  public func ownerOf(state : State, tokenId : Nat) : ?Account {
    Map.get(state.owners, Nat.compare, tokenId);
  };

  public func metadataOf(state : State, tokenId : Nat) : ?[(Text, Value)] {
    Map.get(state.metadata, Nat.compare, tokenId);
  };

  public func balanceOf(state : State, account : Account) : Nat {
    var n = 0;
    for ((_, owner) in Map.entries(state.owners)) { if (accountsEqual(owner, account)) n += 1 };
    n;
  };

  public func totalSupply(state : State) : Nat { state.totalTokens };

  func paginate(it : Map.Map<Nat, Account>, prev : ?Nat, take : ?Nat, filter : ?Account) : [Nat] {
    let cap = switch (take) { case (?t) Nat.min(t, MAX_TAKE); case null MAX_TAKE };
    let out = List.empty<Nat>();
    var n = 0;
    label scan for ((tid, owner) in Map.entries(it)) {
      if (n >= cap) break scan;
      let afterPrev = switch (prev) { case null true; case (?p) tid > p };
      if (not afterPrev) continue scan;
      let pass = switch (filter) { case null true; case (?a) accountsEqual(owner, a) };
      if (pass) { List.add(out, tid); n += 1 };
    };
    List.toArray(out);
  };

  public func tokens(state : State, prev : ?Nat, take : ?Nat) : [Nat] {
    paginate(state.owners, prev, take, null);
  };

  public func tokensOf(state : State, account : Account, prev : ?Nat, take : ?Nat) : [Nat] {
    paginate(state.owners, prev, take, ?account);
  };

  // ── approval predicates ────────────────────────────────────────────────────────────────
  func anyMatch(list : ?List.List<Approval>, spender : Account, now : Nat64) : Bool {
    switch (list) {
      case null false;
      case (?l) {
        for (a in List.values(l)) {
          if (accountsEqual(a.spender, spender) and valid(a, now)) return true;
        };
        false;
      };
    };
  };

  public func isApprovedSpender(state : State, owner : Account, spender : Account, tokenId : Nat, now : Nat64) : Bool {
    if (anyMatch(Map.get(state.tokenApprovals, Nat.compare, tokenId), spender, now)) return true;
    anyMatch(Map.get(state.collectionApprovals, Text.compare, acctKey(owner)), spender, now);
  };

  // Replace any existing grant to the same spender, then add the new one.
  func upsertApproval(existing : ?List.List<Approval>, approval : Approval) : List.List<Approval> {
    let fresh = List.empty<Approval>();
    switch (existing) {
      case (?l) { for (a in List.values(l)) { if (not accountsEqual(a.spender, approval.spender)) List.add(fresh, a) } };
      case null {};
    };
    List.add(fresh, approval);
    fresh;
  };

  func clearTokenApprovals(state : State, tokenId : Nat) {
    ignore Map.delete(state.tokenApprovals, Nat.compare, tokenId);
  };

  func appendTx(state : State, kind : Text, tokenId : ?Nat, from : ?Account, to : ?Account, spender : ?Account, now : Nat64) : Nat {
    let idx = state.nextTxId;
    List.add(state.txLog, { index = idx; kind; token_id = tokenId; from; to; spender; timestamp = now });
    state.nextTxId += 1;
    idx;
  };

  // ── mint (controller-gated at the actor; pure here) ────────────────────────────────────
  public func mint(state : State, to : Account, tokenId : Nat, meta : [(Text, Value)], now : Nat64) : { #ok : Nat; #err : Text } {
    switch (Map.get(state.owners, Nat.compare, tokenId)) {
      case (?_) #err("token_id already exists");
      case null {
        Map.add(state.owners, Nat.compare, tokenId, to);
        Map.add(state.metadata, Nat.compare, tokenId, meta);
        state.totalTokens += 1;
        #ok(appendTx(state, "mint", ?tokenId, null, ?to, null, now));
      };
    };
  };

  // ── ICRC-7 transfer (caller is the current owner) ──────────────────────────────────────
  public func transfer(state : State, caller : Principal, arg : I.TransferArg, now : Nat64) : I.TransferResult {
    let from : Account = { owner = caller; subaccount = arg.from_subaccount };
    if (not memoOk(arg.memo)) return #Err(#GenericError({ error_code = 1; message = "memo too long" }));
    if (Principal.isAnonymous(arg.to.owner)) return #Err(#InvalidRecipient);
    let cur = switch (Map.get(state.owners, Nat.compare, arg.token_id)) { case (?o) o; case null return #Err(#NonExistingTokenId) };
    // Dedup BEFORE the ownership check: a committed transfer changes the owner, so a
    // lost-reply replay (same created_at_time) must resolve to #Duplicate, NOT Unauthorized —
    // otherwise the DvP core would retry forever and never settle. Mirrors IndexedLedger,
    // where dedup precedes the balance transfer. A never-committed op records no dedup, so a
    // genuinely-unauthorized fresh call still fails deterministically below.
    switch (dedupLookup(state, arg.created_at_time, now)) {
      case (#tooOld) return #Err(#TooOld);
      case (#inFuture(t)) return #Err(#CreatedInFuture({ ledger_time = t }));
      case (#dup(idx)) return #Err(#Duplicate({ duplicate_of = idx }));
      case (#fresh) {};
    };
    if (not accountsEqual(cur, from)) return #Err(#Unauthorized);
    Map.add(state.owners, Nat.compare, arg.token_id, arg.to);
    clearTokenApprovals(state, arg.token_id);
    let idx = appendTx(state, "xfer", ?arg.token_id, ?from, ?arg.to, null, now);
    recordDedup(state, arg.created_at_time, idx);
    #Ok(idx);
  };

  // ── ICRC-37 transfer_from (caller is an approved spender) ───────────────────────────────
  public func transferFrom(state : State, caller : Principal, arg : I.TransferFromArg, now : Nat64) : I.TransferFromResult {
    let spender : Account = { owner = caller; subaccount = arg.spender_subaccount };
    if (not memoOk(arg.memo)) return #Err(#GenericError({ error_code = 1; message = "memo too long" }));
    if (Principal.isAnonymous(arg.to.owner)) return #Err(#InvalidRecipient);
    let cur = switch (Map.get(state.owners, Nat.compare, arg.token_id)) { case (?o) o; case null return #Err(#NonExistingTokenId) };
    // Dedup BEFORE ownership/approval checks (see the note in `transfer`): a lost-reply replay
    // of a committed escrow must resolve to #Duplicate even though the owner is now the core
    // and the token-level approval was cleared by that very transfer.
    switch (dedupLookup(state, arg.created_at_time, now)) {
      case (#tooOld) return #Err(#TooOld);
      case (#inFuture(t)) return #Err(#CreatedInFuture({ ledger_time = t }));
      case (#dup(idx)) return #Err(#Duplicate({ duplicate_of = idx }));
      case (#fresh) {};
    };
    if (not accountsEqual(cur, arg.from)) return #Err(#Unauthorized);
    if (not isApprovedSpender(state, cur, spender, arg.token_id, now)) return #Err(#Unauthorized);
    Map.add(state.owners, Nat.compare, arg.token_id, arg.to);
    clearTokenApprovals(state, arg.token_id); // ICRC-37: a transfer clears token-level approvals
    let idx = appendTx(state, "xfer_from", ?arg.token_id, ?arg.from, ?arg.to, ?spender, now);
    recordDedup(state, arg.created_at_time, idx);
    #Ok(idx);
  };

  // ── ICRC-37 approve_tokens ──────────────────────────────────────────────────────────────
  public func approveToken(state : State, caller : Principal, arg : I.ApproveTokenArg, now : Nat64) : I.ApproveTokenResult {
    let info = arg.approval_info;
    let owner : Account = { owner = caller; subaccount = info.from_subaccount };
    if (not memoOk(info.memo)) return #Err(#GenericError({ error_code = 1; message = "memo too long" }));
    if (Principal.isAnonymous(info.spender.owner)) return #Err(#InvalidSpender);
    if (accountsEqual(info.spender, owner)) return #Err(#InvalidSpender);
    let cur = switch (Map.get(state.owners, Nat.compare, arg.token_id)) { case (?o) o; case null return #Err(#NonExistingTokenId) };
    if (not accountsEqual(cur, owner)) return #Err(#Unauthorized);
    switch (info.created_at_time) {
      case (?ts) {
        if (ts + TX_WINDOW_NS + PERMITTED_DRIFT_NS < now) return #Err(#TooOld);
        if (ts > now + PERMITTED_DRIFT_NS) return #Err(#CreatedInFuture({ ledger_time = now }));
      };
      case null {};
    };
    let updated = upsertApproval(Map.get(state.tokenApprovals, Nat.compare, arg.token_id), { spender = info.spender; expires_at = info.expires_at });
    Map.add(state.tokenApprovals, Nat.compare, arg.token_id, updated);
    #Ok(appendTx(state, "approve_token", ?arg.token_id, ?owner, null, ?info.spender, now));
  };

  // ── ICRC-37 approve_collection ──────────────────────────────────────────────────────────
  public func approveCollection(state : State, caller : Principal, arg : I.ApproveCollectionArg, now : Nat64) : I.ApproveCollectionResult {
    let info = arg.approval_info;
    let owner : Account = { owner = caller; subaccount = info.from_subaccount };
    if (not memoOk(info.memo)) return #Err(#GenericError({ error_code = 1; message = "memo too long" }));
    if (Principal.isAnonymous(info.spender.owner)) return #Err(#InvalidSpender);
    if (accountsEqual(info.spender, owner)) return #Err(#InvalidSpender);
    switch (info.created_at_time) {
      case (?ts) {
        if (ts + TX_WINDOW_NS + PERMITTED_DRIFT_NS < now) return #Err(#TooOld);
        if (ts > now + PERMITTED_DRIFT_NS) return #Err(#CreatedInFuture({ ledger_time = now }));
      };
      case null {};
    };
    let key = acctKey(owner);
    let updated = upsertApproval(Map.get(state.collectionApprovals, Text.compare, key), { spender = info.spender; expires_at = info.expires_at });
    Map.add(state.collectionApprovals, Text.compare, key, updated);
    #Ok(appendTx(state, "approve_collection", null, ?owner, null, ?info.spender, now));
  };
};
