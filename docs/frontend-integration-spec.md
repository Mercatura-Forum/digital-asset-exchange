# DvP Exchange — Frontend Integration Spec (Phase-4 handoff)

**Audience:** the frontend team building the "wow" UI. **Backend:** live + seeded on the **chain_id-4
throwaway** Egypt-L1 cluster (validators `187.127.85.101 / 187.124.35.206 / 187.77.182.211 /
72.60.80.89` on `:18080`). **This is the throwaway, never prod (chain_id 2026 `wan`).** Everything
below is proven end-to-end (see `canisters/dvp-matching/evidence/phase4/`). The frontend builds
against this with **zero backend guesswork** — every method, arg/return shape, seeded id, and the
exact call sequence per flow is here.

> Author: Menese DeFi Team. Source-of-truth `.did` files: `canisters/dvp-matching/build/Matching.did`,
> `canisters/dvp-core/build/DvpCore.did`, `canisters/dvp-listing/build/ListingRegistry.did`,
> `canisters/dvp-core/build/{IndexedLedger,LandLedger}` interfaces.

---

## 0. Canister directory (cid · principal)
| Role | manifest name | cid | principal |
|---|---|---|---|
| CBDC cash ledger (ICRC-1/2) | `cash` | 113038164393856 | `g5mfi-tyaab-tm5p5-cp6aa` |
| Company shares ledger (ICRC-1/2) | `shares` | 275531804196854 | `7cutf-fiaad-5jqp2-qh73a` |
| Land titles (ICRC-7/37) | `land` | 104847466402831 | `4bymr-2iaab-pvxm7-5sqhq` |
| DvP atomic-swap core | `coreD` | 104590569141744 | `ti4fx-siaab-pr7y5-yoxya` |
| Batch-auction exchange engine | `xchgD` | 110769186213380 | `eit2t-baaab-sl45p-7byca` |
| Issuer-listing registry | `listing` | 109464390350404 | `fzpgo-viaab-ry5kq-2gzca` |

Token economics: **CEGP** (cash) fee 10, decimals 2; **ACME** (shares) fee 0, decimals 0 (whole
shares); **land** ICRC-7 fee 0 (indivisible titles).

## 1. Demo actors (personas)
| Persona | role | principal |
|---|---|---|
| ACME Corp (issuer) | mints + sells ACME shares; authorized issuer | `rfbci-ymk5h-hjswi-ad7ow-hzob4-7j64l-ogux7-7mxv3-4h7r3-ge2ia-pqe` (mx-s1) |
| Share sellers | resting asks | mx-s2 `ejf7v-…-fae`, mx-s3 `7hvpl-…-qae` (+ issuer mx-s1) |
| CBDC buyers | resting bids | mx-b1 `r5pl5-…-yae`, mx-b2 `eadba-…-yqe`, mx-b3 `deskp-…-yae` |
| Land owner / developer | holds land title #100 | `apqza-cqj6r-x5pi6-ih3md-ccwdi-wv3di-4s6lr-nmavx-66kkv-hsfvk-xqe` (dvp-landowner) |
| Regulator | read-only audit observer | `x2ju3-rtol6-rwx7h-i4h5r-mbvmy-rofux-kkatd-23cws-h6acd-aim7t-yae` (dvp-regulator) |
| Venue operator / settlement relayer | drives clear + settlement; registry admin; **the core's authorized relayer** | `deytp-b76tg-j57r3-u6lga-pimob-va42r-uq44q-mg2zc-iztwc-p5mqd-rae` (dvp-relayer) |

Seeded assets: every CBDC buyer funded 100,000,000 CEGP; sellers funded 1,000,000 ACME; land title
**#100** ("Nile Riverside Plot #100") owned by the land owner; ACME⇄CEGP **listed**; land collection
**RFQ-listed**.

## 2. Authentication — Memphis passkey → IC principal
Memphis passkey login (WebAuthn delegation, shared derivation origin) yields a **self-authenticating
IC principal** per user; the frontend signs each update call as that principal (the standard
agent/delegation flow). All `query` methods below are open (no auth) — the **regulator / public audit
views need no login**. Update methods (`submitOrder`, `icrc2_approve`, `openLandTrade`, `fundTaker`)
are authenticated as the calling user's passkey principal.

