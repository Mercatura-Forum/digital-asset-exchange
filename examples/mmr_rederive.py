#!/usr/bin/env python3
# Re-derive the DvP audit-MMR root from the ordered audit-event strings (one per line on
# stdin) and compare to the canister's auditRootHex (argv[1]). Replicates MerkleMMR.mo:
#   leaf  = SHA256(0x00 || utf8(event))
#   node  = SHA256(0x01 || left || right)
#   root  = fold non-null peaks high->low: result = peak if first else node(peak, result)
import sys, hashlib
events = [l.rstrip("\n") for l in sys.stdin if l.strip()]
def hleaf(b): return hashlib.sha256(b"\x00" + b).digest()
def hnode(l, r): return hashlib.sha256(b"\x01" + l + r).digest()
MAXH = 64
peaks = [None] * MAXH
def append(leaf):
    cur = leaf; h = 0
    while h < MAXH:
        if peaks[h] is not None:
            cur = hnode(peaks[h], cur); peaks[h] = None; h += 1
        else:
            peaks[h] = cur; return
for e in events:
    append(hleaf(e.encode()))
result = None
for h in range(MAXH - 1, -1, -1):
    if peaks[h] is not None:
        result = peaks[h] if result is None else hnode(peaks[h], result)
got = result.hex() if result else None
exp = sys.argv[1] if len(sys.argv) > 1 else ""
print("re-derived root =", got)
print("canister  root  =", exp)
print("MMR MATCH:", got == exp, "(leaves=%d)" % len(events))
sys.exit(0 if got == exp else 1)
