/// ListingRegistry.mo — issuer-gated listing venue for the DvP digital-asset exchange.
///
/// The on-chain source of truth for "what is tradeable". Two asset classes:
///   • fungible SHARES (ICRC-1/2), paired with a CBDC cash ledger → traded on a matching engine
///   • non-fungible LAND collections (ICRC-7) → traded by RFQ / atomic DvP through the core
///
/// Trust model (programmable compliance — differentiator #5): a venue `admin` (the installer)
/// vets and authorizes issuers; an authorized ISSUER lists its own asset. The INVARIANT
/// "only a registered, FUNDED ledger is tradeable" is enforced HERE:
///   - registration is gated to authorized issuers (`requireIssuer`);
///   - a share listing is accepted ONLY if the ledger reports `icrc1_total_supply > 0` (real
///     issued supply) AND the paired cash ledger answers `icrc1_fee` (a real ICRC ledger);
///   - a land listing is accepted ONLY if the collection reports `icrc7_total_supply > 0`.
/// The matching engine consults `isPairTradeable` at order intake; an unregistered/unfunded/
/// delisted market accepts no orders. RFQ/land clients consult `isLandTradeable`.
///
/// This is an additive venue layer: it does NOT touch the DvP core or the proven
/// matching/clearing logic — it gates intake only.

import Principal "mo:core/Principal";
import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";

