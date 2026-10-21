// CRUD Stubs: a Stub with `crud` in place of `request` and `response`
// serves a keyed Data bucket of its Mock as a REST resource. It lists the
// bucket at its path, and reads one item at its path plus the item's key.

///|
/// What a CRUD Stub serves: a keyed Data bucket of its Mock, at a path,
/// with static headers on every answer.
pub struct Crud {
  /// The name of the bucket it serves, a keyed bucket of the Stub's Mock
  /// when the Stub was read.
  bucket : String
  /// The list path, as written: it starts with `/`, does not end with `/`,
  /// and has no empty segment. An item path is this path, then `/`, then
  /// one non-empty segment, the key text.
  path : String
  /// The header fields of `crud.headers`, in the order written, sent on
  /// every answer of the Stub after smock's own. A header given an array
  /// has one field per value, in array order.
  headers : ReadOnlyArray[(String, String)]
} derive(Debug, Eq)

///|
/// What a request asks of a CRUD Stub, by its method and the shape of its
/// path.
pub enum CrudOp {
  /// `GET <path>`: the bucket's items.
  List
  /// `GET <path>/<key>`: the item with that key.
  Read
} derive(Debug, Eq)

///|
/// The operation's name, as the Journal writes it: `list` or `read`.
pub fn CrudOp::name(self : CrudOp) -> String {
  match self {
    List => "list"
    Read => "read"
  }
}

///|
/// The operation a request with the method `meth` and the path `path`,
/// percent-decoded and without the query, asks of the CRUD Stub, if any.
/// The path is compared byte for byte, as `path` conditions compare it, so
/// `/api/v1/orders/` and `/API/v1/orders` are neither the list path nor an
/// item path of `/api/v1/orders`, and the method exactly. Any other method
/// or path shape, such as HEAD, or a path deeper than an item's, asks
/// nothing of the Stub, which then does not match.
///
/// Every request of the Stub's Mock may be tested against it, so the test
/// allocates nothing: it compares the path's prefix in place.
pub fn Crud::operation(self : Crud, meth : String, path : String) -> CrudOp? {
  let list = self.path
  let n = list.length()
  if !path.has_prefix(list) || meth != "GET" {
    return None
  }
  if path.length() == n {
    return Some(List)
  }
  if path.length() == n + 1 || path[n] != '/' {
    return None
  }
  for i in (n + 1)..<path.length() {
    if path[i] == '/' {
      return None
    }
  }
  Some(Read)
}

///|
/// The key text of `path`, an item path of the CRUD Stub, as `operation`
/// finds one: the segment after the list path.
pub fn Crud::key_of(self : Crud, path : String) -> String {
  path[self.path.length() + 1:].to_owned()
}

///|
/// Whether `path` can be a CRUD Stub's path: it starts with `/`, does not
/// end with `/`, and has no empty segment, so `/` alone is not one.
fn is_crud_path(path : String) -> Bool {
  path.has_prefix("/") && path.split("/").drop(1).all(segment => segment != "")
}

///|
/// The header names, in lower case, that smock sets on the answers of a
/// CRUD Stub, so that its `crud.headers` cannot give them: those of a
/// Stub's response, its Content-Type, the `Location` of a create, and the
/// counts of a list.
let crud_names_set_by_smock : Array[String] = [
  ..response_names_set_by_smock, "content-type", "location", "x-total-count", "x-filtered-count",
]

///|
/// The members of a Stub that a CRUD Stub does not have: it has `crud` in
/// their place.
let not_beside_crud : Array[String] = [
  "request", "response", "responses", "scenario", "variables", "dataWrites",
]

///|
/// Reads `crud`, the value `json` at `pointer`: an object with the
/// `bucket` it serves, one of the keyed buckets `buckets` of the Stub's
/// Mock, its `path`, and optional `headers`. It has none when it has a
/// problem.
fn File::read_crud(
  self : File,
  pointer : String,
  json : Json,
  buckets~ : MockBuckets,
) -> Crud? {
  guard json is Object(members) else {
    self.error(pointer, "must be an object")
    return None
  }
  let reported = self.diagnostics.length()
  let mut bucket = None
  let mut path = None
  let mut headers = []
  for name, value in members {
    let field = child_pointer(pointer, name)
    match name {
      "bucket" =>
        if self.name(field, value) is Some(name) {
          match buckets.keyed.get(name) {
            Some(true) => bucket = Some(name)
            Some(false) =>
              self.error(
                field,
                "the Data bucket \{name.escape()} has no \"key\": a CRUD Stub serves only a keyed bucket",
              )
            None =>
              self.error(field, "the Mock has no Data bucket \{name.escape()}")
          }
        }
      "path" =>
        match value {
          String(text) if is_crud_path(text) => path = Some(text)
          _ =>
            self.error(
              field, "must be a path such as /api/v1/orders: it starts with /, does not end with /, and has no empty segment",
            )
        }
      "headers" =>
        headers = self
          .read_headers(field, value, set_by_smock=crud_names_set_by_smock)
          .map(header => (header.0, header.1))
      _ => self.unknown_field(field)
    }
  }
  self.require(members, pointer, "bucket")
  self.require(members, pointer, "path")
  guard self.diagnostics.length() == reported &&
    bucket is Some(bucket) &&
    path is Some(path) else {
    return None
  }
  Some({ bucket, path, headers: ReadOnlyArray::from_array(headers), })
}
