/// Guards.mo — Per-caller mutex with auto-expiry for reentrancy prevention
///
/// Ported from menes_icp_pool/Guards.mo. Prevents concurrent async calls
/// from the same caller (TOCTOU defense per IC canister-security skill).
///
/// Usage:
///   if (not mutex.tryAcquire("swap:" # Principal.toText(caller))) return #err("busy");
///   try { ... await* ... } finally { mutex.release("swap:" # Principal.toText(caller)) };

import Map "mo:core/Map";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Array "mo:core/Array";

module {

  let MUTEX_EXPIRY_NS : Int = 60_000_000_000; // 60 seconds

  public class MutexManager() {
    var locks = Map.empty<Text, Int>(); // key → acquired timestamp

    public func tryAcquire(key : Text) : Bool {
      let now = Time.now();
      switch (Map.get(locks, Text.compare, key)) {
        case (?ts) {
          if (now - ts > MUTEX_EXPIRY_NS) {
            // Expired — auto-release and acquire
            Map.add(locks, Text.compare, key, now);
            true
          } else { false }; // Still held
        };
        case null {
          Map.add(locks, Text.compare, key, now);
          true
        };
      };
    };

    public func release(key : Text) {
      ignore Map.delete(locks, Text.compare, key);
    };

    public func toStable() : [(Text, Int)] {
      let now = Time.now();
      let entries = Map.toArray(locks);
      Array.filter<(Text, Int)>(entries, func((_, ts)) { now - ts <= MUTEX_EXPIRY_NS });
    };

    public func fromStable(entries : [(Text, Int)]) {
      let now = Time.now();
      for ((k, ts) in entries.vals()) {
        if (now - ts <= MUTEX_EXPIRY_NS) {
          Map.add(locks, Text.compare, k, ts);
        };
      };
    };
  };
};
