# Digital Asset Exchange

A sovereign exchange where cash, company shares, and land titles change hands in a single,
indivisible step. The two halves of a trade either both happen or neither does; there is no
moment where one party has given and the other has not yet paid.

It runs entirely on Egypt-L1, a Byzantine-fault-tolerant network. No clearing house sits in the
middle. No single server can be bribed, hacked, or switched off to reverse a settled trade.

*Most markets settle in days through a chain of intermediaries; this one settles in one step, with no intermediary at all.*

---

## What this actually is

Three different kinds of value trade here, and they all settle the same way:

- **Cash** — a digital currency (a CBDC-style token).
- **Company shares** — fungible ownership in a company.
- **Land titles** — unique, one-of-a-kind property deeds.

Buying any of them today is a relay race: you pay, a broker confirms, a custodian moves the asset,
a clearing house reconciles, and *days* later the trade is "final." Every handoff is a place where
things stall, where one side is exposed, where a keeper must be trusted not to fail or cheat.

This project removes the relay. When a buyer and a seller agree, the cash and the asset move
**together**, in the same atomic operation, verified by a network of independent machines that must
agree before anything is written down. The instant it is written, it is final — and anyone can
check it.

The deeper idea: **the things we trade are ultimately paper** — a deed, a share certificate, a
banknote — and paper settlement is slow because the paper and the payment travel separately through
trusted middlemen. When the asset and the money are both just verifiable entries on a
Byzantine-fault-tolerant ledger, "delivery versus payment" stops being a multi-day reconciliation
and becomes a **single, atomic, T+0 event with no clearing house**. That is the whole thesis, built
end to end: a unified, sovereign venue for real-world assets — cash, equities, and real estate —
that settles in one step and is independently auditable by anyone.

---

## Architecture

The system is layered. A thin **market layer** decides *what* trades and at *what price*; a single
**settlement substrate** makes every trade atomic; **asset ledgers** hold the actual balances and
titles; and an **audit + crypto** layer makes the whole thing verifiable without trusting the
operator.

```
   traders / apps
        │  orders, RFQs
        ▼
 ┌─────────────────────────────┐   ┌──────────────────────────┐
 │ matching engine             │   │ listing registry         │   MARKET LAYER
 │ (dvp-matching)              │   │ (dvp-listing)            │   what trades / at what price
 │ batch-auction CLOB, p*      │   │ issuer-gated, funded-only│
 └──────────────┬──────────────┘   └──────────────────────────┘
                │  settlement obligation (buyer, seller, price, qty)
                ▼
 ┌─────────────────────────────────────────────────────────────┐
 │ settlement core (dvp-core)                                   │   SETTLEMENT SUBSTRATE
 │ escrow-first · both-or-neither · idempotent · 5 invariants   │   makes every trade atomic
 └──────────────┬──────────────────────────────┬───────────────┘
        #icrc1  │                       #icrc7  │
                ▼                               ▼
 ┌──────────────────────────┐      ┌──────────────────────────┐    ASSET LEDGERS
 │ ICRC-MENA                │      │ ICRC-7 / 37 land ledger  │    balances & titles
 │ cash + company shares    │      │ unique land titles       │
 │ (self-indexed)           │      │ (icrc7-land)             │
 └──────────────────────────┘      └──────────────────────────┘
 ┌─────────────────────────────────────────────────────────────┐
 │ Merkle-Mountain-Range audit trail · in-house SHA-256         │   AUDIT + CRYPTO
 │ (lib/crypto — no external cryptographic dependency)          │   verifiable, sovereign
 └─────────────────────────────────────────────────────────────┘
            all on Egypt-L1 — a Byzantine-fault-tolerant network
```

The crucial design choice is that **the settlement substrate is one small, heavily-proven core that
every market and every asset type reuses unchanged.** The matching engine and the listing registry
sit *on top* of it and hold no custody; the asset ledgers sit *under* it. Add a new asset type or a
new market and the both-or-neither guarantee comes for free — because it lives in one place that is
never modified.

