#!/usr/bin/env python3
# Parse the (hash-keyed) candid output of allObligations / unsettledObligations into rows.
# Usage: <thebes output on stdin>  [--window N] [--unsettled] -> prints "seq window buyId sellId qty settled"
import sys, re
FIELDS = {5741471:'seq',1384944624:'window',3136741569:'buyId',1782076429:'sellId',
          5645366:'qty',665460857:'settled',3027091297:'dvpTradeId'}
args = sys.argv[1:]
want_window = None; only_unsettled = False
if '--window' in args: want_window = int(args[args.index('--window')+1])
if '--unsettled' in args: only_unsettled = True
t = sys.stdin.read()
t = re.sub(r'\x1b\[[0-9;]*m','',t)
rows=[]
for rec in re.findall(r'record \{(.*?)\}', t, re.S):
    d={}
    for h,v in re.findall(r'([0-9_]+)\s*=\s*([0-9_]+|true|false)', rec):
        hn=int(h.replace('_',''))
        if hn in FIELDS:
            val=v.replace('_','')
            d[FIELDS[hn]] = (val=='true') if v in ('true','false') else int(val)
    if 'seq' in d:
        rows.append(d)
out=[]
for d in rows:
    if want_window is not None and d.get('window')!=want_window: continue
    if only_unsettled and d.get('settled',False): continue
    out.append(d)
for d in out:
    print(d.get('seq'), d.get('window'), d.get('buyId'), d.get('sellId'), d.get('qty'), d.get('settled'))