**Binding seeded assets to passkey principals (operator step, before the demo).** The seeded balances
above are currently held by the listed ed25519 demo principals. A passkey login derives a *different*
principal, so for a passkey-driven demo the operator must put the demo assets under each persona's
passkey principal. Recipe (operator runs once, after the frontend captures each persona's passkey
principal `P`):
- **CEGP to a buyer:** `cash.icrc1_transfer({to=P; amount; …})` from a funded buyer, or re-deploy the
  CEGP ledger with `P` in `initial_balances`.
- **ACME to a seller / issuer:** same on `shares`.
- **A land title to the land owner:** `land.mint({owner=P; subaccount=null}, <tokenId>, vec {})`
  (controller = `dvp-relayer`).
- **Authorize a passkey issuer:** `listing.registerIssuer(P)` (admin = `dvp-relayer`).
The flows themselves are identical regardless of which principal holds the assets.

---

## 3. Candid interfaces (arg/return shapes the frontend calls)

### 3.1 Exchange engine `xchgD` (`Matching.did`)
```
type Side        = variant { buy; sell };
type OrderStatus = variant { Open; PartiallyFilled; Filled; Cancelled };
type SubmitResult = record { orderId: nat; status: OrderStatus; reservedShares: nat; reservedCash: nat; note: text };
type OrderView    = record { id: nat; owner: principal; side: Side; limitPrice: nat; qty: nat; remaining: nat; window: nat; status: OrderStatus; allOrNone: bool; createdAt: nat64 };
type ObligationView = record { seq: nat; window: nat; buyId: nat; sellId: nat; buyer: principal; seller: principal; price: nat; qty: nat; dvpTradeId: opt nat; settled: bool };
type ClearResult  = record { window: nat; clearingPrice: opt nat; targetVolume: nat; fillsThisCall: nat; totalFilled: nat; complete: bool; chunks: nat; note: text };

submitOrder      : (record { side: Side; limitPrice: nat; qty: nat; allOrNone: bool }) -> (variant { ok: SubmitResult; err: text });
cancelOrder      : (nat) -> (variant { ok: text; err: text });
clearWindow      : () -> (variant { ok: ClearResult; err: text });
continueClear    : (window: nat) -> (variant { ok: ClearResult; err: text });
settleObligation : (seq: nat, deadlineSecs: nat) -> (variant { ok: text; err: text });   // deterministic, per-match
settleMatched    : (window: nat, deadlineSecs: nat) -> (variant { ok: record { settledThisCall: bool; remaining: nat; note: text }; err: text }); // autonomous Timer self-chain
getCurrentWindow : () -> (nat) query;
getOrder         : (nat) -> (opt OrderView) query;
allOrders        : () -> (vec OrderView) query;
ordersInWindow   : (nat) -> (vec OrderView) query;
allObligations   : () -> (vec ObligationView) query;
unsettledObligations : () -> (vec ObligationView) query;
obligationSummary: () -> (text) query;     // "buyId>sellId@price:qty;…"
bookSummary      : () -> (text) query;     // "id:side:remaining:status;…"
pendingClearStatus: (nat) -> (opt record { window:nat; clearingPrice:nat; targetVolume:nat; filled:nat; i:nat; j:nat; chunks:nat }) query;
reservationOf    : (principal) -> (record { shares: nat; cash: nat }) query;
config           : () -> (record { sharesLedger: principal; cashLedger: principal; dvpCore: principal; matchingEngine: principal; budget: nat64; maxFillsPerChunk: nat; listingRegistry: opt principal }) query;
```