---

## The components

Five cooperating parts. Each is explained twice: once in plain language, once under the hood.

### 1. The settlement core — `smart-contracts/dvp-core`

*Plain:* the part that makes "both or neither" true. It takes the asset from one party and the cash
from the other, holds both for an instant, and releases them to their new owners at the same time.
If either side fails to deliver in time, everything already collected is handed straight back.
Nobody is ever left half-paid.

*Under the hood:* a delivery-versus-payment state machine implementing **BIS DvP Model 1**
(trade-by-trade, gross, simultaneous final settlement). A trade has two legs — an asset leg and a
cash leg — and walks a strict lifecycle: `Open → Funded → Settled`, or `Open → Aborted` if the
funding deadline passes. It is **escrow-first**: both legs are pulled into the core's own account
*before* any payout, so a payout can never fail for allowance reasons and a transient ledger error
is safely retried rather than half-completing. Settlement is gated — payouts fire only once **both**
legs are escrowed (the "DvP gate"). The arithmetic and lifecycle gates live in a pure, side-effect-free
module (`DvpLogic.mo`) that is exhaustively unit-tested with no replica in the loop.

The hard problem in any settlement system is the *double-pay hazard*: a ledger commits a transfer,
the reply is lost, and a naive retry pays twice. The core defeats this with idempotent settlement —
each ledger call reuses a stable, monotonic `created_at_time`, so a true replay lands inside the
ledger's de-duplication window and returns `#Duplicate` instead of moving funds again. Five
invariants (`INV-DVP-1..5`) hold the line: conservation (the core's own balance returns to exactly
zero), the both-legs gate, single-resolution per leg (a leg is paid **or** refunded, never both),
absorbing terminal states, and idempotent retries. The leg model is ledger-agnostic — a leg
references any ICRC ledger and a kind (`#icrc1` fungible or `#icrc7` non-fungible) — and the state
machine never branches on kind, so the same proven core settles a share-for-cash trade and a
land-for-cash trade without change.

### 2. The matching engine — `smart-contracts/dvp-matching`

*Plain:* the trading floor for shares. Buyers and sellers post the price they want. At a fixed
rhythm the engine collects every order, finds the one fair price that clears the most trades, and
matches everyone at that single price. There is no advantage to being microseconds faster than the
next person.

*Under the hood:* a **frequent batch-auction CLOB** (continuous limit order book cleared in discrete
windows) with price-time priority and a uniform clearing price `p*`. Batch auctions are a deliberate
choice over continuous matching; they neutralise the latency races and front-running that plague
continuous books (Budish–Cramton–Shim, *"The High-Frequency Trading Arms Race"*). The engine holds
**no custody** — it is a pure orchestrator. Each match it produces is a settlement obligation
`(buyer, seller, price, qty)` that settles through the **unchanged** DvP core as one atomic trade
(seller = maker, buyer = taker). Clearing is resumable and chunked so a large window can't exceed the
per-message instruction budget; the eligible orders and `p*` are frozen at window close, so a chunked
clear reconstructs byte-for-byte identically to an unbounded reference run (this equivalence is a
property test). Measured ceiling: ~19,375 fills per clear message; the production cap is 4,000 for
headroom.

### 3. The listing registry — `smart-contracts/dvp-listing`

*Plain:* decides what is allowed to trade. A market operator approves trusted issuers; an approved
company can then list its own shares or land. The rule is simple: nothing is tradeable unless it is
real and funded — you cannot list a company that has issued no shares, or land with no registered
titles.

