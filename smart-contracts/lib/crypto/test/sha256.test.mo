/// Known-answer tests for the in-house SHA-256 (`lib/crypto/Sha256` over `InPlaceSha256d`).
///
/// Pins the hash to the NIST FIPS-180-4 vectors and checks it across every padding
/// regime (one-block, two-block, and the 55/56/63/64-byte boundaries) plus the
/// streaming form — feeding bytes through a `Digest` must equal hashing the same
/// bytes in one shot. That streaming-equals-one-shot property is what lets the
/// Merkle-Mountain-Range audit root be re-derived from the public event log.

import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Text "mo:core/Text";

import Sha256 "../Sha256";

var checks = 0; var fails = 0;
func check(name : Text, cond : Bool) { checks += 1; if (not cond) { fails += 1; Debug.print("  FAIL: " # name) } };

let HEX = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"];
func hex(b : Blob) : Text { var o = ""; for (x in b.vals()) { let n = Nat8.toNat(x); o #= HEX[n/16] # HEX[n%16] }; o };

// NIST FIPS-180-4 known-answer vectors.
check("sha256(\"abc\")", hex(Sha256.fromArray(#sha256, [0x61, 0x62, 0x63])) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
check("sha256(\"\")",    hex(Sha256.fromArray(#sha256, [])) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
// "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" (56 bytes — forces a second block).
let twoBlock = Blob.toArray(Text.encodeUtf8("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"));
check("sha256(two-block KAT)", hex(Sha256.fromArray(#sha256, twoBlock)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");

// The streaming form must agree with the one-shot form on the same byte sequence,
// across the padding boundaries.
for (len in [0, 1, 31, 32, 55, 56, 63, 64, 65, 100, 119, 120, 128, 200, 257].vals()) {
  let msg = Array.tabulate<Nat8>(len, func(i) { Nat8.fromNat((i * 37 + 11) % 256) });
  let d = Sha256.Digest(#sha256);
  d.writeArray(msg);
  check("streaming == one-shot @len=" # Nat.toText(len), Blob.equal(d.sum(), Sha256.fromArray(#sha256, msg)));
};

// Domain-separated marker + fields (the MMR node-hash shape).
let left = Sha256.fromArray(#sha256, [1, 2, 3]);
let right = Sha256.fromArray(#sha256, [4, 5, 6]);
let d = Sha256.Digest(#sha256);
d.writeArray([0x01]); d.writeBlob(left); d.writeBlob(right);
check("marker+blobs streaming == one-shot concat",
  Blob.equal(d.sum(), Sha256.fromArray(#sha256, Array.flatten<Nat8>([[0x01], Blob.toArray(left), Blob.toArray(right)]))));

Debug.print("checks=" # Nat.toText(checks) # " fails=" # Nat.toText(fails));
if (fails > 0) { Runtime.trap("SHA-256 KAT RED: " # Nat.toText(fails) # " failures") } else { Debug.print("SHA-256 KAT GREEN: all " # Nat.toText(checks) # " checks passed") };
