/// Zero-per-hash-allocation SHA-256 / double-SHA256 in Motoko — optimized.
///
/// A `Hasher` owns all scratch (state `h`, saved `h1`, schedule `w`, one 64-byte
/// `block`) preallocated ONCE. Every hash reads input from, and writes its digest into,
/// caller-provided `[var Nat8]` buffers — no `Blob`, no array, nothing allocated per
/// hash. The Merkle root is computed in place over one flat `[var Nat8]` buffer
/// (32 B/leaf) halved level by level. Whole-tree allocation is O(1) (the Hasher).
///
/// Instruction-tuned: rotations are inline constant shifts (no calls), bytes convert
/// via fixed-width prims (NO bignum `Nat` hop), word<->byte uses `explodeNat32`, and
/// the SHA-256 length suffix is written as constants on the Merkle hot path.
///
/// Correctness is proven, not assumed: NIST vectors on the general core + byte-exact
/// match to real Bitcoin block headers (see InPlaceTest.mo).
import Prim "mo:⛔";
import Int "mo:core/Int";
import Nat8 "mo:core/Nat8";
import VarArray "mo:core/VarArray";

module {

  let K : [Nat32] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  let IV : [Nat32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];

  public class Hasher() {
    let h = VarArray.repeat<Nat32>(0, 8);
    let h1 = VarArray.repeat<Nat32>(0, 8);
    let w = VarArray.repeat<Nat32>(0, 64);
    let block = VarArray.repeat<Nat8>(0, 64);

    func setIV() { var i = 0; while (i < 8) { h[i] := IV[i]; i += 1 } };

    // Compress the 64 bytes currently in `block` into `h`. Straight schedule (64-word
    // array, direct indices) — faster in Motoko than a %16 sliding window, since Nat
    // modulo costs more than a fixed array bounds check.
    func compress() {
      var i = 0;
      while (i < 16) {
        let j = i * 4;
        w[i] := (Prim.nat16ToNat32(Prim.nat8ToNat16(block[j])) << 24) | (Prim.nat16ToNat32(Prim.nat8ToNat16(block[j + 1])) << 16) | (Prim.nat16ToNat32(Prim.nat8ToNat16(block[j + 2])) << 8) | Prim.nat16ToNat32(Prim.nat8ToNat16(block[j + 3]));
        i += 1;
      };
      while (i < 64) {
        let x15 = w[i - 15];
        let x2 = w[i - 2];
        let s0 = ((x15 >> 7) | (x15 << 25)) ^ ((x15 >> 18) | (x15 << 14)) ^ (x15 >> 3);
        let s1 = ((x2 >> 17) | (x2 << 15)) ^ ((x2 >> 19) | (x2 << 13)) ^ (x2 >> 10);
        w[i] := w[i - 16] +% s0 +% w[i - 7] +% s1;
        i += 1;
      };
      var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3];
      var e = h[4]; var f = h[5]; var g = h[6]; var hh = h[7];
      i := 0;
      while (i < 64) {
        let S1 = ((e >> 6) | (e << 26)) ^ ((e >> 11) | (e << 21)) ^ ((e >> 25) | (e << 7));
        let ch = (e & f) ^ ((^ e) & g);
        let t1 = hh +% S1 +% ch +% K[i] +% w[i];
        let S0 = ((a >> 2) | (a << 30)) ^ ((a >> 13) | (a << 19)) ^ ((a >> 22) | (a << 10));
        let maj = (a & b) ^ (a & c) ^ (b & c);
        let t2 = S0 +% maj;
        hh := g; g := f; f := e; e := d +% t1; d := c; c := b; b := a; a := t1 +% t2;
        i += 1;
      };
      h[0] +%= a; h[1] +%= b; h[2] +%= c; h[3] +%= d;
      h[4] +%= e; h[5] +%= f; h[6] +%= g; h[7] +%= hh;
    };

    func zeroBlockFrom(start : Nat) { var i = start; while (i < 64) { block[i] := 0; i += 1 } };

    // big-endian 64-bit bit length into block[56..63] (general path only)
    func putBitLen(bits : Nat) {
      var v = bits; var i = 63;
      label L while (i >= 56) { block[i] := Prim.natToNat8(v % 256); v /= 256; if (i == 56) break L; i -= 1 };
    };

    func writeStateInto(dst : [var Nat8], off : Nat) {
      var i = 0;
      while (i < 8) {
        let (b0, b1, b2, b3) = Prim.explodeNat32(h[i]);
        let o = off + i * 4;
        dst[o] := b0; dst[o + 1] := b1; dst[o + 2] := b2; dst[o + 3] := b3;
        i += 1;
      };
    };

    /// double-SHA256 of (buf[lOff..+32) ‖ buf[rOff..+32)), result -> dst[dOff..+32).
    /// Allocates nothing.
    public func hashPairInto(buf : [var Nat8], lOff : Nat, rOff : Nat, dst : [var Nat8], dOff : Nat) {
      // pass 1: SHA256 of the 64-byte concatenation
      setIV();
      var i = 0;
      while (i < 32) { block[i] := buf[lOff + i]; block[32 + i] := buf[rOff + i]; i += 1 };
      compress();                       // data block
      block[0] := 0x80; zeroBlockFrom(1);
      block[62] := 0x02;                // bit length 512 = 0x0200 (big-endian)
      compress();                       // padding block
      i := 0; while (i < 8) { h1[i] := h[i]; i += 1 };
      // pass 2: SHA256 of the 32-byte digest h1
      setIV();
      i := 0;
      while (i < 8) {
        let (b0, b1, b2, b3) = Prim.explodeNat32(h1[i]);
        let o = i * 4;
        block[o] := b0; block[o + 1] := b1; block[o + 2] := b2; block[o + 3] := b3;
        i += 1;
      };
      block[32] := 0x80; zeroBlockFrom(33);
      block[62] := 0x01;                // bit length 256 = 0x0100 (big-endian)
      compress();
      writeStateInto(dst, dOff);
    };

    /// General single SHA-256 of an arbitrary message (validation path; allocates output).
    public func sha256General(msg : [Nat8]) : [Nat8] {
      setIV();
      let len = msg.size();
      var off = 0;
      while (off + 64 <= len) {
        var i = 0; while (i < 64) { block[i] := msg[off + i]; i += 1 };
        compress(); off += 64;
      };
      let r = Int.abs((len : Int) - (off : Int));
      var i = 0; while (i < r) { block[i] := msg[off + i]; i += 1 };
      block[r] := 0x80;
      if (r <= 55) {
        var j = r + 1; while (j < 56) { block[j] := 0; j += 1 };
        putBitLen(len * 8); compress();
      } else {
        var j = r + 1; while (j < 64) { block[j] := 0; j += 1 };
        compress(); zeroBlockFrom(0); putBitLen(len * 8); compress();
      };
      let out = VarArray.repeat<Nat8>(0, 32);
      writeStateInto(out, 0);
      VarArray.toArray<Nat8>(out)
    };
  };

  /// Merkle root in place over `buf` (count 32-byte internal leaves). Root -> buf[0..32).
  public func computeRootFlat(buf : [var Nat8], count : Nat) {
    assert (count > 0);
    let hasher = Hasher();
    var n = count;
    while (n > 1) {
      var j = 0; var k = 0;
      while (k < n) {
        let rIdx = if (k + 1 < n) { k + 1 } else { k };
        hasher.hashPairInto(buf, k * 32, rIdx * 32, buf, j * 32);
        j += 1; k += 2;
      };
      n := j;
    };
  };
}
