/// Allowances.mo -- ICRC-2 allowance table backed by Region stable memory.
///
/// The public API matches the old heap Map implementation, but allowance state
/// now lives outside GC-visible heap:
///   - RegionBTree maps (owner, spender) to the latest allowance-record index.
///   - StableLog stores append-only allowance record versions.
///   - Zero allowance is represented as a tombstone because RegionBTree has no
///     physical delete operation.

import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Time "mo:core/Time";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Result "mo:core/Result";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";

import T "Types";
import BTree "RegionBTree";
import SLog "StableLog";

module {

  public type AllowanceRecord = {
    var allowance : Nat;
    var expires_at : ?Nat64;
    arrived_at : Nat64;
  };

  public type AllowanceKey = (T.AccountKey, T.AccountKey);

  public type ApproveError = {
    #AllowanceChanged : { current_allowance : Nat };
    #Expired : { ledger_time : Nat64 };
    #InsufficientFunds : { balance : Nat };
  };

  public type UseAllowanceError = {
    #InsufficientAllowance : { allowance : Nat };
  };

  public type State = {
    table : BTree.State;
    records : SLog.State;
    var expirationQueue : List.List<(Nat64, AllowanceKey)>;
    var activeCount : Nat;
  };

  public func newState() : State {
    {
      table = BTree.newState();
      records = SLog.newState();
      var expirationQueue = List.empty<(Nat64, AllowanceKey)>();
      var activeCount = 0;
    }
  };

  func now() : Nat64 {
    Nat64.fromNat(Int.abs(Time.now()))
  };

  func isActive(record : AllowanceRecord) : Bool {
    record.allowance > 0
  };

  func accountKeyToBlob(key : T.AccountKey) : Blob {
    let pBlob = Principal.toBlob(key.0);
    let pArr = Blob.toArray(pBlob);
    let sArr = Blob.toArray(key.1);
    Blob.fromArray(Array.tabulate<Nat8>(62, func(i) {
      if (i == 0) {
        Nat8.fromNat(pBlob.size())
      } else if (i <= 29) {
        let pi = Int.abs((i : Int) - 1);
        if (pi < pArr.size()) pArr[pi] else 0
      } else {
        let si = Int.abs((i : Int) - 30);
        if (si < sArr.size()) sArr[si] else 0
      }
    }))
  };

  func allowanceKeyToBlob(key : AllowanceKey) : Blob {
    let owner = Blob.toArray(accountKeyToBlob(key.0));
    let spender = Blob.toArray(accountKeyToBlob(key.1));
    Blob.fromArray(Array.tabulate<Nat8>(124, func(i) {
      if (i < 62) owner[i] else spender[i - 62]
    }))
  };

  func natToBytes(n : Nat) : [Nat8] {
    if (n == 0) return [0];
    var tmp = n;
    var byteCount : Nat = 0;
    while (tmp > 0) {
      tmp /= 256;
      byteCount += 1;
    };
    if (byteCount > 65535) Runtime.trap("Allowance amount is too large to encode");
    Array.tabulate<Nat8>(byteCount, func(i) {
      Nat8.fromNat((n / (256 ** (byteCount - 1 - i))) % 256)
    })
  };

  func bytesToNat(bytes : [Nat8]) : Nat {
    var n : Nat = 0;
    for (b in bytes.vals()) {
      n := n * 256 + Nat8.toNat(b);
    };
    n
  };

  func nat64Byte(n : Nat64, byteIndex : Nat) : Nat8 {
    let v = Nat64.toNat(n);
    Nat8.fromNat((v / (256 ** (7 - byteIndex))) % 256)
  };

  func readNat64(bytes : [Nat8], start : Nat) : ?Nat64 {
    if (start + 8 > bytes.size()) return null;
    var n : Nat = 0;
    var i = 0;
    while (i < 8) {
      n := n * 256 + Nat8.toNat(bytes[start + i]);
      i += 1;
    };
    ?Nat64.fromNat(n)
  };

  func encodeIndex(idx : Nat) : Blob {
    Blob.fromArray(Array.tabulate<Nat8>(8, func(i) {
      Nat8.fromNat((idx / (256 ** (7 - i))) % 256)
    }))
  };

  func decodeIndex(ptr : Blob) : ?Nat {
    let bytes = Blob.toArray(ptr);
    if (bytes.size() != 8) return null;
    var n : Nat = 0;
    for (b in bytes.vals()) {
      n := n * 256 + Nat8.toNat(b);
    };
    ?n
  };

  func encodeRecord(record : AllowanceRecord) : Blob {
    let amountBytes = natToBytes(record.allowance);
    let amountLen = amountBytes.size();
    let hasExpiry : Nat8 = switch (record.expires_at) { case (?_) 1; case null 0 };
    let expiry : Nat64 = switch (record.expires_at) { case (?exp) exp; case null 0 };
    let total = 1 + 2 + amountLen + 1 + 8 + 8;
    Blob.fromArray(Array.tabulate<Nat8>(total, func(i) {
      if (i == 0) {
        1
      } else if (i == 1) {
        Nat8.fromNat(amountLen / 256)
      } else if (i == 2) {
        Nat8.fromNat(amountLen % 256)
      } else if (i < 3 + amountLen) {
        amountBytes[i - 3]
      } else if (i == 3 + amountLen) {
        hasExpiry
      } else if (i < 12 + amountLen) {
        nat64Byte(expiry, i - (4 + amountLen))
      } else {
        nat64Byte(record.arrived_at, i - (12 + amountLen))
      }
    }))
  };

  func decodeRecord(data : Blob) : ?AllowanceRecord {
    let bytes = Blob.toArray(data);
    if (bytes.size() < 20) return null;
    if (bytes[0] != 1) return null;
    let amountLen = Nat8.toNat(bytes[1]) * 256 + Nat8.toNat(bytes[2]);
    if (amountLen == 0) return null;
    let expectedLen = 1 + 2 + amountLen + 1 + 8 + 8;
    if (bytes.size() != expectedLen) return null;
    let amountBytes = Array.tabulate<Nat8>(amountLen, func(i) { bytes[3 + i] });
    let flag = bytes[3 + amountLen];
    let expiry = switch (readNat64(bytes, 4 + amountLen)) {
      case (?exp) exp;
      case null return null;
    };
    let arrived = switch (readNat64(bytes, 12 + amountLen)) {
      case (?ts) ts;
      case null return null;
    };
    let expiresAt = if (flag == 0) null else ?expiry;
    ?{ var allowance = bytesToNat(amountBytes); var expires_at = expiresAt; arrived_at = arrived }
  };

  func currentRecord(state : State, key : AllowanceKey) : ?AllowanceRecord {
    switch (BTree.get(state.table, allowanceKeyToBlob(key))) {
      case null null;
      case (?ptr) {
        switch (decodeIndex(ptr)) {
          case null null;
          case (?idx) {
            switch (SLog.get(state.records, idx)) {
              case null null;
              case (?data) decodeRecord(data);
            }
          };
        }
      };
    }
  };

  func writeRecord(state : State, key : AllowanceKey, record : AllowanceRecord) {
    let oldActive = switch (currentRecord(state, key)) {
      case (?old) isActive(old);
      case null false;
    };
    let newActive = isActive(record);

    let idx = SLog.append(state.records, encodeRecord(record));
    ignore BTree.put(state.table, allowanceKeyToBlob(key), encodeIndex(idx));

    if (oldActive and not newActive) {
      if (state.activeCount > 0) state.activeCount -= 1;
    } else if (not oldActive and newActive) {
      state.activeCount += 1;
    };
  };

  func tombstone(state : State, key : AllowanceKey, ts : Nat64) {
    writeRecord(state, key, { var allowance = 0; var expires_at = null; arrived_at = ts });
  };

  public func getAllowance(state : State, owner : T.Account, spender : T.Account) : T.Allowance {
    let key : AllowanceKey = (T.accountKey(owner), T.accountKey(spender));
    switch (currentRecord(state, key)) {
      case (?record) {
        switch (record.expires_at) {
          case (?exp) {
            if (exp <= now()) return { allowance = 0; expires_at = null };
          };
          case null {};
        };
        { allowance = record.allowance; expires_at = record.expires_at }
      };
      case null ({ allowance = 0; expires_at = null } : T.Allowance);
    }
  };

  public func approve(
    state : State,
    owner : T.Account,
    spender : T.Account,
    amount : Nat,
    expires_at : ?Nat64,
    expectedAllowance : ?Nat,
  ) : Result.Result<(), ApproveError> {
    let key : AllowanceKey = (T.accountKey(owner), T.accountKey(spender));
    let t = now();

    switch (expires_at) {
      case (?exp) {
        if (exp <= t) return #err(#Expired({ ledger_time = t }));
      };
      case null {};
    };

    switch (expectedAllowance) {
      case (?expected) {
        let current = getAllowance(state, owner, spender).allowance;
        if (current != expected) return #err(#AllowanceChanged({ current_allowance = current }));
      };
      case null {};
    };

    writeRecord(state, key, {
      var allowance = amount;
      var expires_at = expires_at;
      arrived_at = t;
    });

    if (amount > 0) {
      switch (expires_at) {
        case (?exp) { List.add(state.expirationQueue, (exp, key)) };
        case null {};
      };
    };

    #ok(())
  };

  public func useAllowance(
    state : State,
    owner : T.Account,
    spender : T.Account,
    amount : Nat,
  ) : Result.Result<(), UseAllowanceError> {
    let key : AllowanceKey = (T.accountKey(owner), T.accountKey(spender));
    let t = now();

    switch (currentRecord(state, key)) {
      case (?record) {
        switch (record.expires_at) {
          case (?exp) {
            if (exp <= t) {
              tombstone(state, key, t);
              return #err(#InsufficientAllowance({ allowance = 0 }));
            };
          };
          case null {};
        };

        if (record.allowance < amount) {
          return #err(#InsufficientAllowance({ allowance = record.allowance }));
        };

        let remaining = Int.abs((record.allowance : Int) - (amount : Int));
        writeRecord(state, key, {
          var allowance = remaining;
          var expires_at = if (remaining == 0) null else record.expires_at;
          arrived_at = record.arrived_at;
        });
        #ok(())
      };
      case null #err(#InsufficientAllowance({ allowance = 0 }));
    }
  };

  public func prune(state : State, limit : Nat) : Nat {
    let t = now();
    var pruned : Nat = 0;
    var remaining = List.empty<(Nat64, AllowanceKey)>();

    for ((exp, key) in List.values(state.expirationQueue)) {
      switch (currentRecord(state, key)) {
        case null {};
        case (?record) {
          if (pruned < limit and exp <= t) {
            switch (record.expires_at) {
              case (?currentExp) {
                if (currentExp == exp) {
                  tombstone(state, key, t);
                  pruned += 1;
                };
              };
              case null {};
            };
          } else {
            switch (record.expires_at) {
              case (?currentExp) {
                if (currentExp == exp) {
                  List.add(remaining, (exp, key));
                };
              };
              case null {};
            };
          };
        };
      };
    };

    state.expirationQueue := remaining;
    pruned
  };

  public func size(state : State) : Nat {
    state.activeCount
  };

  public func storageStats(state : State) : {
    active_allowances : Nat;
    indexed_pairs : Nat;
    record_versions : Nat;
    record_bytes : Nat;
  } {
    {
      active_allowances = state.activeCount;
      indexed_pairs = BTree.size(state.table);
      record_versions = SLog.size(state.records);
      record_bytes = SLog.dataSize(state.records);
    }
  };

  public type AccountKey = T.AccountKey;
};
