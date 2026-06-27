/// ICRC.mo — ICRC-1/ICRC-2 ledger interface types
///
/// Matches the official Candid definitions exactly:
///   ICRC-1: https://github.com/dfinity/ICRC-1/blob/main/standards/ICRC-1/ICRC-1.did
///   ICRC-2: https://github.com/dfinity/ICRC-1/blob/main/standards/ICRC-2/ICRC-2.did

import Principal "mo:core/Principal";

module {

  public type Account = {
    owner : Principal;
    subaccount : ?Blob;
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-1 (Transfer)
  // ═══════════════════════════════════════════════════════

  public type TransferArgs = {
    from_subaccount : ?Blob;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferResult = { #Ok : Nat; #Err : TransferError };

  // ═══════════════════════════════════════════════════════
  //  ICRC-2 (Approve + TransferFrom)
  // ═══════════════════════════════════════════════════════

  public type ApproveArgs = {
    from_subaccount : ?Blob;
    spender : Account;
    amount : Nat;
    expected_allowance : ?Nat;
    expires_at : ?Nat64;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type ApproveError = {
    #BadFee : { expected_fee : Nat };
    #InsufficientFunds : { balance : Nat };
    #AllowanceChanged : { current_allowance : Nat };
    #Expired : { ledger_time : Nat64 };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type ApproveResult = { #Ok : Nat; #Err : ApproveError };

  public type TransferFromArgs = {
    spender_subaccount : ?Blob;
    from : Account;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferFromError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferFromResult = { #Ok : Nat; #Err : TransferFromError };

  // ═══════════════════════════════════════════════════════
  //  ICRC-2 (Allowance query)
  // ═══════════════════════════════════════════════════════

  public type AllowanceArgs = {
    account : Account;
    spender : Account;
  };

  public type Allowance = {
    allowance : Nat;
    expires_at : ?Nat64;
  };

  // ═══════════════════════════════════════════════════════
  //  LEDGER ACTOR INTERFACE
  // ═══════════════════════════════════════════════════════

  public type Ledger = actor {
    // ICRC-1
    icrc1_transfer : (TransferArgs) -> async TransferResult;
    icrc1_balance_of : (Account) -> async Nat;
    icrc1_fee : () -> async Nat;

    // ICRC-2
    icrc2_approve : (ApproveArgs) -> async ApproveResult;
    icrc2_transfer_from : (TransferFromArgs) -> async TransferFromResult;
    icrc2_allowance : (AllowanceArgs) -> async Allowance;
  };
};
