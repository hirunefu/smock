// CRUD Stubs at the match decision: the answer of a CRUD Stub to a
// request it matched, read from the copy of its bucket that the request's
// Session holds, or else from the bucket's initial value. The answers are
// not templates: smock writes them, with fixed statuses.

///|
/// What a request asked of the CRUD Stub that matched it: the operation,
/// and the key text of its item path for an operation on one item. The
/// Journal records it. Its JSON form is the `CrudCall` schema of the Admin
/// API document.
pub(all) struct CrudCall {
  op : @definitions.CrudOp
  /// The key text of the item path, for an operation on one item: the
  /// segment after the Stub's path, whatever the outcome. `None` for a
  /// list.
  key : String?
} derive(Debug, Eq)

///|
/// The `CrudCall` schema of the Admin API document: `{op, key}`.
pub impl ToJson for CrudCall with fn to_json(self) {
  {
    "op": Json::string(self.op.name()),
    "key": match self.key {
      Some(key) => Json::string(key)
      None => Json::null()
    },
  }
}

///|
/// What the request `incoming` asks of `crud`, which it matched.
fn crud_call(crud : @definitions.Crud, incoming : Incoming) -> CrudCall {
  let path = incoming.path
  match crud.operation(incoming.request.meth, path) {
    Some(List as op) => { op, key: None, }
    Some(Read as op) => { op, key: Some(crud.key_of(path)), }
    None => abort("a CRUD Stub matched a request it does not serve")
  }
}

///|
/// The answer of the CRUD Stub `stub` of the Mock `mock`, which serves
/// `crud`, to the request `incoming` of `session` that asked `call` of it,
/// without Faults. It reads the copy of the bucket that the Session holds,
/// or else the bucket's initial value, and writes nothing:
///
/// - a list answers 200 with the items its query keeps, a plain array, or
///   400 when smock cannot read its query (see `crud_list`);
/// - a read answers 200 with the item whose key has the text of the item
///   path, or 404 when there is none.
///
/// The bucket is looked up by name, since an Ephemeral Stub is not read
/// again at a reload: one whose bucket the Mock no longer declares answers
/// 500 `unknown data bucket`, and one whose bucket has no `key` any more
/// 500 `data bucket changed`. Every answer is compact JSON, with the Stub's
/// `crud.headers` after smock's own.
fn Engine::crud_answer(
  self : Engine,
  mock : @definitions.Mock?,
  stub : String,
  crud : @definitions.Crud,
  call : CrudCall,
  incoming : Incoming,
  session : String?,
) -> ResponsePlan {
  // A matched Stub always has the Mock that answered.
  guard mock is Some(mock) && bucket_named(mock, crud.bucket) is Some(bucket) else {
    return crud_failed(crud, 500, {
      "error": "unknown data bucket",
      "stub": Json::string(stub),
      "bucket": Json::string(crud.bucket),
    })
  }
  guard bucket.key is Some(key) else {
    return crud_failed(crud, 500, {
      "error": "data bucket changed",
      "stub": Json::string(stub),
      "bucket": Json::string(crud.bucket),
    })
  }
  let copy = match self.store.copies_of(mock.name, session) {
    Some(copies) => copies.values.get(bucket.name)
    None => None
  }
  let value = match copy {
    Some(value) => value
    None => bucket.initial
  }
  // Every write keeps the rules of a keyed bucket, so it holds an array.
  guard value is Array(items) else { abort("a keyed bucket holds an array") }
  match call.op {
    List => crud_list(crud, stub, value, items, incoming.query_parameters())
    Read => {
      let text = call.key.unwrap_or("")
      match item_index(items, key, text) {
        Some(i) =>
          crud_plan(crud, 200, @template.compact_json_bytes(items[i]), [])
        None =>
          crud_failed(crud, 404, {
            "error": "no item with this key",
            "stub": Json::string(stub),
            "key": Json::string(text),
          })
      }
    }
  }
}

///|
/// An answer of a CRUD Stub that serves `crud`: `status`, with `body`, a
/// JSON value in compact JSON, its `Content-Type`, then smock's
/// `headers`, then the Stub's `crud.headers`.
fn crud_plan(
  crud : @definitions.Crud,
  status : Int,
  body : Bytes,
  headers : Array[(String, String)],
) -> ResponsePlan {
  let given = crud.headers
  // Room for the Smock-Mock field the Default Mock adds.
  let fields = Array(capacity=1 + headers.length() + given.length() + 1)
  fields.push(("Content-Type", "application/json"))
  for header in headers {
    fields.push(header)
  }
  for i in 0..<given.length() {
    fields.push(given[i])
  }
  { status, headers: fields, body: Bytes(body), delay_ms: 0, fault: None, }
}

///|
/// A failure of a CRUD Stub that serves `crud`: `status`, with `body`, an
/// object that says what went wrong, as `{"error": "<what>", "stub":
/// "<id>", ...}`, and the Stub's `crud.headers`.
fn crud_failed(
  crud : @definitions.Crud,
  status : Int,
  body : Json,
) -> ResponsePlan {
  crud_plan(crud, status, @template.compact_json_bytes(body), [])
}