*Under the hood:* programmable compliance, on-chain. The venue admin authorizes issuers; an
authorized issuer lists its own asset. A share market is accepted only if the shares ledger reports
`icrc1_total_supply > 0` and the paired cash ledger answers `icrc1_fee` (proof it is a real ICRC
ledger); land is accepted only if the collection reports `icrc7_total_supply > 0`. The matching
engine consults `isPairTradeable` at order intake and RFQ clients consult `isLandTradeable`, so an
unregistered, unfunded, or delisted market accepts no orders. This gate is additive; it never
touches the settlement core.

### 4. ICRC-MENA — the self-indexed ledger (cash and shares) — `smart-contracts/icrc-mena`

*Plain:* the ledger that holds balances and records every movement of money or shares. What makes it
special: it keeps its own searchable history built in. On most chains you need a second, separate
service just to answer "show me this account's transactions"; here the ledger answers that itself,
and every answer comes with cryptographic proof it was not tampered with.

*Under the hood:* **ICRC-MENA** is a production-hardened, self-indexed ICRC-1 / ICRC-2 / ICRC-3 /
ICRC-10 token ledger that **eliminates the separate index canister** — every transfer atomically
updates a per-account transaction index inside the same canister. The stack is modular:
`Balances.mo` and `Allowances.mo`, an append-only hash-chained `BlockLog.mo` with a built-in account
index, a `CertifiedTree.mo` (IC-certified Merkle tree) so query results carry a verifiable witness, a
`MerkleMMR.mo` for compact inclusion proofs, and a Bloom-filter fast path for de-duplication.
Allowances and the block log are **Region-backed** (`RegionBTree` + `StableLog`) so the ledger scales
past heap limits and survives upgrades byte-for-byte. The digital cash (CBDC) and every company-share
ledger on the exchange are instances of ICRC-MENA.

### 5. ICRC-7 / ICRC-37 land ledger — `smart-contracts/icrc7-land`

*Plain:* the registry of land. Each parcel is a unique digital title with its own permanent
attributes. It can be owned, transferred, and — crucially — sold atomically for cash through the
same settlement core, so a land sale carries the exact same "both or neither" guarantee as a share
trade.

*Under the hood:* a spec-compliant **ICRC-7** (non-fungible token) plus **ICRC-37** (NFT approval)
land-title ledger. One parcel = one `token_id` plus immutable metadata. All registry logic lives in a
single tested module (`LandRegistry.mo`); the actor (`LandLedger.mo`) wires it to the exact ICRC-7/37
batch shapes. Transfer fee is zero because a title is indivisible — conservation here is "the unique
token moves exactly once," not arithmetic. The contribution is the **atomic-DvP-settleable NFT**: the
land ledger plugs into the DvP core's `#icrc7` leg, so a title and its purchase price change hands in
one indivisible settlement, with no escrow agent and no clearing delay.

### Running through everything — the audit trail and the crypto

Every settlement appends a leaf to a **Merkle Mountain Range** (`MerkleMMR.mo`). Anyone can re-derive
a leaf hash from the public encoded event and prove a given trade is included in the exchange's
history, without trusting the operator. *The exchange does not ask you to believe its records; it
lets you check them.* The hashing underneath is **in-house** (`smart-contracts/lib/crypto`): the
exchange carries **no external cryptographic dependency**, and the implementation is byte-identical
to the NIST SHA-256 test vectors (pinned by a known-answer test).

---

## Why you can trust it

- **Both-or-neither, structurally.** Escrow-first means the core holds both sides before paying
  either; a failure refunds, it never half-settles. This is enforced by invariants that *halt* on
  violation, not by convention.
- **No privileged custodian.** The matching engine and listing registry hold no funds; settlement
  destinations are predetermined, so the settlement entrypoints are permissionless among
  authenticated principals — no admin can redirect a payout.
- **Byzantine-fault-tolerant.** It runs on a BFT network: no single node can forge, reorder, or
  reverse a settled trade. Determinism is a property test — the same block produces the same state
  on every node.
- **Independently auditable.** The MMR root re-derives from the public event log; `examples/`
  ships the re-derivation tooling so a third party can verify history end to end.
