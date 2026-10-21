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
/// `crud`, to a request of `session` that asked `call` of it, without
/// Faults. It reads the copy of the bucket that the Session holds, or else
/// the bucket's initial value, and writes nothing:
///
/// - a list answers 200 with the bucket's items, a plain array, and their
///   number in `X-Total-Count` and `X-Filtered-Count`;
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
    List => {
      let count = items.length().to_string()
      crud_plan(crud, 200, @template.compact_json_bytes(value), [
        ("X-Total-Count", count),
        ("X-Filtered-Count", count),
      ])
    }
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
/// The index of the item of `items`, the value of a bucket keyed by the
/// member `key`, whose key has the text `text`, if any. A key is compared
/// by its text, as `@definitions.key_text` gives it, without making the
/// text: a string as it is, and an integer by its value, when `text` is
/// the text of an integer.
fn item_index(items : Array[Json], key : String, text : String) -> Int? {
  let integer = integer_of(text)
  for i in 0..<items.length() {
    guard items[i] is Object(members) else { continue }
    match members.get(key) {
      Some(String(s)) if s == text => return Some(i)
      Some(Number(n, ..)) if integer is Some(wanted) && n == wanted =>
        return Some(i)
      _ => ()
    }
  }
  None
}

///|
/// The integer whose key text is `text`, if there is one: decimal digits
/// with no leading zero, after `-` when it is negative, from
/// `-@definitions.max_integer_key` to `@definitions.max_integer_key`. So
/// `42` and `-7` have one, and `042`, `-0`, `+1` and `4.2e1` do not.
fn integer_of(text : String) -> Double? {
  let negative = text.has_prefix("-")
  let start = if negative { 1 } else { 0 }
  let digits = text.length() - start
  // 2^53 - 1 has 16 digits.
  if digits < 1 ||
    digits > 16 ||
    (text[start] == '0' && (digits > 1 || negative)) {
    return None
  }
  let mut value = 0L
  for i in start..<text.length() {
    let c = text[i]
    if c < '0' || c > '9' {
      return None
    }
    value = value * 10L + (c.to_int() - '0'.to_int()).to_int64()
  }
  if value > @definitions.max_integer_key {
    return None
  }
  Some(if negative { -value.to_double() } else { value.to_double() })
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