### 3.2 DvP core `coreD` (`DvpCore.did`)
```
type TradeStatus  = variant { Open; Funded; Settled; Aborted };
type SettleResult = record { tradeId: nat; status: TradeStatus; legAPaid: bool; legBPaid: bool; legAPayoutAmount: nat; legBPayoutAmount: nat; note: text };
type FundResult   = record { tradeId: nat; status: TradeStatus; legEscrowed: bool; bothEscrowed: bool; settleNote: text };
type OpenResult   = record { tradeId: nat; status: TradeStatus; makerEscrowed: bool; note: text };
type AuditEvent   = record { seq: nat; tradeId: nat; encoded: text; leafHex: text };

openLandTrade : (record { taker: opt principal; landLedger: principal; tokenId: nat; cashLedger: principal; cashAmount: nat; deadlineSecs: nat }) -> (variant { ok: OpenResult; err: text });
openTrade     : (record { taker: opt principal; assetLedger: principal; assetAmount: nat; cashLedger: principal; cashAmount: nat; deadlineSecs: nat }) -> (variant { ok: OpenResult; err: text });
fundTaker     : (nat) -> (variant { ok: FundResult; err: text });
fundMaker     : (nat) -> (variant { ok: FundResult; err: text });
settle        : (nat) -> (variant { ok: SettleResult; err: text });
reclaim       : (nat) -> (variant { ok: record { tradeId:nat; status:TradeStatus; legARefunded:bool; legBRefunded:bool; note:text }; err: text });
getTrade      : (nat) -> (opt TradeView) query;       // TradeView = full trade incl. per-leg escrow/payout/refund state
auditEvents   : (tradeId: nat) -> (vec AuditEvent) query;
allEvents     : () -> (vec AuditEvent) query;
auditRootHex  : () -> (opt text) query;               // SHA-256 hex of the audit-MMR root
corePrincipal : () -> (principal) query;
tradeCount    : () -> (nat) query;
// authorized-relayer only (the matching engine calls this; the UI does NOT):
settleMatchFor: (record { matchSeq: nat; maker: principal; taker: principal; assetLedger: principal; assetAmount: nat; cashLedger: principal; cashAmount: nat; deadlineSecs: nat }) -> (variant { ok: SettleResult; err: text });
```

### 3.3 Ledgers
```
// cash + shares (ICRC-1/2):
icrc1_balance_of : (record { owner: principal; subaccount: opt blob }) -> (nat) query;
icrc1_fee        : () -> (nat) query;
icrc1_total_supply: () -> (nat) query;
icrc2_approve    : (record { spender: record { owner: principal; subaccount: opt blob }; amount: nat; from_subaccount: opt blob; expected_allowance: opt nat; expires_at: opt nat64; fee: opt nat; memo: opt blob; created_at_time: opt nat64 }) -> (variant { Ok: nat; Err: variant {…} });
// land (ICRC-7/37):
icrc7_owner_of       : (vec nat) -> (vec opt record { owner: principal; subaccount: opt blob }) query;
icrc7_balance_of     : (vec record { owner: principal; subaccount: opt blob }) -> (vec nat) query;
icrc7_token_metadata : (vec nat) -> (vec opt vec record { text; variant { Blob:blob; Int:int; Nat:nat; Text:text } }) query;
icrc37_approve_tokens: (vec record { token_id: nat; approval_info: record { spender: record { owner: principal; subaccount: opt blob }; from_subaccount: opt blob; expires_at: opt nat64; created_at_time: opt nat64; memo: opt blob } }) -> (vec opt variant {…});
```

### 3.4 Listing registry `listing` (`ListingRegistry.did`)
```
isPairTradeable : (shares: principal, cash: principal) -> (bool) query;   // engine consults this at intake
isLandTradeable : (land: principal) -> (bool) query;                      // RFQ clients consult this
shareListingsView : () -> (vec record { shares:principal; cash:principal; issuer:principal; supplyAtListing:nat; status: variant { Listed; Delisted } }) query;
landListingsView  : () -> (vec record { land:principal; issuer:principal; supplyAtListing:nat; status: variant { Listed; Delisted } }) query;
listShare         : (shares: principal, cash: principal) -> (variant { ok: text; err: text });   // authorized issuer
listLandCollection: (land: principal) -> (variant { ok: text; err: text });                      // authorized issuer
registerIssuer    : (principal) -> (variant { ok: text; err: text });                            // admin only
```

---

## 4. Exact call sequence per flagship flow

### Flow 1 — Share trade settles T+0
1. **Buyer** (and seller) ensure allowance: `cash.icrc2_approve({ spender = coreD; amount = limitPrice*qty + fee })`; **seller** `shares.icrc2_approve({ spender = coreD; amount = qty })`. (UI can pre-flight `icrc1_balance_of` + `reservationOf` + `isPairTradeable(shares,cash)` to gate the form.)
2. **Seller** `xchgD.submitOrder({ side = sell; limitPrice; qty; allOrNone = false })`.
3. **Buyer** `xchgD.submitOrder({ side = buy; limitPrice; qty; allOrNone = false })`. → `SubmitResult` (orderId, reservation).
4. At window close the **venue operator** calls `xchgD.clearWindow()` (and `continueClear(window)` while `pendingClearStatus(window)` is non-null) → emits `ObligationView`s at the uniform price p*.
5. **Settlement (no trader action):** the operator/relayer calls, per cleared obligation seq, `xchgD.settleObligation(seq, deadlineSecs)` (or `xchgD.settleMatched(window, deadlineSecs)` for autonomous Timer-chained settle). The engine relays to `coreD.settleMatchFor` → shares→buyer + cash→seller, both-or-neither, one block.
6. **UI confirmation / receipt:** poll `xchgD.allObligations()` until the obligation's `settled=true` & `dvpTradeId=opt T`; then `coreD.getTrade(T).status == Settled` and `coreD.auditEvents(T)` contains a `SETTLED|…` event. Balances via `icrc1_balance_of`. **No T+2 — settled in the batch.**

