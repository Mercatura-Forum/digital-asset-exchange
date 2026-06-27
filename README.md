# Digital Asset Exchange

A sovereign exchange where cash, company shares, and land titles change hands in a single,
indivisible step. The two halves of a trade either both happen or neither does; there is no
moment where one party has given and the other has not yet paid.

It runs entirely on Egypt-L1, a Byzantine-fault-tolerant network. No clearing house sits in the
middle. No single server can be bribed, hacked, or switched off to reverse a settled trade.

*Most markets settle in days through a chain of intermediaries; this one settles in one step, with no intermediary at all.*

---

## In one minute (for everyone)

Buying a share or a plot of land today is a relay race: you pay, a broker confirms, a custodian
moves the asset, a clearing house reconciles, and days later the trade is "final." Every handoff
is a place where things stall, where one side is exposed, where a keeper must be trusted.

This exchange removes the relay. When a buyer and a seller agree, the cash and the asset move
**together**, in the same operation, verified by a network of independent machines that must all
agree before anything is written down. The instant it is written, it is final and cannot be undone.

Three kinds of things trade here:

- **Cash** — a digital currency (a CBDC-style token).
- **Company shares** — fungible ownership in a company.
- **Land titles** — unique, one-of-a-kind property deeds.

The same settlement guarantee covers all three.

---

## The systems we are committing

The backend is five cooperating parts. Each is explained twice below: once in plain language,
once under the hood.

### 1. The settlement core — `dvp-core`

This is the part that makes "both or neither" true. It takes the asset from
one party and the cash from the other, holds both for an instant, and releases them to their new
owners at the same time. If either side fails to deliver in time, everything already collected is
handed straight back. Nobody is ever left half-paid.

A delivery-versus-payment state machine implementing **BIS DvP Model 1**
(trade-by-trade, gross, simultaneous final settlement). A trade has two legs — an asset leg and a
cash leg — and walks a strict lifecycle: `Open → Funded → Settled`, or `Open → Aborted` if the
funding deadline passes. Settlement is gated: payouts can only fire once **both** legs are escrowed
(the "DvP gate"). The arithmetic and the lifecycle gates live in a pure, side-effect-free module
(`DvpLogic.mo`) that is exhaustively unit-tested with no replica in the loop.

The hard problem in any settlement system is the *double-pay hazard*: a ledger commits a transfer,
then the reply is lost, and a naive retry pays twice. The core defeats this with idempotent
settlement; each ledger call reuses a stable, monotonic `created_at_time`, so a true replay lands
inside the ledger's de-duplication window and returns `#Duplicate` instead of moving funds again.
Five invariants (`INV-DVP-1..5`) hold the line: conservation (the core's own balance returns to
exactly zero), the both-legs gate, single-resolution per leg (a leg is paid **or** refunded, never
both), absorbing terminal states, and idempotent retries.

The leg model is ledger-agnostic: a leg references any ICRC ledger and a kind (`#icrc1` fungible or
`#icrc7` non-fungible). The state machine never branches on kind; only the dispatch layer does, so
the same proven core settles a share-for-cash trade and a land-for-cash trade without change.

### 2. The matching engine — `dvp-matching`

This is the trading floor for shares. Buyers and sellers post the price they
want. At a fixed rhythm the engine collects every order, finds the one fair price that clears the
most trades, and matches everyone at that single price. There is no advantage to being microseconds
faster than the next person.

A **frequent batch-auction CLOB** (continuous limit order book cleared in
discrete windows) with price-time priority and a uniform clearing price `p*`. Batch auctions are a
deliberate choice over continuous matching; they neutralise the latency races and front-running that
plague continuous books (see Budish-Cramton-Shim, *"The High-Frequency Trading Arms Race"*). The
engine holds **no custody**: it is a pure orchestrator. Each match it produces is a settlement
obligation `(buyer, seller, price, qty)` that settles through the **unchanged** DvP core as one
atomic trade (seller = maker, buyer = taker). Clearing is resumable and chunked so a large window
cannot exceed the per-message budget; the eligible orders and `p*` are frozen at window close, so a
chunked clear reconstructs byte-for-byte identically to an unbounded reference run. Measured ceiling:
~19,375 fills per clear message; the production cap is set to 4,000 for headroom.

### 3. The listing registry — `dvp-listing`

This decides what is allowed to trade. A market operator approves trusted
issuers; an approved company can then list its own shares or land. The rule it enforces is simple:
nothing is tradeable unless it is real and funded. You cannot list a company that has issued no
shares, or land that has no registered titles.

Programmable compliance, on-chain. The venue admin (the installer) authorizes
issuers; an authorized issuer lists its own asset. Listing a share market is accepted only if the
shares ledger reports `icrc1_total_supply > 0` and the paired cash ledger answers `icrc1_fee` (proof
it is a real ICRC ledger); listing land is accepted only if the collection reports
`icrc7_total_supply > 0`. The matching engine consults `isPairTradeable` at order intake and RFQ
clients consult `isLandTradeable`, so an unregistered, unfunded, or delisted market accepts no
orders. This is an additive gate; it never touches the byte-frozen settlement core.

