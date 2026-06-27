/// BlockLog.mo — Append-only block log with SHA256 hash chain + account index
///
/// Uses StableLog (Region-backed) for the transaction log — scales to gigabytes.
/// Account index uses Map (heap) — bounded by number of accounts.
/// SHA256 hash chain: each block's hash = SHA256(parent_hash || timestamp || kind || amount || accounts).
///
/// Phase 2 complete: Region storage + real hash chain.

import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Principal "mo:core/Principal";

import Sha256 "mo:sha2/Sha256";

import T "Types";
import SLog "StableLog";
import CBOR "CBOR";
import MMR "MerkleMMR";

module {

  /// Block with hash chain linkage
  public type Block = {
    index : Nat;
    parentHash : ?Blob;
    hash : Blob;
    timestamp : Nat64;
    transaction : T.Transaction;
    effectiveFee : ?Nat;
  };

  /// Internal decoded block with parentHash from CBOR
  type DecodedBlock = {
    tx : T.Transaction;
    parentHash : ?Blob;
  };

  // ═══════════════════════════════════════════════════════
  //  BINARY ENCODING HELPERS (zero-allocation hash preimage)
  // ═══════════════════════════════════════════════════════

  /// Encode Nat as big-endian variable-length bytes (no text conversion)
  func natToBytes(digest : Sha256.Digest, n : Nat) {
    if (n == 0) { digest.writeArray([0]); return };
    // Count bytes needed
    var tmp = n;
    var byteCount : Nat = 0;
    while (tmp > 0) { tmp /= 256; byteCount += 1 };
    // Write big-endian
    let bytes = Array.tabulate<Nat8>(byteCount, func(i) {
      let shift = byteCount - 1 - i;
      Nat8.fromNat((n / (256 ** shift)) % 256)
    });
    digest.writeArray(bytes);
  };

  /// Encode Nat64 as fixed 8-byte big-endian (optimal for timestamps)
  func nat64ToBytes(digest : Sha256.Digest, n : Nat64) {
    let v = Nat64.toNat(n);
    digest.writeArray([
      Nat8.fromNat((v / 72057594037927936) % 256), // byte 7
      Nat8.fromNat((v / 281474976710656) % 256),   // byte 6
      Nat8.fromNat((v / 1099511627776) % 256),     // byte 5
      Nat8.fromNat((v / 4294967296) % 256),         // byte 4
      Nat8.fromNat((v / 16777216) % 256),           // byte 3
      Nat8.fromNat((v / 65536) % 256),              // byte 2
      Nat8.fromNat((v / 256) % 256),                // byte 1
      Nat8.fromNat(v % 256),                        // byte 0
    ]);
  };

  /// Compute SHA256 hash of block content using binary preimage (zero-copy)
  func computeBlockHash(
    parentHash : ?Blob,
    timestamp : Nat64,
    tx : T.Transaction,
    effectiveFee : ?Nat,
  ) : Blob {
    let digest = Sha256.Digest(#sha256);
    // Parent hash (32 bytes or absent — length-prefixed for domain separation)
    switch (parentHash) {
      case (?h) { digest.writeArray([0x01]); digest.writeBlob(h) };
      case null { digest.writeArray([0x00]) };
    };
    // Timestamp: fixed 8-byte big-endian
    nat64ToBytes(digest, timestamp);
    // Kind: length-prefixed UTF-8
    let kindBytes = Text.encodeUtf8(tx.kind);
    natToBytes(digest, kindBytes.size());
    digest.writeBlob(kindBytes);
    // Amount: variable-length big-endian
    natToBytes(digest, tx.amount);
    // Accounts: principal bytes with presence flag
    switch (tx.from) {
      case (?a) { digest.writeArray([0x01]); digest.writeBlob(Principal.toBlob(a.owner)) };
      case null { digest.writeArray([0x00]) };
    };
    switch (tx.to) {
      case (?a) { digest.writeArray([0x01]); digest.writeBlob(Principal.toBlob(a.owner)) };
      case null { digest.writeArray([0x00]) };
    };
    // Fee: presence flag + variable-length
    switch (effectiveFee) {
      case (?f) { digest.writeArray([0x01]); natToBytes(digest, f) };
      case null { digest.writeArray([0x00]) };
    };
    digest.sum()
  };

  // ═══════════════════════════════════════════════════════
  //  STABLE STATE (pure data — no closures)
  // ═══════════════════════════════════════════════════════

  public type State = {
    var blockCount : Nat;
    var lastHash : ?Blob;
    var accountTxIndex : Map.Map<T.AccountKey, List.List<Nat>>;
    var subaccountMap : Map.Map<Principal, List.List<Blob>>;
    stableLog : SLog.State;
    mmr : MMR.State;
  };

  public func newState() : State {
    {
      var blockCount = 0;
      var lastHash : ?Blob = null;
      var accountTxIndex = Map.empty<T.AccountKey, List.List<Nat>>();
      var subaccountMap = Map.empty<Principal, List.List<Blob>>();
      stableLog = SLog.newState();
      mmr = MMR.newState();
    };
  };

  // ═══════════════════════════════════════════════════════
  //  OPERATIONS
  // ═══════════════════════════════════════════════════════

  /// Append a transaction. Returns block index.
  public func append(state : State, tx : T.Transaction, effectiveFee : ?Nat) : Nat {
    let idx = state.blockCount;
    let timestamp = Nat64.fromNat(Int.abs(Time.now()));
    let hash = computeBlockHash(state.lastHash, timestamp, tx, effectiveFee);
    let encoded = encodeBlock(idx, state.lastHash, hash, timestamp, tx, effectiveFee);
    ignore SLog.append(state.stableLog, encoded);
    // Use blockHash directly as MMR leaf (domain separation is in internal nodes)
    // Saves one full SHA256 per block vs MMR.hashLeaf(hash)
    ignore MMR.append(state.mmr, hash);
    state.blockCount += 1;
    state.lastHash := ?hash;
    // Index accounts (skip null accounts to avoid unnecessary Map lookups)
    indexAccount(state, tx.from, idx);
    indexAccount(state, tx.to, idx);
    indexAccount(state, tx.spender, idx);
    trackSub(state, tx.from);
    trackSub(state, tx.to);
    idx
  };

  // ═══════════════════════════════════════════════════════
  //  V2 CBOR ENCODING (full fidelity: subaccounts, spender, memo)
  // ═══════════════════════════════════════════════════════

  func encodeBlock(_idx : Nat, parentHash : ?Blob, _hash : Blob, ts : Nat64, tx : T.Transaction, fee : ?Nat) : Blob {
    CBOR.encodeBlockV2({
      kind = tx.kind;
      from = tx.from;
      to = tx.to;
      spender = tx.spender;
      amount = tx.amount;
      fee = tx.fee;
      memo = tx.memo;
      parentHash;
      timestamp = ts;
      index = _idx;
    }, fee)
  };

  /// Decode block — auto-detects v1 (pipe-delimited text) vs v2 (CBOR)
  func decodeBlock(idx : Nat, data : Blob) : ?DecodedBlock {
    let bytes = Blob.toArray(data);
    if (bytes.size() == 0) return null;

    // v2: starts with 0x02 version byte
    if (bytes[0] == 0x02) {
      let rest = Array.tabulate<Nat8>(bytes.size() - 1, func(i) { bytes[i + 1] });
      switch (CBOR.decodeBlockV2(rest, idx)) {
        case (?btx) {
          ?{
            tx = {
              kind = btx.kind; from = btx.from; to = btx.to; spender = btx.spender;
              amount = btx.amount; fee = btx.fee; memo = btx.memo;
              timestamp = btx.timestamp; index = btx.index;
            };
            parentHash = btx.parentHash;
          }
        };
        case null null;
      };
    } else {
      // v1 fallback: pipe-delimited text (backward compatible)
      switch (decodeBlockV1(idx, data)) {
        case (?tx) ?{ tx; parentHash = null };
        case null null;
      };
    };
  };

  /// Legacy v1 decoder for pre-CBOR blocks
  func decodeBlockV1(idx : Nat, data : Blob) : ?T.Transaction {
    switch (Text.decodeUtf8(data)) {
      case null null;
      case (?text) {
        let collected = List.empty<Text>();
        var current = "";
        for (c in text.chars()) {
          if (c == '|') {
            List.add(collected, current);
            current := "";
          } else {
            current #= Text.fromChar(c);
          };
        };
        List.add(collected, current);
        let parts = List.toArray(collected);
        if (parts.size() < 7) return null;
        let kind = parts[2];
        let amount = switch (Nat.fromText(parts[3])) { case (?n) n; case null 0 };
        let from = if (parts[4] == "") { null } else {
          ?({ owner = Principal.fromText(parts[4]); subaccount = null } : T.Account)
        };
        let to = if (parts[5] == "") { null } else {
          ?({ owner = Principal.fromText(parts[5]); subaccount = null } : T.Account)
        };
        let fee = if (parts[6] == "") { null } else {
          switch (Nat.fromText(parts[6])) { case (?n) ?n; case null null }
        };
        let ts = switch (Nat.fromText(parts[1])) { case (?n) Nat64.fromNat(n); case null 0 : Nat64 };
        ?{
          kind; from; to; spender = null; amount; fee; memo = null;
          timestamp = ts; index = idx;
        }
      };
    };
  };

  // Max transaction indices per account (prevents unbounded memory growth)
  let MAX_ACCOUNT_TX_INDEX : Nat = 10_000;

  func indexAccount(state : State, account : ?T.Account, txIdx : Nat) {
    switch (account) {
      case (?a) {
        let key = T.accountKey(a);
        let existing = switch (Map.get(state.accountTxIndex, T.accountKeyCompare, key)) {
          case (?list) list; case null List.empty<Nat>();
        };
        List.add(existing, txIdx);
        // Cap at MAX_ACCOUNT_TX_INDEX — oldest entries are in StableLog if needed
        if (List.size(existing) > MAX_ACCOUNT_TX_INDEX) {
          // Trim: keep only the last MAX_ACCOUNT_TX_INDEX entries
          let arr = List.toArray(existing);
          let trimmed = List.empty<Nat>();
          var i = arr.size() - MAX_ACCOUNT_TX_INDEX;
          while (i < arr.size()) {
            List.add(trimmed, arr[i]);
            i += 1;
          };
          Map.add(state.accountTxIndex, T.accountKeyCompare, key, trimmed);
        } else {
          Map.add(state.accountTxIndex, T.accountKeyCompare, key, existing);
        };
      };
      case null {};
    };
  };

  func trackSub(state : State, account : ?T.Account) {
    switch (account) {
      case (?a) {
        let sub = switch (a.subaccount) { case (?s) s; case null "" : Blob };
        let existing = switch (Map.get(state.subaccountMap, Principal.compare, a.owner)) {
          case (?list) list; case null List.empty<Blob>();
        };
        var found = false;
        for (s in List.values(existing)) { if (s == sub) found := true };
        if (not found) {
          List.add(existing, sub);
          Map.add(state.subaccountMap, Principal.compare, a.owner, existing);
        };
      };
      case null {};
    };
  };

  // ═══════════════════════════════════════════════════════
  //  INDEX QUERIES
  // ═══════════════════════════════════════════════════════

  public func getAccountTransactions(state : State, account : T.Account, start : ?Nat, maxResults : Nat) : [T.Transaction] {
    let key = T.accountKey(account);
    let indices = switch (Map.get(state.accountTxIndex, T.accountKeyCompare, key)) {
      case (?list) List.toArray(list); case null return [];
    };
    let reversed = Array.tabulate<Nat>(indices.size(), func(i) { indices[indices.size() - 1 - i] });
    let startPos = switch (start) {
      case (?s) {
        var pos : Nat = 0;
        label search for (i in reversed.keys()) {
          if (reversed[i] <= s) { pos := i; break search };
        };
        pos
      };
      case null 0;
    };
    let cap = Nat.min(maxResults, 100);
    let result = List.empty<T.Transaction>();
    var count : Nat = 0;
    var i = startPos;
    while (i < reversed.size() and count < cap) {
      let txIdx = reversed[i];
      switch (SLog.get(state.stableLog,txIdx)) {
        case (?data) {
          switch (decodeBlock(txIdx, data)) {
            case (?decoded) { List.add(result, decoded.tx) };
            case null {};
          };
        };
        case null {};
      };
      count += 1;
      i += 1;
    };
    List.toArray(result)
  };

  public func getOldestTxId(state : State, account : T.Account) : ?Nat {
    let key = T.accountKey(account);
    switch (Map.get(state.accountTxIndex, T.accountKeyCompare, key)) {
      case (?list) { let arr = List.toArray(list); if (arr.size() > 0) ?arr[0] else null };
      case null null;
    };
  };

  public func listSubaccounts(state : State, owner : Principal, start : ?Blob) : [Blob] {
    switch (Map.get(state.subaccountMap, Principal.compare, owner)) {
      case (?list) {
        let all = List.toArray(list);
        switch (start) {
          case null all;
          case (?s) {
            var found = false;
            let result = List.empty<Blob>();
            for (sub in all.vals()) {
              if (found) { List.add(result, sub) };
              if (sub == s) { found := true };
            };
            List.toArray(result)
          };
        };
      };
      case null [];
    };
  };

  // ═══════════════════════════════════════════════════════
  //  BLOCK ACCESS
  // ═══════════════════════════════════════════════════════

  public func getBlocks(state : State, start : Nat, length : Nat) : [Block] {
    let end = Nat.min(start + length, state.blockCount);
    if (start >= state.blockCount) return [];
    let result = List.empty<Block>();
    var i = start;
    while (i < end) {
      switch (SLog.get(state.stableLog,i)) {
        case (?data) {
          switch (decodeBlock(i, data)) {
            case (?decoded) {
              List.add(result, {
                index = i;
                parentHash = decoded.parentHash;
                hash = Sha256.fromBlob(#sha256, data);
                timestamp = decoded.tx.timestamp;
                transaction = decoded.tx;
                effectiveFee = decoded.tx.fee;
              });
            };
            case null {};
          };
        };
        case null {};
      };
      i += 1;
    };
    List.toArray(result)
  };

  public func length(state : State) : Nat { state.blockCount };
  public func tipHash(state : State) : ?Blob { state.lastHash };
  public func dataSize(state : State) : Nat { SLog.dataSize(state.stableLog) };

  // ═══════════════════════════════════════════════════════
  //  MERKLE MOUNTAIN RANGE — O(log n) inclusion proofs
  // ═══════════════════════════════════════════════════════

  /// Get the MMR root hash (covers all blocks)
  public func mmrRoot(state : State) : ?Blob { MMR.rootHash(state.mmr) };

  /// Number of MMR peaks (= popcount of leafCount)
  public func mmrPeakCount(state : State) : Nat { MMR.peakCount(state.mmr) };

  /// Generate an inclusion proof for a block at the given index.
  /// Returns sibling hashes needed to verify the block is in the MMR.
  public func mmrProof(state : State, blockIndex : Nat) : ?{
    siblings : [Blob];
    peakIndex : Nat;
    peaks : [Blob];
  } {
    MMR.generateProof(state.mmr, blockIndex)
  };
};
