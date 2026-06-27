/// FlakyLandLedger.mo — the LandLedger registry + a controller-gated clean-transient fault
/// injector on icrc7_transfer. THROWAWAY TEST FIXTURE ONLY (mission L3): it drives the DvP
/// core's idempotent-retry path for the NFT payout leg.
///
/// The injected failure returns `#Err(#GenericError)` BEFORE any state change or dedup record
/// (ICRC-7's TransferError has no TemporarilyUnavailable variant), so it is a genuine clean
/// transient — a re-driven settle re-sends normally and the token moves EXACTLY once. This is
/// NOT a stub of the DvP core (which stays pristine) and NOT a stub of the registry (identical
/// LandRegistry logic): only the injector line differs from the clean LandLedger.

import Principal "mo:core/Principal";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Time "mo:core/Time";
import List "mo:core/List";
import Runtime "mo:core/Runtime";

import I "../ICRC7";
import R "LandRegistry";

shared (initMsg) persistent actor class FlakyLandLedger(args : { name : Text; symbol : Text; description : ?Text }) = self {

  let st : R.State = R.newState();
  let tokenName = args.name;
  let tokenSymbol = args.symbol;
  let tokenDescription = args.description;
  let controller = initMsg.caller;

  // L3 fault injection: the next N icrc7_transfer calls return #GenericError (clean, no commit)
  // before falling through to normal behavior.
  var failTransfersRemaining : Nat = 0;

  public shared ({ caller }) func set_fail_next(n : Nat) : async () {
    if (not Principal.equal(caller, controller)) Runtime.trap("only the registry controller may inject faults");
    failTransfersRemaining := n;
  };
  public query func fail_next_remaining() : async Nat { failTransfersRemaining };

  func now() : Nat64 { Nat64.fromNat(Int.abs(Time.now())) };

  public shared ({ caller }) func icrc7_transfer(transferArgs : [I.TransferArg]) : async [?I.TransferResult] {
    // Clean-transient injection — fire BEFORE any state/dedup mutation so a retry re-sends.
    if (failTransfersRemaining > 0) {
      failTransfersRemaining -= 1;
      let out = List.empty<?I.TransferResult>();
      for (_ in transferArgs.vals()) {
        List.add(out, ?(#Err(#GenericError({ error_code = 999; message = "injected transient (test fixture)" }))));
      };
      return List.toArray(out);
    };
    let out = List.empty<?I.TransferResult>();
    let n = now();
    for (a in transferArgs.vals()) { List.add(out, ?R.transfer(st, caller, a, n)) };
    List.toArray(out);
  };

  public shared ({ caller }) func icrc37_transfer_from(tfArgs : [I.TransferFromArg]) : async [?I.TransferFromResult] {
    let out = List.empty<?I.TransferFromResult>();
    let n = now();
    for (a in tfArgs.vals()) { List.add(out, ?R.transferFrom(st, caller, a, n)) };
    List.toArray(out);
  };

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
  public query func icrc7_tokens_of(account : I.Account, prev : ?Nat, take : ?Nat) : async [Nat] { R.tokensOf(st, account, prev, take) };

  public query func icrc7_token_metadata(tokenIds : [Nat]) : async [?[(Text, I.Value)]] {
    let out = List.empty<?[(Text, I.Value)]>();
    for (id in tokenIds.vals()) { List.add(out, R.metadataOf(st, id)) };
    List.toArray(out);
  };

  public query func icrc7_total_supply() : async Nat { R.totalSupply(st) };
  public query func icrc7_name() : async Text { tokenName };
  public query func icrc7_symbol() : async Text { tokenSymbol };
  public query func icrc7_description() : async ?Text { tokenDescription };
  public query func icrc7_transfer_fee(_tokenId : Nat) : async ?Nat { ?0 };

  public query func icrc7_supported_standards() : async [{ name : Text; url : Text }] {
    [
      { name = "ICRC-7"; url = "https://github.com/dfinity/ICRC/tree/main/ICRCs/ICRC-7" },
      { name = "ICRC-37"; url = "https://github.com/dfinity/ICRC/tree/main/ICRCs/ICRC-37" },
    ];
  };

  public shared ({ caller }) func mint(to : I.Account, tokenId : Nat, meta : [(Text, I.Value)]) : async { #ok : Nat; #err : Text } {
    if (not Principal.equal(caller, controller)) Runtime.trap("only the registry controller may mint");
    R.mint(st, to, tokenId, meta, now());
  };

  public query func registry_status() : async { total_tokens : Nat; total_txs : Nat } {
    { total_tokens = R.totalSupply(st); total_txs = st.nextTxId };
  };
};
