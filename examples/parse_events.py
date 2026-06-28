#!/usr/bin/env python3
# Parse the candid output of `coreD.allEvents()` into the ordered audit-event strings —
# one `AuditEvent.encoded` per line, ordered by `seq`. This is the exact input that
# `mmr_rederive.py` folds into the audit-MMR root, and it doubles as the human-readable
# settlement lifecycle stream (ORDER -> FUND_A -> FUND_B -> FUNDED -> SETTLED ... per trade).
#
# Usage:  <thebes `allEvents ()` output on stdin>  ->  prints each encoded event, one per line
#
# thebes prints records hash-keyed (field name -> candid field hash), so we resolve the
# "encoded" and "seq" field hashes ourselves rather than depend on field names being present.
import sys, re

def candid_hash(name: str) -> int:
    h = 0
    for ch in name.encode():
        h = (h * 223 + ch) & 0xFFFFFFFF
    return h

H_ENCODED = candid_hash("encoded")
H_SEQ = candid_hash("seq")

text = re.sub(r"\x1b\[[0-9;]*m", "", sys.stdin.read())  # strip ANSI colour

rows = []
for rec in re.findall(r"record \{(.*?)\}", text, re.S):
    m_enc = re.search(r'%d\s*=\s*"((?:[^"\\]|\\.)*)"' % H_ENCODED, rec)
    if not m_enc:
        continue
    encoded = m_enc.group(1)
    m_seq = re.search(r"%d\s*=\s*([0-9_]+)" % H_SEQ, rec)
    seq = int(m_seq.group(1).replace("_", "")) if m_seq else len(rows)
    rows.append((seq, encoded))

rows.sort(key=lambda r: r[0])
for _, encoded in rows:
    print(encoded)