### 4. ICRC-MENA — the self-indexed ledger (cash and shares)

This is the ledger that holds balances and records every movement of money or
shares. What makes it special: it keeps its own searchable history built in. On most blockchains you
need a second, separate service just to answer "show me this account's transactions"; here the ledger
answers that itself, and every answer comes with cryptographic proof that it was not tampered with.

**ICRC-MENA** (formerly ICRC-ME) is our production-hardened, self-indexed
ICRC-1 / ICRC-2 / ICRC-3 / ICRC-10 token ledger. *First on ICP to eliminate the separate index
canister:* every transfer atomically updates a per-account transaction index inside the same
canister. The stack is modular: `Balances.mo` and `Allowances.mo` (ports of DFINITY's `balances.rs`
/ `approvals.rs`), an append-only hash-chained `BlockLog.mo` with a built-in account index, a
`CertifiedTree.mo` (IC-certified Merkle tree) so query results carry a verifiable witness, a
`MerkleMMR.mo` for compact inclusion proofs, and a Bloom-filter fast path for de-duplication.
Allowances and the block log are **Region-backed** (`RegionBTree` + `StableLog`) so the ledger scales
past heap limits and survives upgrades byte-for-byte. The digital cash (CBDC) and every company share
ledger on the exchange are instances of ICRC-MENA.

### 5. ICRC-7 / ICRC-37 land ledger — `dvp-core/src/land`

This is the registry of land. Each parcel is a unique digital title with its own
permanent attributes. It can be owned, transferred, and — crucially — sold atomically for cash
through the same settlement core, so a land sale carries the exact same "both or neither" guarantee
as a share trade.

A spec-compliant **ICRC-7** (non-fungible token) plus **ICRC-37** (NFT approval)
land-title ledger. One parcel = one `token_id` plus immutable metadata. All registry logic lives in a
single tested module (`LandRegistry.mo`); the actor (`LandLedger.mo`) wires it to the exact ICRC-7/37
batch shapes. Transfer fee is zero because a title is indivisible — conservation here is "the unique
token moves exactly once," not arithmetic. Our contribution is the **atomic-DvP-settleable NFT**: the
land ledger plugs into the DvP core's `#icrc7` leg, so a title and its purchase price change hands in
one indivisible settlement, with no escrow agent and no clearing delay.

### Running through everything — the audit trail

Every settlement appends a leaf to a **Merkle Mountain Range** (`MerkleMMR.mo`). Anyone can
re-derive a leaf hash from the public encoded event and prove a given trade is included in the
exchange's history, without trusting the operator. *The exchange does not ask you to believe its
records; it lets you check them.*

---

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
mops.toml          dependency manifest (core, sha2)
smart-contracts/
  dvp-core/        DvP atomic-swap settlement core (BIS Model 1) + land ledger + MMR audit
    src/           DvpCore, DvpLogic, DvpTypes, MerkleMMR, ICRC7, Guards
    src/land/      LandLedger (ICRC-7/37), LandRegistry
    fixtures/ledger/  ICRC-MENA self-indexed ledger stack (IndexedLedger + modules)
    test/          pure-logic + ICRC-7 batteries (mops test --mode interpreter)
    thebes.toml.example   sample deploy manifest (copy to thebes.toml)
  dvp-matching/    frequent batch-auction CLOB; MatchLogic (pure), Matching (actor)
    src/  test/  thebes.toml.example
  dvp-listing/     issuer-gated listing registry (programmable compliance)
examples/          three flagship flows + demo.env + audit helpers (parse_obl.py, mmr_rederive.py)
docs/              frontend-integration-spec.md (the boundary the showcase frontend binds to)
```

The showcase frontend lives in a separate tree and is committed alongside in a follow-on change;
`docs/frontend-integration-spec.md` is the contract it binds to.

## Build and test

- Tooling: `moc` with `mo:core`; `mops` for dependencies (`mops install`).
- Pure-logic batteries (`DvpLogic`, `MatchLogic`) run with no replica: `mops test --mode interpreter`.
- Deploy to an Egypt-L1 cluster with `thebes-deploy`: copy a `thebes.toml.example` to `thebes.toml`,
  set your validators / identity, `thebes-deploy build`, then `thebes-deploy deploy`.

## Status

The full exchange is live on Egypt-L1 production (chain_id 2026): settlement core, matching engine,
listing registry, the CBDC and six company-share ICRC-MENA ledgers, and the land ledger, all seeded
and query-verified. The settlement core is byte-frozen and unchanged across every later phase.

---

*Authored by the Menese DeFi Team for Mercatura Forum.*
