/// ICRC7.mo — ICRC-7 (NFT) + ICRC-37 (NFT approval) interface types.
///
/// Matches the canonical DFINITY Candid definitions verbatim (fetched this session):
///   ICRC-7:  https://raw.githubusercontent.com/dfinity/ICRC/main/ICRCs/ICRC-7/ICRC-7.did
///   ICRC-37: https://raw.githubusercontent.com/dfinity/ICRC/main/ICRCs/ICRC-37/ICRC-37.did
///
/// Both the land ledger (LandRegistry/LandLedger/FlakyLandLedger) and the DvP core's
/// `#icrc7` leg handler import these types. The `Ledger7` actor type is the surface the
/// DvP core calls to escrow (icrc37_transfer_from), pay out and refund (icrc7_transfer).
/// Note the batch shape: every transfer method takes a `vec` of args and returns a
/// `vec opt Result` — a single-token call sends a 1-element vec and reads element 0.

module {

  // Structurally identical to ICRC.Account / DvpTypes.Account (Motoko structural typing
  // makes them interchangeable on the call boundary).
  public type Account = { owner : Principal; subaccount : ?Blob };

  // ICRC-3 metadata value (reduced set sufficient for land-title attributes).
  public type Value = {
    #Nat : Nat;
    #Int : Int;
    #Text : Text;
    #Blob : Blob;
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-7 — transfer
  // ═══════════════════════════════════════════════════════

  public type TransferArg = {
    from_subaccount : ?Blob;
    to : Account;
    token_id : Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferError = {
    #NonExistingTokenId;
    #InvalidRecipient;
    #Unauthorized;
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #GenericError : { error_code : Nat; message : Text };
    #GenericBatchError : { error_code : Nat; message : Text };
  };

  public type TransferResult = { #Ok : Nat; #Err : TransferError };

  // ═══════════════════════════════════════════════════════
  //  ICRC-37 — transfer_from
  // ═══════════════════════════════════════════════════════

  public type TransferFromArg = {
    spender_subaccount : ?Blob;
    from : Account;
    to : Account;
    token_id : Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferFromError = {
    #InvalidRecipient;
    #Unauthorized;
    #NonExistingTokenId;
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #GenericError : { error_code : Nat; message : Text };
    #GenericBatchError : { error_code : Nat; message : Text };
  };

  public type TransferFromResult = { #Ok : Nat; #Err : TransferFromError };

  // ═══════════════════════════════════════════════════════
  //  ICRC-37 — approvals
  // ═══════════════════════════════════════════════════════

  public type ApprovalInfo = {
    spender : Account;
    from_subaccount : ?Blob;
    expires_at : ?Nat64;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type ApproveTokenArg = {
    token_id : Nat;
    approval_info : ApprovalInfo;
  };

  public type ApproveTokenError = {
    #InvalidSpender;
    #Unauthorized;
    #NonExistingTokenId;
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #GenericError : { error_code : Nat; message : Text };
    #GenericBatchError : { error_code : Nat; message : Text };
  };

  public type ApproveTokenResult = { #Ok : Nat; #Err : ApproveTokenError };

  public type ApproveCollectionArg = {
    approval_info : ApprovalInfo;
  };

  public type ApproveCollectionError = {
    #InvalidSpender;
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #GenericError : { error_code : Nat; message : Text };
    #GenericBatchError : { error_code : Nat; message : Text };
  };

  public type ApproveCollectionResult = { #Ok : Nat; #Err : ApproveCollectionError };

  // ═══════════════════════════════════════════════════════
  //  LEDGER ACTOR INTERFACE (what the DvP core calls)
  // ═══════════════════════════════════════════════════════

  public type Ledger7 = actor {
    // ICRC-7 — escrowed-token payout / refund (core is the current owner)
    icrc7_transfer : ([TransferArg]) -> async [?TransferResult];
    icrc7_owner_of : ([Nat]) -> async [?Account];
    // ICRC-37 — escrow pull (core is the approved spender)
    icrc37_transfer_from : ([TransferFromArg]) -> async [?TransferFromResult];
  };
};
