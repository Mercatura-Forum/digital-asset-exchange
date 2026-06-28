/// SHA-256 with a streaming digest interface, over our own hash core.
///
/// The settlement core and the ledgers hash incrementally — a domain-separation
/// marker byte, then one or more `Blob` fields, then a final digest. This module
/// gives them that streaming shape (`Digest` with `writeArray` / `writeBlob` /
/// `sum`) while the actual compression runs through `InPlaceSha256d`, our
/// allocation-free SHA-256 core (verified against the NIST vectors and against
/// real block headers). Keeping the hash in-house means the exchange carries no
/// external cryptographic dependency.
///
/// A `Digest` accumulates the written bytes and runs the compression once, at
/// `sum()`. Output is therefore identical to feeding the same byte sequence to a
/// one-shot SHA-256 — the streaming and one-shot forms agree byte for byte, which
/// is what lets the Merkle-Mountain-Range audit root be re-derived externally.

import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import List "mo:core/List";

import Core "InPlaceSha256d";

module {

  /// Only SHA-256 is used here; the variant is kept so call sites read the same as
  /// the conventional `Sha256.Digest(#sha256)` form.
  public type Algorithm = { #sha256 };

  /// Streaming SHA-256. Bytes written in order; `sum()` returns the 32-byte digest.
  public class Digest(_algo : Algorithm) {
    let buffer = List.empty<Nat8>();

    public func writeArray(bytes : [Nat8]) {
      for (b in bytes.vals()) List.add(buffer, b);
    };

    public func writeBlob(b : Blob) {
      for (x in b.vals()) List.add(buffer, x);
    };

    public func sum() : Blob {
      let hasher = Core.Hasher();
      Blob.fromArray(hasher.sha256General(List.toArray(buffer)));
    };
  };

  /// One-shot SHA-256 of a byte array.
  public func fromArray(_algo : Algorithm, data : [Nat8]) : Blob {
    let hasher = Core.Hasher();
    Blob.fromArray(hasher.sha256General(data));
  };

  /// One-shot SHA-256 of a blob.
  public func fromBlob(_algo : Algorithm, data : Blob) : Blob {
    let hasher = Core.Hasher();
    Blob.fromArray(hasher.sha256General(Blob.toArray(data)));
  };
};