- **Sovereign.** No external crypto library, no external index service, no off-chain clearing.

## How a trade flows

**A share trade.** Buyer and seller approve the exchange to move their cash / shares, then post
orders. At the next clearing window the matching engine fixes one fair price, produces a settlement
obligation, and the DvP core moves shares to the buyer and cash to the seller in one atomic step.

**A land sale.** A buyer and the title-holder agree terms (RFQ). The DvP core escrows the cash leg
(ICRC-MENA) and the title leg (ICRC-7), then releases both together. If either side does not fund by
the deadline, the funded side is refunded in full.

In both, the listing registry has already guaranteed the market is real and funded, and the MMR has
recorded the result for independent audit.

---

## Repository layout

```
mops.toml             dependency manifest (mo:core only — no external crypto dependency)
smart-contracts/
  dvp-core/           atomic DvP settlement core (BIS Model 1) + MMR audit trail
    src/              DvpCore, DvpLogic, DvpTypes, MerkleMMR, ICRC, ICRC7, Guards
    test/             pure-logic battery (dvp-logic.test.mo)
    thebes.toml.example
  dvp-matching/       frequent batch-auction CLOB; MatchLogic (pure), Matching (actor)
    src/  test/  thebes.toml.example
  dvp-listing/        issuer-gated listing registry (programmable compliance)
  icrc-mena/          ICRC-MENA self-indexed ICRC-1/2/3 ledger (cash + shares)
    src/  test/
  icrc7-land/         ICRC-7/37 land-title ledger (atomically DvP-settleable)
    src/  test/
  lib/crypto/         in-house SHA-256 (InPlaceSha256d + Sha256 shim) + known-answer test
examples/             three flagship flows + demo.env + audit helpers (parse_obl.py, mmr_rederive.py)
docs/                 frontend-integration-spec.md (the API boundary a frontend binds to)
```

## Build and test

- Tooling: `moc` with `mo:core`; `mops` for dependencies (`mops install`).
- **`mops test`** runs the full battery green: DvP conservation/idempotency, ICRC-7 land,
  matching-engine chunked-equals-unbounded equivalence, and the SHA-256 known-answer test.
- Deploy to an Egypt-L1 cluster with `thebes-deploy`: copy a `thebes.toml.example` to `thebes.toml`,
  set your validators / identity, `thebes-deploy build`, then `thebes-deploy deploy`.

## Status

The full exchange has run on Egypt-L1: settlement core, matching engine, listing registry, a CBDC
plus company-share ICRC-MENA ledgers, and the land ledger — seeded and query-verified end to end.
The settlement core was implemented once and has not changed since; every change ships behind a
green test battery.

---

## Standards & credits

This exchange speaks **open standards from the Internet Computer ecosystem** rather than inventing
its own wire formats. Credit for the standards belongs to their authors — the **ICRC working group**
and the **DFINITY Foundation / Internet Computer community**:

- **ICRC-1 / ICRC-2 / ICRC-3 / ICRC-10** — the fungible-token, approve & transfer-from, block-log,
  and supported-standards specifications. **ICRC-MENA is our *implementation* of these** (self-indexed,
  with the separate index canister eliminated); the standards themselves are the community's.
- **ICRC-7 / ICRC-37** — the non-fungible-token and NFT-approval specifications. The land ledger is a
  spec-compliant implementation; **our contribution is making an ICRC-7 token atomically
  DvP-settleable** through the core.

What is original here is the *composition* built on top of those open interfaces: the atomic DvP
settlement core, the frequent batch-auction CLOB, the self-indexed ICRC-MENA ledger, the
atomic-DvP-settleable land title, the in-house SHA-256, and the Byzantine-fault-tolerant substrate
they run on.

---

*Built by the Thebes core team. ICRC standards © the ICRC working group / DFINITY & the Internet Computer community.*
