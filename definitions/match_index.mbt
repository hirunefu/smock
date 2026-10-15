// The match index of a Mock: its Stubs grouped by the method and the exact
// path a request needs for them to match, so that finding the Stub that
// answers a request does not try every Stub of the Mock.
//
// The index never changes which Stub answers. A lookup gives every Stub
// the request could match, in matching order; it leaves out only Stubs
// whose exact method or exact path differs from the request's. Stubs that
// cannot be indexed, with neither an exact path nor a method, are given
// for every request, in their place in the order.

///|
/// The Stubs of a Mock, by their position in matching order, grouped by
/// their method and exact path conditions. Every list of positions is in
/// ascending order.
priv struct MatchIndex {
  /// The Stubs with an exact path condition, by that path.
  by_path : Map[String, PathStubs]
  /// The Stubs with a method condition and no exact path condition, such
  /// as a path pattern, by method.
  by_method : Map[String, Array[Int]]
  /// The Stubs with neither a method nor an exact path condition: they are
  /// tried for every request.
  scanned : Array[Int]
} derive(Debug, Eq)

///|
/// The Stubs with one exact path condition.
priv struct PathStubs {
  /// The Stubs that also have a method condition, by method.
  by_method : Map[String, Array[Int]]
  /// The Stubs without a method condition.
  any_method : Array[Int]
} derive(Debug, Eq)

///|
/// Indexes `stubs`, given in matching order.
fn MatchIndex::new(stubs : ReadOnlyArray[Stub]) -> MatchIndex {
  let index : MatchIndex = {
    by_path: Map([]),
    by_method: Map([]),
    scanned: [],
  }
  for position, stub in stubs {
    match (stub.request.path, stub.request.meth) {
      (Some(Exact(path)), meth) => {
        let stubs = match index.by_path.get(path) {
          Some(stubs) => stubs
          None => {
            let stubs = { by_method: Map([]), any_method: [], }
            index.by_path[path] = stubs
            stubs
          }
        }
        match meth {
          Some(meth) => add_position(stubs.by_method, meth, position)
          None => stubs.any_method.push(position)
        }
      }
      (_, Some(meth)) => add_position(index.by_method, meth, position)
      (_, None) => index.scanned.push(position)
    }
  }
  index
}

///|
/// Appends `position` to the list of `key` in `lists`.
fn add_position(
  lists : Map[String, Array[Int]],
  key : String,
  position : Int,
) -> Unit {
  match lists.get(key) {
    Some(list) => list.push(position)
    None => lists[key] = [position]
  }
}

///|
/// The Stubs of this Mock that a request with the method `meth` and the
/// path `path` can match, in matching order. `path` is percent-decoded and
/// without the query, as path conditions compare it.
///
/// They are found through the Mock's match index, built with the snapshot.
/// Every Stub left out has an exact method or an exact path condition that
/// the request does not meet, so the first of them that the request
/// matches is the first Stub of `stubs` that it matches.
pub fn Mock::candidates(
  self : Mock,
  meth : String,
  path : String,
) -> Iter[Stub] {
  let index = self.index
  let lists : Array[Array[Int]] = []
  if index.by_path.get(path) is Some(stubs) {
    if stubs.by_method.get(meth) is Some(list) {
      lists.push(list)
    }
    lists.push(stubs.any_method)
  }
  if index.by_method.get(meth) is Some(list) {
    lists.push(list)
  }
  lists.push(index.scanned)
  // Merges the lists: each step takes the lowest next position.
  let next = FixedArray::make(lists.length(), 0)
  Iter::new(() => {
    let mut first = -1
    for k, list in lists {
      if next[k] < list.length() &&
        (first < 0 || list[next[k]] < lists[first][next[first]]) {
        first = k
      }
    }
    guard first >= 0 else { None }
    let position = lists[first][next[first]]
    next[first] += 1
    Some(self.stubs[position])
  })
}

///|
/// No positions, for a list the match index does not have.
let no_positions : Array[Int] = []

///|
/// The first of `candidates(meth, path)` for which `accepts` holds, in the
/// same order, or `None`: found with a merge over the index's lists, with
/// no iterator or closure per Stub, since every request looks for one.
pub fn Mock::first_candidate(
  self : Mock,
  meth : String,
  path : String,
  accepts : (Stub) -> Bool,
) -> Stub? {
  let index = self.index
  // The same lists as `candidates` merges. A Stub is in one list at most,
  // so the lists never share a position.
  let mut by_path_method = no_positions
  let mut by_path_any = no_positions
  if index.by_path.get(path) is Some(stubs) {
    if stubs.by_method.get(meth) is Some(list) {
      by_path_method = list
    }
    by_path_any = stubs.any_method
  }
  let by_method = match index.by_method.get(meth) {
    Some(list) => list
    None => no_positions
  }
  let scanned = index.scanned
  let mut a = 0
  let mut b = 0
  let mut c = 0
  let mut d = 0
  for ;; {
    // The lowest next position of the four lists.
    let mut position = @int.MAX_VALUE
    let mut list = -1
    if a < by_path_method.length() && by_path_method[a] < position {
      position = by_path_method[a]
      list = 0
    }
    if b < by_path_any.length() && by_path_any[b] < position {
      position = by_path_any[b]
      list = 1
    }
    if c < by_method.length() && by_method[c] < position {
      position = by_method[c]
      list = 2
    }
    if d < scanned.length() && scanned[d] < position {
      position = scanned[d]
      list = 3
    }
    match list {
      0 => a += 1
      1 => b += 1
      2 => c += 1
      3 => d += 1
      _ => return None
    }
    let stub = self.stubs[position]
    if accepts(stub) {
      return Some(stub)
    }
  }
}
