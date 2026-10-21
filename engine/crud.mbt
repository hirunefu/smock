// CRUD Stubs at the match decision: the answer of a CRUD Stub to a
// request it matched. A list or a read reads the copy of its bucket that
// the request's Session holds, or else the bucket's initial value. A
// create, replace, update or delete is one keyed write, the same that
// `dataWrites` makes, applied to a working copy, checked against the bound
// on per-Session state, and stored, or not at all. The answers are not
// templates: smock writes them, with fixed statuses. A rendering gives the
// same answers and makes the same write on a sample's data, with no bound
// and nothing stored (`render_crud`).

///|
/// What a request asked of the CRUD Stub that matched it: the operation,
/// and the key text of its item path for an operation on one item. The
/// Journal records it. Its JSON form is the `CrudCall` schema of the Admin
/// API document.
pub(all) struct CrudCall {
  op : @definitions.CrudOp
  /// The key text of the item path, for an operation on one item: the
  /// segment after the Stub's path, whatever the outcome. For a create,
  /// the key text of the item stored, or of the body's key member when an
  /// item has that key already, and else `None`. `None` for a list.
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
/// What the request `incoming` asks of `crud`, which it matched. The key
/// of a create is not known yet.
fn crud_call(crud : @definitions.Crud, incoming : Incoming) -> CrudCall {
  let path = incoming.path
  match crud.operation(incoming.request.meth, path) {
    Some(List | Create as op) => { op, key: None, }
    Some(op) => { op, key: Some(crud.key_of(path)), }
    None => abort("a CRUD Stub matched a request it does not serve")
  }
}

///|
/// The answer of a CRUD Stub to a request, and what it did.
priv struct CrudAnswer {
  /// The answer, without Faults.
  plan : ResponsePlan
  /// What the request asked of the Stub, as the Journal records it.
  call : CrudCall
  /// The names of the Data buckets the answer wrote: the Stub's bucket
  /// after a write, and none after a list, a read or any failure.
  written : ReadOnlyArray[String]
}

///|
/// The answer of the CRUD Stub `stub` of the Mock `mock`, which serves
/// `crud`, to the request `incoming` of `session`, which took the draw
/// `draw`, without Faults:
///
/// - a list answers 200 with the items its query keeps, a plain array, or
///   400 when smock cannot read its query (see `crud_list`);
/// - a read answers 200 with the item whose key has the text of the item
///   path, or 404 when there is none;
/// - a create, replace, update or delete writes, as `Engine::crud_write`
///   says.
///
/// A list or a read reads the copy of the bucket that the Session holds,
/// or else the bucket's initial value, and writes nothing. The bucket is
/// looked up by name, since an Ephemeral Stub is not read again at a
/// reload: one whose bucket the Mock no longer declares answers 500
/// `unknown data bucket`, and one whose bucket has no `key` any more 500
/// `data bucket changed`, and neither writes. Every answer is compact
/// JSON, with the Stub's `crud.headers` after smock's own.
fn Engine::crud_answer(
  self : Engine,
  mock : @definitions.Mock?,
  stub : String,
  crud : @definitions.Crud,
  incoming : Incoming,
  session : String?,
  draw : UInt64,
) -> CrudAnswer {
  let call = crud_call(crud, incoming)
  // A matched Stub always has the Mock that answered.
  guard mock is Some(mock) && bucket_named(mock, crud.bucket) is Some(bucket) else {
    return {
      plan: crud_failed(crud, 500, {
        "error": "unknown data bucket",
        "stub": Json::string(stub),
        "bucket": Json::string(crud.bucket),
      }),
      call,
      written: no_buckets_written,
    }
  }
  guard bucket.key is Some(key) else {
    return {
      plan: crud_failed(crud, 500, {
        "error": "data bucket changed",
        "stub": Json::string(stub),
        "bucket": Json::string(crud.bucket),
      }),
      call,
      written: no_buckets_written,
    }
  }
  if call.op is (Create | Replace | Update | Delete) {
    return self.crud_write(
      mock.name,
      stub,
      crud,
      bucket,
      key,
      call,
      incoming,
      session,
      draw,
    )
  }
  let copy = match self.store.copies_of(mock.name, session) {
    Some(copies) => copies.values.get(bucket.name)
    None => None
  }
  let value = match copy {
    Some(value) => value
    None => bucket.initial
  }
  {
    plan: crud_read(crud, stub, key, call, value, incoming),
    call,
    written: no_buckets_written,
  }
}

///|
/// The answer of the CRUD Stub `stub`, which serves `crud` over a bucket
/// keyed by the member `key_member`, to the request `incoming`, which
/// asked `call` of it, a list or a read, when the bucket holds `value`:
///
/// - a list answers 200 with the items its query keeps, a plain array, or
///   400 when smock cannot read its query (see `crud_list`);
/// - a read answers 200 with the item whose key has the text of the item
///   path, or 404 when there is none.
fn crud_read(
  crud : @definitions.Crud,
  stub : String,
  key_member : String,
  call : CrudCall,
  value : Json,
  incoming : Incoming,
) -> ResponsePlan {
  // Every write keeps the rules of a keyed bucket, so it holds an array.
  guard value is Array(items) else { abort("a keyed bucket holds an array") }
  if call.op is List {
    crud_list(crud, stub, value, items, incoming.query_parameters())
  } else {
    let text = call.key.unwrap_or("")
    match item_index(items, key_member, text) {
      Some(i) =>
        crud_plan(crud, 200, @template.compact_json_bytes(items[i]), [])
      None => no_item(crud, stub, text)
    }
  }
}

///|
/// The write of the CRUD Stub `stub` of the Mock `mock`, which serves
/// `crud`, over its keyed bucket `bucket`, keyed by the member
/// `key_member`, for the request `incoming` of `session`, which took the
/// draw `draw` and asked `call` of the Stub: a create, replace, update or
/// delete.
///
/// - The write is applied to a working copy of the Session's copy of the
///   bucket, or of its initial value, as `crud_apply` says.
/// - The bound on per-Session state is checked: a Session's first write to
///   the bucket counts the whole copy it leaves. A write that does not fit
///   answers 507, and counts as refused.
/// - The copy is stored, and the answer is the item stored, or the item
///   removed: 201 with `Location` for a create, else 200.
///
/// A write that cannot be applied answers 400 `body is not a JSON object`,
/// `invalid key` or `key does not match the path`, 404 `no item with this
/// key`, 409 `key already exists`, or 500 `no new key`. A failed write
/// writes nothing.
fn Engine::crud_write(
  self : Engine,
  mock : String,
  stub : String,
  crud : @definitions.Crud,
  bucket : @definitions.DataBucket,
  key_member : String,
  call : CrudCall,
  incoming : Incoming,
  session : String?,
  draw : UInt64,
) -> CrudAnswer {
  let working = WorkingCopies::new(self.store.copies_of(mock, session))
  let item = crud_apply(working, bucket, key_member, call, incoming, draw) catch {
    failure => return crud_refused(crud, stub, call, failure)
  }
  let space_growth = self.store.space_growth(mock, session)
  let growth = space_growth + working.growth()
  if !self.state.fits(growth) {
    working.undo()
    let message = self.state.refuse(growth)
    return {
      plan: crud_failed(crud, 507, state_limit_body(stub, message)),
      call,
      written: no_buckets_written,
    }
  }
  working.store(self.store, mock, session, space_growth~)
  crud_stored(crud, bucket.name, key_member, call, item)
}

///|
/// Applies the write of a CRUD Stub over the keyed bucket `bucket`, keyed
/// by the member `key_member`, to the working copies `working`, for the
/// request `incoming`, which took the draw `draw` and asked `call` of the
/// Stub: a create, replace, update or delete. It is the keyed write that
/// `dataWrites` makes with the same op: `append`, `set` or `merge` with a
/// key, or `remove`. Returns the item stored, or the item removed.
///
/// - A create, replace or update writes the request body, parsed as JSON
///   whatever its Content-Type, which must be an object. A delete ignores
///   the body.
/// - The write applies to the copy of the bucket that `working` holds, or
///   else to its initial value. A new `uuid` key draws from the helper
///   generator seeded with `draw`.
///
/// Raises the `KeyedFailure` that says why, `NotAnObject` for a body that
/// is not a JSON object, when the write cannot be applied, and then leaves
/// `working` as it was. Checks no bound and stores nothing.
fn crud_apply(
  working : WorkingCopies,
  bucket : @definitions.DataBucket,
  key_member : String,
  call : CrudCall,
  incoming : Incoming,
  draw : UInt64,
) -> Json raise KeyedFailure {
  let key = call.key.unwrap_or("")
  let body = if call.op is Delete {
    Json::null()
  } else {
    // A body that is not JSON is not an object either.
    incoming.body_json().unwrap_or(Json::null())
  }
  let i = working.reach(bucket.name, bucket.initial)
  errdefer working.undo()
  match call.op {
    Create =>
      working.append_item(
        i,
        bucket,
        key_member,
        body,
        @template.helper_generator(draw),
      )
    Replace => working.set_item(i, bucket, key_member, key, body)
    Update => working.merge_item(i, bucket, key_member, key, body)
    Delete => working.remove_item(i, bucket, key_member, key)
    List | Read => abort("a list or a read writes nothing")
  }
}

///|
/// The answer of the CRUD Stub that serves `crud` to a request that asked
/// `call` of it, once its write stored `item` in the bucket named `bucket`,
/// keyed by the member `key_member`, or removed it: 201 with the item and
/// its `Location` for a create, which then knows its key, else 200 with
/// the item.
fn crud_stored(
  crud : @definitions.Crud,
  bucket : String,
  key_member : String,
  call : CrudCall,
  item : Json,
) -> CrudAnswer {
  let body = @template.compact_json_bytes(item)
  let written = ReadOnlyArray::from_array([bucket])
  guard call.op is Create else {
    { plan: crud_plan(crud, 200, body, []), call, written, }
  }
  // A stored item always has a key.
  let key = item_key(item, key_member)
  {
    plan: crud_plan(crud, 201, body, [("Location", location(crud, key))]),
    call: { op: call.op, key: Some(key), },
    written,
  }
}

///|
/// The key text of `item`'s key member `key_member`, an item that a write
/// stored, which always has a valid key.
fn item_key(item : Json, key_member : String) -> String {
  guard item is Object(members) &&
    members.get(key_member) is Some(held) &&
    @definitions.key_text(held) is Some(key) else {
    abort("a stored item has a key")
  }
  key
}

///|
/// The answer of the CRUD Stub `stub`, which serves `crud`, to a request
/// that asked `call` of it and whose write could not be applied, for the
/// reason `failure`. The key of a create whose body's key an item has
/// already is that key.
fn crud_refused(
  crud : @definitions.Crud,
  stub : String,
  call : CrudCall,
  failure : KeyedFailure,
) -> CrudAnswer {
  let mut call = call
  let plan = match failure {
    NoItem(key) => no_item(crud, stub, key)
    NotAnObject(_) => bad_crud_request(crud, stub, "body is not a JSON object")
    OtherKey(_) => bad_crud_request(crud, stub, "key does not match the path")
    InvalidKey(_) => bad_crud_request(crud, stub, "invalid key")
    KeyTaken(key) => {
      call = { op: call.op, key: Some(key), }
      crud_failed(crud, 409, {
        "error": "key already exists",
        "stub": Json::string(stub),
        "key": Json::string(key),
      })
    }
    NoNewKey =>
      crud_failed(crud, 500, {
        "error": "no new key",
        "stub": Json::string(stub),
      })
  }
  { plan, call, written: no_buckets_written, }
}

///|
/// The 400 of the CRUD Stub `stub`, which serves `crud`, for a request
/// whose body cannot be written, for the reason `error`.
fn bad_crud_request(
  crud : @definitions.Crud,
  stub : String,
  error : String,
) -> ResponsePlan {
  crud_failed(crud, 400, {
    "error": Json::string(error),
    "stub": Json::string(stub),
  })
}

///|
/// The 404 of the CRUD Stub `stub`, which serves `crud`, for an item path
/// whose key text `key` no item has.
fn no_item(
  crud : @definitions.Crud,
  stub : String,
  key : String,
) -> ResponsePlan {
  crud_failed(crud, 404, {
    "error": "no item with this key",
    "stub": Json::string(stub),
    "key": Json::string(key),
  })
}

///|
/// The `Location` of an item that a create of the CRUD Stub that serves
/// `crud` stored with the key text `key`: each segment of the Stub's path,
/// then the key text, each after a `/` and percent-encoded as `urlEncode`
/// encodes it. So the key `a b` under `/api/v1/orders` gives
/// `/api/v1/orders/a%20b`.
fn location(crud : @definitions.Crud, key : String) -> String {
  let path = crud.path
  let out = StringBuilder()
  // The path starts with `/`, and has no empty segment.
  let mut start = 1
  for i in 1..<=path.length() {
    if i == path.length() || path[i] == '/' {
      out.write_char('/')
      @template.write_url_encoded(
        out,
        path.view(start_offset=start, end_offset=i),
      )
      start = i + 1
    }
  }
  out.write_char('/')
  @template.write_url_encoded(out, key)
  out.to_string()
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