### Flow 2 — Land⇄CBDC atomic swap (RFQ)
1. Pre-flight: `listing.isLandTradeable(land)` must be true; `land.icrc7_owner_of([tokenId])` = the seller.
2. **Land owner** `land.icrc37_approve_tokens([{ token_id; approval_info = { spender = coreD; … } }])`.
3. **Buyer** `cash.icrc2_approve({ spender = coreD; amount ≥ cashAmount + fee })`.
4. **Land owner** `coreD.openLandTrade({ taker = opt buyer; landLedger = land; tokenId; cashLedger = cash; cashAmount; deadlineSecs })` → `OpenResult.tradeId` (the title is escrowed inline).
5. **Buyer** `coreD.fundTaker(tradeId)` → escrows cash + auto-settles, both-or-neither.
6. **UI confirmation:** `land.icrc7_owner_of([tokenId])` = buyer; `coreD.getTrade(tradeId).status == Settled`; seller CBDC credited. If the buyer never funds before the deadline, the seller calls `coreD.reclaim(tradeId)` to get the title back (no funds stranded).

### Flow 3 — Regulator audit stream (read-only, no login)
1. **Live order/match feed:** poll `xchgD.allOrders()`, `xchgD.allObligations()`, `xchgD.obligationSummary()`.
2. **Settlement lifecycle:** `coreD.allEvents()` → ordered `AuditEvent{ encoded }` strings (`ORDER|… → FUND_A|… → FUND_B|… → FUNDED|… → SETTLED|…` per trade).
3. **Tamper-evidence:** `coreD.auditRootHex()` → the on-chain MMR root; re-derive it off-chain from the `encoded` events (leaf = `SHA256(0x00‖utf8(encoded))`, node = `SHA256(0x01‖L‖R)`, fold peaks high→low) and assert equality. Reference re-deriver: `canisters/dvp-core/evidence/icrc7/mmr_rederive.py` (proven MATCH against this backend).
4. **Cross-node verifiability (optional, sovereign):** the frontend may also poll each validator's `/api/block/{h}` and confirm `block_hash` + `state_root` agree across all 4 nodes (INV-C1/C2).

---

## 5. UI states & error surfaces (so the UI shows truth, not guesses)
- `submitOrder` `err` strings are user-facing-ready: `"insufficient free shares: balance … reserved … need …"`, `"insufficient cash allowance to DvP core: …"`, `"this market (shares/cash pair) is not a registered, funded listing"`.
- Order lifecycle for the UI: `OrderStatus` `Open → PartiallyFilled → Filled | Cancelled`; remainder re-rests at preserved price-time priority in the next window (poll `getOrder(id)`).
- Trade lifecycle: `TradeStatus` `Open → Funded → Settled | Aborted`. A pending obligation shows `settled=false, dvpTradeId=null|opt T`.
- Clearing math: uniform clearing price p* per window (`ClearResult.clearingPrice`); the long side is rationed by **price-time priority** (the proven allocation; a pro-rata variant is an operator-gated option — see the pro-rata proposal in `session-checkpoint-dvp-phase4.md`).
- Chunking: a large clear may take K chunks (`ClearResult.chunks`, `pendingClearStatus`); the UI shows "clearing…" until `complete=true`. `maxFillsPerChunk = 4000` (≈4.8× headroom under the 20 B fuel ceiling — mission C).

## 6. Hard boundaries (do NOT build these into the UI)
- The UI never calls `coreD.settleMatchFor` directly — it is gated to the matching engine. Settlement is triggered via the engine (`settleObligation`/`settleMatched`) or runs autonomously.
- The UI never needs the relayer/admin keys; trading is done as the logged-in user. Clearing + settlement are operator/relayer actions (or autonomous), surfaced to the UI as state changes to poll.
- Throwaway only. No prod ids appear here.
