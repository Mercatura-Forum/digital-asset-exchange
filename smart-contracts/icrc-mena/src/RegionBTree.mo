/// RegionBTree.mo -- fixed-size B-tree in Region stable memory.
///
/// This is the Region-backed sorted map used by the ledger for data that must
/// stay out of GC-visible heap. It supports lookup and insert/update. Deletion
/// is modeled by callers with tombstone values.

import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Blob "mo:core/Blob";
import Region "mo:core/Region";
import Runtime "mo:core/Runtime";
import Order "mo:core/Order";

module {

  let PAGE_SIZE : Nat64 = 8192;
  let KEY_SIZE : Nat = 124;
  let VAL_SIZE : Nat = 8;
  let ENTRY_SIZE : Nat = 132;
  let CHILD_PTR : Nat = 6;

  let LEAF_CAP : Nat = 62;
  let INTERNAL_CAP : Nat = 62;

  let NODE_LEAF : Nat8 = 0;
  let NODE_INTERNAL : Nat8 = 1;
  let NULL_NODE : Nat64 = 0xFFFF_FFFF_FFFF;

  public type State = {
    region : Region.Region;
    var root : Nat64;
    var nodeCount : Nat64;
    var entryCount : Nat;
  };

  public func newState() : State {
    {
      region = Region.new();
      var root : Nat64 = NULL_NODE;
      var nodeCount : Nat64 = 0;
      var entryCount : Nat = 0;
    }
  };

  func growIfNeeded(state : State, needed : Nat64) {
    let pages = (needed / 65536) + 1;
    let have = Region.size(state.region);
    if (pages > have) {
      let g = Region.grow(state.region, pages - have);
      if (g == 0xFFFF_FFFF_FFFF_FFFF) Runtime.trap("RegionBTree: memory exhausted");
    };
  };

  func allocNode(state : State, nodeType : Nat8) : Nat64 {
    let off = state.nodeCount * PAGE_SIZE;
    state.nodeCount += 1;
    growIfNeeded(state, state.nodeCount * PAGE_SIZE);
    Region.storeNat8(state.region, off, nodeType);
    Region.storeNat16(state.region, off + 1, 0);
    off
  };

  func nodeType(state : State, node : Nat64) : Nat8 {
    Region.loadNat8(state.region, node)
  };

  func nodeEntryCount(state : State, node : Nat64) : Nat {
    Nat16.toNat(Region.loadNat16(state.region, node + 1))
  };

  func setNodeEntryCount(state : State, node : Nat64, count : Nat) {
    Region.storeNat16(state.region, node + 1, Nat16.fromNat(count));
  };

  func leafKeyOff(node : Nat64, idx : Nat) : Nat64 {
    node + 3 + Nat64.fromNat(idx * ENTRY_SIZE)
  };

  func leafKey(state : State, node : Nat64, idx : Nat) : Blob {
    Region.loadBlob(state.region, leafKeyOff(node, idx), KEY_SIZE)
  };

  func leafVal(state : State, node : Nat64, idx : Nat) : Blob {
    Region.loadBlob(state.region, leafKeyOff(node, idx) + Nat64.fromNat(KEY_SIZE), VAL_SIZE)
  };

  func setLeafEntry(state : State, node : Nat64, idx : Nat, key : Blob, val : Blob) {
    assert key.size() == KEY_SIZE;
    assert val.size() == VAL_SIZE;
    Region.storeBlob(state.region, leafKeyOff(node, idx), key);
    Region.storeBlob(state.region, leafKeyOff(node, idx) + Nat64.fromNat(KEY_SIZE), val);
  };

  func internalChildOff(node : Nat64, idx : Nat) : Nat64 {
    node + 3 + Nat64.fromNat(idx * CHILD_PTR)
  };

  func internalKeyOff(node : Nat64, idx : Nat) : Nat64 {
    node + 3 + Nat64.fromNat((INTERNAL_CAP + 1) * CHILD_PTR) + Nat64.fromNat(idx * KEY_SIZE)
  };

  func getChild(state : State, node : Nat64, idx : Nat) : Nat64 {
    let off = internalChildOff(node, idx);
    let lo = Nat32.toNat(Region.loadNat32(state.region, off));
    let hi = Nat16.toNat(Region.loadNat16(state.region, off + 4));
    Nat64.fromNat(lo + hi * 4294967296)
  };

  func setChild(state : State, node : Nat64, idx : Nat, child : Nat64) {
    let off = internalChildOff(node, idx);
    Region.storeNat32(state.region, off, Nat32.fromNat(Nat64.toNat(child) % 4294967296));
    Region.storeNat16(state.region, off + 4, Nat16.fromNat(Nat64.toNat(child) / 4294967296));
  };

  func internalKey(state : State, node : Nat64, idx : Nat) : Blob {
    Region.loadBlob(state.region, internalKeyOff(node, idx), KEY_SIZE)
  };

  func setInternalKey(state : State, node : Nat64, idx : Nat, key : Blob) {
    assert key.size() == KEY_SIZE;
    Region.storeBlob(state.region, internalKeyOff(node, idx), key);
  };

  func compareKeys(a : Blob, b : Blob) : Order.Order {
    Blob.compare(a, b)
  };

  func leafSearch(state : State, node : Nat64, key : Blob) : (Nat, Bool) {
    let count = nodeEntryCount(state, node);
    if (count == 0) return (0, false);
    var lo = 0;
    var hi = count;
    while (lo < hi) {
      let mid = (lo + hi) / 2;
      switch (compareKeys(leafKey(state, node, mid), key)) {
        case (#less) { lo := mid + 1 };
        case (#equal) { return (mid, true) };
        case (#greater) { hi := mid };
      };
    };
    (lo, false)
  };

  func internalSearch(state : State, node : Nat64, key : Blob) : Nat {
    let count = nodeEntryCount(state, node);
    var lo = 0;
    var hi = count;
    while (lo < hi) {
      let mid = (lo + hi) / 2;
      switch (compareKeys(internalKey(state, node, mid), key)) {
        case (#less) { lo := mid + 1 };
        case (#equal) { return mid + 1 };
        case (#greater) { hi := mid };
      };
    };
    lo
  };

  func shiftLeafRight(state : State, node : Nat64, from : Nat, count : Nat) {
    var i = count;
    while (i > from) {
      let src = leafKeyOff(node, i - 1);
      let dst = leafKeyOff(node, i);
      let entry = Region.loadBlob(state.region, src, ENTRY_SIZE);
      Region.storeBlob(state.region, dst, entry);
      i -= 1;
    };
  };

  func shiftInternalRight(state : State, node : Nat64, from : Nat, count : Nat) {
    var i = count;
    while (i > from) {
      let srcKey = internalKeyOff(node, i - 1);
      let dstKey = internalKeyOff(node, i);
      Region.storeBlob(state.region, dstKey, Region.loadBlob(state.region, srcKey, KEY_SIZE));
      let srcChild = internalChildOff(node, i);
      let dstChild = internalChildOff(node, i + 1);
      Region.storeBlob(state.region, dstChild, Region.loadBlob(state.region, srcChild, CHILD_PTR));
      i -= 1;
    };
  };

  type SplitResult = { medianKey : Blob; rightNode : Nat64 };

  func splitLeaf(state : State, node : Nat64) : SplitResult {
    let count = nodeEntryCount(state, node);
    let mid = count / 2;
    let right = allocNode(state, NODE_LEAF);
    var i = mid;
    var ri = 0;
    while (i < count) {
      let entry = Region.loadBlob(state.region, leafKeyOff(node, i), ENTRY_SIZE);
      Region.storeBlob(state.region, leafKeyOff(right, ri), entry);
      i += 1;
      ri += 1;
    };
    setNodeEntryCount(state, right, count - mid);
    setNodeEntryCount(state, node, mid);
    { medianKey = leafKey(state, right, 0); rightNode = right }
  };

  func splitInternal(state : State, node : Nat64) : SplitResult {
    let count = nodeEntryCount(state, node);
    let mid = count / 2;
    let right = allocNode(state, NODE_INTERNAL);
    let median = internalKey(state, node, mid);

    var i = mid + 1;
    var ri = 0;
    while (i < count) {
      setInternalKey(state, right, ri, internalKey(state, node, i));
      i += 1;
      ri += 1;
    };

    i := mid + 1;
    ri := 0;
    while (i <= count) {
      setChild(state, right, ri, getChild(state, node, i));
      i += 1;
      ri += 1;
    };

    setNodeEntryCount(state, right, count - mid - 1);
    setNodeEntryCount(state, node, mid);
    { medianKey = median; rightNode = right }
  };

  public func get(state : State, key : Blob) : ?Blob {
    assert key.size() == KEY_SIZE;
    var node = state.root;
    while (node != NULL_NODE) {
      if (nodeType(state, node) == NODE_LEAF) {
        let (idx, found) = leafSearch(state, node, key);
        if (found) return ?leafVal(state, node, idx);
        return null;
      };
      node := getChild(state, node, internalSearch(state, node, key));
    };
    null
  };

  public func put(state : State, key : Blob, val : Blob) : ?Blob {
    assert key.size() == KEY_SIZE;
    assert val.size() == VAL_SIZE;
    if (state.root == NULL_NODE) {
      let root = allocNode(state, NODE_LEAF);
      setLeafEntry(state, root, 0, key, val);
      setNodeEntryCount(state, root, 1);
      state.root := root;
      state.entryCount += 1;
      return null;
    };

    let rootCount = nodeEntryCount(state, state.root);
    let rootCap = if (nodeType(state, state.root) == NODE_LEAF) LEAF_CAP else INTERNAL_CAP;
    if (rootCount >= rootCap) {
      let split = if (nodeType(state, state.root) == NODE_LEAF) splitLeaf(state, state.root) else splitInternal(state, state.root);
      let newRoot = allocNode(state, NODE_INTERNAL);
      setChild(state, newRoot, 0, state.root);
      setInternalKey(state, newRoot, 0, split.medianKey);
      setChild(state, newRoot, 1, split.rightNode);
      setNodeEntryCount(state, newRoot, 1);
      state.root := newRoot;
    };

    insertNonFull(state, state.root, key, val)
  };

  func insertNonFull(state : State, node : Nat64, key : Blob, val : Blob) : ?Blob {
    if (nodeType(state, node) == NODE_LEAF) {
      let count = nodeEntryCount(state, node);
      let (idx, found) = leafSearch(state, node, key);
      if (found) {
        let old = leafVal(state, node, idx);
        Region.storeBlob(state.region, leafKeyOff(node, idx) + Nat64.fromNat(KEY_SIZE), val);
        return ?old;
      };
      shiftLeafRight(state, node, idx, count);
      setLeafEntry(state, node, idx, key, val);
      setNodeEntryCount(state, node, count + 1);
      state.entryCount += 1;
      null
    } else {
      let childIdx = internalSearch(state, node, key);
      var child = getChild(state, node, childIdx);
      let childCount = nodeEntryCount(state, child);
      let childCap = if (nodeType(state, child) == NODE_LEAF) LEAF_CAP else INTERNAL_CAP;
      if (childCount >= childCap) {
        let split = if (nodeType(state, child) == NODE_LEAF) splitLeaf(state, child) else splitInternal(state, child);
        let count = nodeEntryCount(state, node);
        shiftInternalRight(state, node, childIdx, count);
        setInternalKey(state, node, childIdx, split.medianKey);
        setChild(state, node, childIdx + 1, split.rightNode);
        setNodeEntryCount(state, node, count + 1);
        switch (compareKeys(key, split.medianKey)) {
          case (#less) {};
          case _ { child := split.rightNode };
        };
      };
      insertNonFull(state, child, key, val)
    }
  };

  public func size(state : State) : Nat {
    state.entryCount
  };

  public func memoryStats(state : State) : { nodes : Nat; entries : Nat; bytes : Nat; bytesPerEntry : Nat } {
    let nodes = Nat64.toNat(state.nodeCount);
    let bytes = nodes * Nat64.toNat(PAGE_SIZE);
    {
      nodes;
      entries = state.entryCount;
      bytes;
      bytesPerEntry = if (state.entryCount == 0) 0 else bytes / state.entryCount;
    }
  };
};