shared (install) persistent actor class ListingRegistry() = self {

  // The venue operator (installer). Authorizes issuers; can delist.
  transient let admin : Principal = install.caller;

  // Minimal ledger interfaces for the funded-check (only the read methods we need).
  type FungibleLedger = actor { icrc1_total_supply : () -> async Nat; icrc1_fee : () -> async Nat };
  type Icrc7Ledger = actor { icrc7_total_supply : () -> async Nat };

  type Status = { #Listed; #Delisted };
  type ShareListing = {
    shares : Principal;
    cash : Principal;
    issuer : Principal;
    supplyAtListing : Nat;       // icrc1_total_supply observed at listing (audit)
    var status : Status;
  };
  type LandListing = {
    land : Principal;
    issuer : Principal;
    supplyAtListing : Nat;       // icrc7_total_supply observed at listing
    var status : Status;
  };

  // Authorized issuers.
  let issuers = Map.empty<Principal, Bool>();
  // Share listings keyed by the shares ledger principal (one company ledger = one listing).
  let shareListings = Map.empty<Principal, ShareListing>();
  // Land listings keyed by the land collection principal.
  let landListings = Map.empty<Principal, LandListing>();

  func requireAuth(c : Principal) { if (Principal.isAnonymous(c)) Runtime.trap("anonymous principal not allowed") };
  func isAdmin(c : Principal) : Bool { Principal.equal(c, admin) };
  func isIssuerP(c : Principal) : Bool { switch (Map.get(issuers, Principal.compare, c)) { case (?b) b; case null false } };

  // ── Admin: authorize / revoke issuers (the venue's listing committee) ─────────────────────────
  public shared ({ caller }) func registerIssuer(p : Principal) : async Result.Result<Text, Text> {
    requireAuth(caller);
    if (not isAdmin(caller)) return #err("only the venue admin may authorize issuers");
    Map.add(issuers, Principal.compare, p, true);
    #ok("issuer authorized: " # Principal.toText(p))
  };
  public shared ({ caller }) func revokeIssuer(p : Principal) : async Result.Result<Text, Text> {
    requireAuth(caller);
    if (not isAdmin(caller)) return #err("only the venue admin may revoke issuers");
    Map.add(issuers, Principal.compare, p, false);
    #ok("issuer revoked: " # Principal.toText(p))
  };

  // ── Issuer: list a fungible SHARE market (shares paired with a cash ledger) ────────────────────
  // INVARIANT enforced: caller is an authorized issuer AND the shares ledger is FUNDED
  // (icrc1_total_supply > 0) AND the cash ledger is a real ICRC ledger (answers icrc1_fee).
  public shared ({ caller }) func listShare(shares : Principal, cash : Principal) : async Result.Result<Text, Text> {
    requireAuth(caller);
    if (not isIssuerP(caller)) return #err("caller is not an authorized issuer");
    if (Principal.equal(shares, cash)) return #err("shares and cash ledgers must differ");
    let sl : FungibleLedger = actor (Principal.toText(shares));
    let cl : FungibleLedger = actor (Principal.toText(cash));
    let supply = try { await sl.icrc1_total_supply() } catch (_) { return #err("shares ledger unreachable / not ICRC-1") };
    if (supply == 0) return #err("shares ledger is not funded (total_supply == 0) — mint shares before listing");
    let _cashFee = try { await cl.icrc1_fee() } catch (_) { return #err("cash ledger unreachable / not ICRC-1") };
    let listing : ShareListing = { shares; cash; issuer = caller; supplyAtListing = supply; var status = #Listed };
    Map.add(shareListings, Principal.compare, shares, listing);
    #ok("share market listed: " # Principal.toText(shares) # " / " # Principal.toText(cash) # " (supply " # Nat.toText(supply) # ")")
  };

  // ── Issuer: list a LAND collection for RFQ / atomic DvP ───────────────────────────────────────
  public shared ({ caller }) func listLandCollection(land : Principal) : async Result.Result<Text, Text> {
    requireAuth(caller);
    if (not isIssuerP(caller)) return #err("caller is not an authorized issuer");
    let ll : Icrc7Ledger = actor (Principal.toText(land));
    let supply = try { await ll.icrc7_total_supply() } catch (_) { return #err("land ledger unreachable / not ICRC-7") };
    if (supply == 0) return #err("land collection has no minted titles (icrc7_total_supply == 0)");
    let listing : LandListing = { land; issuer = caller; supplyAtListing = supply; var status = #Listed };
    Map.add(landListings, Principal.compare, land, listing);
    #ok("land collection listed: " # Principal.toText(land) # " (titles " # Nat.toText(supply) # ")")
  };

  // ── Admin: delist (status flip; the listing record is retained for audit) ──────────────────────
  public shared ({ caller }) func delistShare(shares : Principal) : async Result.Result<Text, Text> {
    requireAuth(caller);
    if (not isAdmin(caller)) return #err("only the venue admin may delist");
    switch (Map.get(shareListings, Principal.compare, shares)) {
      case (?l) { l.status := #Delisted; #ok("share market delisted") };
      case null #err("no such share listing");
    };
  };
  public shared ({ caller }) func delistLand(land : Principal) : async Result.Result<Text, Text> {
    requireAuth(caller);
    if (not isAdmin(caller)) return #err("only the venue admin may delist");
    switch (Map.get(landListings, Principal.compare, land)) {
      case (?l) { l.status := #Delisted; #ok("land collection delisted") };
      case null #err("no such land listing");
    };
  };

  // ── Tradeability queries (the engine gate + RFQ clients consult these) ─────────────────────────
  public query func isPairTradeable(shares : Principal, cash : Principal) : async Bool {
    switch (Map.get(shareListings, Principal.compare, shares)) {
      case (?l) (l.status == #Listed) and Principal.equal(l.cash, cash);
      case null false;
    };
  };
  public query func isLandTradeable(land : Principal) : async Bool {
    switch (Map.get(landListings, Principal.compare, land)) {
      case (?l) l.status == #Listed;
      case null false;
    };
  };

  // Live funded re-verification (auditable): re-reads icrc1_total_supply for a listed share market.
  public shared func verifyShareFunded(shares : Principal) : async Result.Result<Nat, Text> {
    switch (Map.get(shareListings, Principal.compare, shares)) {
      case null #err("no such share listing");
      case (?l) {
        let sl : FungibleLedger = actor (Principal.toText(l.shares));
        let supply = try { await sl.icrc1_total_supply() } catch (_) { return #err("shares ledger unreachable") };
        if (supply == 0) #err("NOT FUNDED — total_supply == 0") else #ok(supply);
      };
    };
  };

  // ── Views ─────────────────────────────────────────────────────────────────────────────────────
  type ShareListingView = { shares : Principal; cash : Principal; issuer : Principal; supplyAtListing : Nat; status : Status };
  type LandListingView = { land : Principal; issuer : Principal; supplyAtListing : Nat; status : Status };

  public query func adminPrincipal() : async Principal { admin };
  public query func isAuthorizedIssuer(p : Principal) : async Bool { isIssuerP(p) };
  public query func shareListingsView() : async [ShareListingView] {
    let out = List.empty<ShareListingView>();
    for ((_, l) in Map.entries(shareListings)) List.add(out, { shares = l.shares; cash = l.cash; issuer = l.issuer; supplyAtListing = l.supplyAtListing; status = l.status });
    List.toArray(out)
  };
  public query func landListingsView() : async [LandListingView] {
    let out = List.empty<LandListingView>();
    for ((_, l) in Map.entries(landListings)) List.add(out, { land = l.land; issuer = l.issuer; supplyAtListing = l.supplyAtListing; status = l.status });
    List.toArray(out)
  };
};
