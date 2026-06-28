/// LandLedger.mo — spec-compliant ICRC-7 (NFT) + ICRC-37 (NFT approval) land-title ledger.
///
/// A parcel of land = one `token_id` + immutable metadata attributes. All registry logic
/// lives in `LandRegistry` (the single tested source of truth); this actor wires it to the
/// ICRC-7/37 endpoints with the exact batch `vec`/`vec opt Result` shapes. Transfer fee is
/// 0 (a title registry has no per-transfer fungible charge): an NFT is indivisible, so
/// `icrc7_transfer` carries no `fee` field and conservation is "the unique token moves
/// exactly once", not arithmetic.
///
/// This is the CLEAN production ledger. `FlakyLandLedger` is the same registry + a
/// controller-gated clean-transient injector used ONLY as a test fixture.

import Principal "mo:core/Principal";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Time "mo:core/Time";
import List "mo:core/List";
import Runtime "mo:core/Runtime";

import I "../../dvp-core/src/ICRC7";
import R "LandRegistry";

shared (initMsg) persistent actor class LandLedger(args : { name : Text; symbol : Text; description : ?Text }) = self {

  let st : R.State = R.newState();
  let tokenName = args.name;
  let tokenSymbol = args.symbol;
  let tokenDescription = args.description;
  let controller = initMsg.caller;

  func now() : Nat64 { Nat64.fromNat(Int.abs(Time.now())) };

  // ── ICRC-7 transfer (owner → recipient) ────────────────────────────────────────────────
  public shared ({ caller }) func icrc7_transfer(transferArgs : [I.TransferArg]) : async [?I.TransferResult] {
    let out = List.empty<?I.TransferResult>();
    let n = now();
    for (a in transferArgs.vals()) { List.add(out, ?R.transfer(st, caller, a, n)) };
    List.toArray(out);
  };

  // ── ICRC-37 transfer_from (approved spender pulls owner's token) ─────────────────────────
  public shared ({ caller }) func icrc37_transfer_from(tfArgs : [I.TransferFromArg]) : async [?I.TransferFromResult] {
    let out = List.empty<?I.TransferFromResult>();
    let n = now();
    for (a in tfArgs.vals()) { List.add(out, ?R.transferFrom(st, caller, a, n)) };
    List.toArray(out);
  };

  // ── ICRC-37 approvals ────────────────────────────────────────────────────────────────────
  public shared ({ caller }) func icrc37_approve_tokens(approveArgs : [I.ApproveTokenArg]) : async [?I.ApproveTokenResult] {
    let out = List.empty<?I.ApproveTokenResult>();
    let n = now();
    for (a in approveArgs.vals()) { List.add(out, ?R.approveToken(st, caller, a, n)) };
    List.toArray(out);
  };

  public shared ({ caller }) func icrc37_approve_collection(approveArgs : [I.ApproveCollectionArg]) : async [?I.ApproveCollectionResult] {
    let out = List.empty<?I.ApproveCollectionResult>();
    let n = now();
    for (a in approveArgs.vals()) { List.add(out, ?R.approveCollection(st, caller, a, n)) };
    List.toArray(out);
  };

  // ── ICRC-7 queries ───────────────────────────────────────────────────────────────────────
  public query func icrc7_owner_of(tokenIds : [Nat]) : async [?I.Account] {
    let out = List.empty<?I.Account>();
    for (id in tokenIds.vals()) { List.add(out, R.ownerOf(st, id)) };
    List.toArray(out);
  };

  public query func icrc7_balance_of(accounts : [I.Account]) : async [Nat] {
    let out = List.empty<Nat>();
    for (a in accounts.vals()) { List.add(out, R.balanceOf(st, a)) };
    List.toArray(out);
  };

  public query func icrc7_tokens(prev : ?Nat, take : ?Nat) : async [Nat] { R.tokens(st, prev, take) };

  public query func icrc7_tokens_of(account : I.Account, prev : ?Nat, take : ?Nat) : async [Nat] {
    R.tokensOf(st, account, prev, take);
  };

  public query func icrc7_token_metadata(tokenIds : [Nat]) : async [?[(Text, I.Value)]] {
    let out = List.empty<?[(Text, I.Value)]>();
    for (id in tokenIds.vals()) { List.add(out, R.metadataOf(st, id)) };
    List.toArray(out);
  };

  public query func icrc7_total_supply() : async Nat { R.totalSupply(st) };
  public query func icrc7_name() : async Text { tokenName };
  public query func icrc7_symbol() : async Text { tokenSymbol };
  public query func icrc7_description() : async ?Text { tokenDescription };

  // NFT transfer fee — none for a title registry (the indivisible token bears no fee).
  public query func icrc7_transfer_fee(_tokenId : Nat) : async ?Nat { ?0 };

  public query func icrc7_supported_standards() : async [{ name : Text; url : Text }] {
    [
      { name = "ICRC-7"; url = "https://github.com/dfinity/ICRC/tree/main/ICRCs/ICRC-7" },
      { name = "ICRC-37"; url = "https://github.com/dfinity/ICRC/tree/main/ICRCs/ICRC-37" },
    ];
  };

  // ── Admin: mint a parcel (controller-only; for test setup / registry bootstrap) ──────────
  public shared ({ caller }) func mint(to : I.Account, tokenId : Nat, meta : [(Text, I.Value)]) : async { #ok : Nat; #err : Text } {
    if (not Principal.equal(caller, controller)) Runtime.trap("only the registry controller may mint");
    R.mint(st, to, tokenId, meta, now());
  };

  // ── Diagnostics ──────────────────────────────────────────────────────────────────────────
  public query func registry_status() : async { total_tokens : Nat; total_txs : Nat } {
    { total_tokens = R.totalSupply(st); total_txs = st.nextTxId };
  };
};
