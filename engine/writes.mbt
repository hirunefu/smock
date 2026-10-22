// The writes of a matched Stub, at the match decision: its `variables` and
// its `dataWrites`, rendered against the state from before the request,
// applied to working copies of the Data buckets, checked against the bound
// on per-Session state, and then stored all at once, or not at all.

///|
/// A write of a Stub's `dataWrites` that could not be applied: a JSON
/// Pointer to the write, within the Stub, such as `/dataWrites/0`, and
/// what went wrong. The client then gets a 500, and the Journal entry
/// records it.
pub(all) struct DataError {
  at : String
  message : String
} derive(Debug, Eq)

///|
/// The `DataError` schema of the Admin API document.
pub impl ToJson for DataError with fn to_json(self) {
  { "at": Json::string(self.at), "message": Json::string(self.message) }
}

///|
/// Why a request's writes were not taken: nothing was written.
priv suberror WriteFailure {
  /// A value failed to render: the request gets the template failure.
  ValueFailed(TemplateError)
  /// A write of `dataWrites` could not be applied: the request gets
  /// `data_write_failed`.
  ApplyFailed(DataError)
  /// The writes would take the count of per-Session state above its bound,
  /// for the reason given: the request gets 507.
  StateLimitReached(String)
}

///|
/// What a request's writes leave: the rendering the response continues
/// with, which reads the state after them, and the names of the Data
/// buckets written, in the order first written, each once.
priv struct Written {
  context : @template.Context
  buckets : ReadOnlyArray[String]
}

///|
/// The names of the Data buckets a request wrote, when it wrote none.
let no_buckets_written : ReadOnlyArray[String] = ReadOnlyArray::from_array([])

///|
/// The writes, a step of the match decision, for `ordinary`, a Stub of the
/// Mock `mock` that writes Variables or Data buckets, whose Mock declares
/// the buckets `buckets`:
///
/// - The value of each of its `variables` is rendered, in the order
///   written, then the key and the value of each of its `dataWrites`, all
///   against the state of `mock` and `session` from before the request.
///   `first` is the first rendering for the request, which reads that
///   state; each key and value has a rendering of its own, with its own
///   bounds, and they draw from the request's helper generator in turn.
/// - The writes of `dataWrites` are applied in order, as if to working
///   copies of the buckets. New `uuid` keys draw from the helper generator
///   then, in write order.
/// - The bound on per-Session state is checked.
/// - The Variables and the copies are stored at once.
///
/// Returns the rendering the response continues with, which reads the
/// state after the writes, and the buckets written. When a key or a value
/// fails to render, a write cannot be applied, or the writes do not fit,
/// it raises why and writes nothing; the bound counts a refusal.
fn Engine::write_state(
  self : Engine,
  mock : String,
  buckets : ReadOnlyArray[@definitions.DataBucket],
  ordinary : @definitions.Ordinary,
  session : String?,
  first : @template.Context,
) -> Written raise WriteFailure {
  let variables = ordinary.variables
  let writes = ordinary.data_writes
  let before = self.store.variables_of(mock, session)
  let values = Array(capacity=variables.values.length())
  let write_keys = Array(capacity=writes.length())
  let write_values = Array(capacity=writes.length())
  let last = render_writes(
    ordinary, first, before, values, write_keys, write_values,
  ) catch {
    RenderError(at~, message~) => raise ValueFailed({ at, message, })
  }
  // A Stub without data writes makes no working copies.
  let working = if writes.length() == 0 {
    None
  } else {
    Some(
      apply_writes(
        self.store.copies_of(mock, session),
        writes,
        write_keys,
        write_values,
        buckets,
        last.generator(),
      ),
    )
  }
  let variable_growth = self.store.variable_growth(
    mock,
    session,
    before,
    variables.names,
    values,
  )
  // A space counts once: with the Variables when the Stub writes any.
  let mut space_growth = 0L
  let mut data_growth = 0L
  if working is Some(working) {
    if variables.names.length() == 0 {
      space_growth = self.store.space_growth(mock, session)
    }
    data_growth = working.growth()
  }
  let growth = variable_growth + space_growth + data_growth
  if !self.state.fits(growth) {
    if working is Some(working) {
      working.undo()
    }
    raise StateLimitReached(self.state.refuse(growth))
  }
  self.store.write_variables(
    mock,
    session,
    variables.names,
    values,
    growth=variable_growth,
  )
  match working {
    None =>
      {
        context: last.next(vars?=self.store.variables_of(mock, session)),
        buckets: no_buckets_written,
      }
    Some(working) => {
      working.store(self.store, mock, session, space_growth~)
      {
        context: last.next(
          vars?=self.store.variables_of(mock, session),
          copies?=self.store.copy_values(mock, session),
        ),
        buckets: ReadOnlyArray::from_array(working.names()),
      }
    }
  }
}

///|
/// Renders what `ordinary`, a Stub that writes Variables or Data buckets,
/// writes, as the second step of the match decision does: the value of
/// each of its `variables`, in the order written, into `values`, then the
/// key and the value of each of its `dataWrites`, into `keys` and
/// `write_values`, all against the state from before the request. `first`
/// is the first rendering for the request, which reads that state, and
/// `before` the Variables of that state. Each key and value has a rendering
/// of its own, with its own bounds, and they draw from the request's helper
/// generator in turn. A write without a key gets `None`, and a `remove`
/// the value null.
///
/// Returns the last rendering, which the response continues from. Raises
/// `RenderError` when a value or a key fails to render.
fn render_writes(
  ordinary : @definitions.Ordinary,
  first : @template.Context,
  before : Map[String, Json]?,
  values : Array[Json],
  keys : Array[String?],
  write_values : Array[Json],
) -> @template.Context raise @template.RenderError {
  let writes = ordinary.data_writes
  let mut context = render_values(ordinary.variables, first, before, values)
  // Whether `context` has rendered nothing yet: only `first` may not have,
  // when the Stub writes no Variable.
  let mut fresh = values.length() == 0
  for i in 0..<writes.length() {
    let write = writes[i]
    match write.key {
      Some(key) => {
        if !fresh {
          context = context.next(vars?=before)
        }
        fresh = false
        keys.push(Some(key.render_value(context)))
      }
      None => keys.push(None)
    }
    match write.value {
      Some(value) => {
        if !fresh {
          context = context.next(vars?=before)
        }
        fresh = false
        write_values.push(value.render_value(context))
      }
      // A `remove` has no value.
      None => write_values.push(Json::null())
    }
  }
  context
}

///|
/// Applies `writes`, a Stub's `dataWrites`, with their rendered keys
/// `keys` and values `values`, in order, to working copies of the buckets
/// `buckets` of the Stub's Mock, in a space that holds the copies `stored`.
/// New `uuid` keys draw from `rand`, the request's helper generator.
/// Raises `ApplyFailed` when a write cannot be applied, and then leaves the
/// copies as they were.
fn apply_writes(
  stored : Copies?,
  writes : ReadOnlyArray[@definitions.DataWrite],
  keys : Array[String?],
  values : Array[Json],
  buckets : ReadOnlyArray[@definitions.DataBucket],
  rand : @prng.Generator,
) -> WorkingCopies raise WriteFailure {
  let working = WorkingCopies::new(stored)
  errdefer working.undo()
  for i in 0..<writes.length() {
    working.apply(i, writes[i], keys[i], values[i], buckets, rand)
  }
  working
}

///|
/// Where the value of a bucket that a request's writes have reached comes
/// from.
priv enum Source {
  /// The writes made it: it is the request's own, and changes in place.
  Own
  /// The copy the space held before the request. It changes in place, and
  /// each change is recorded, so that it can be undone.
  Stored
  /// The bucket's initial value, which belongs to the definition set and
  /// never changes: a write that changes it in place copies it first.
  Initial
}

///|
/// How to undo a change made in place to a copy the space held before the
/// request.
priv enum Undo {
  /// A member of an object was set: put back its value before, or remove
  /// it when it had none.
  Member(Map[String, Json], String, Json?)
  /// An element was appended to an array: remove it.
  Element(Array[Json])
  /// The element at an index of an array was replaced: put back the one
  /// before.
  Replaced(Array[Json], Int, Json)
  /// The element at an index of an array was removed: insert it back.
  Removed(Array[Json], Int, Json)
}

///|
/// The working copies of one request's data writes: each bucket the writes
/// have reached so far, by its index, with the value it holds after them.
/// "Working copies" describe the result, not the method: only a space's
/// first write to a bucket copies the bucket. Later writes change the
/// space's copy in place, and are undone when the request fails.
priv struct WorkingCopies {
  /// The copies the space held before the request, if any.
  stored : Copies?
  /// The buckets reached, in the order first written.
  reached : Array[Reached]
  /// The changes made in place to the stored copies, in order.
  changes : Array[Undo]
}

///|
/// A bucket that a request's writes have reached.
priv struct Reached {
  /// The bucket's name.
  name : String
  /// The value it holds after the writes so far.
  mut value : Json
  /// Where the value comes from.
  mut source : Source
  /// What it would count as a copy, as `copy_bytes` gives it, kept up to
  /// date as it changes; unknown while it is the initial value.
  mut bytes : Int64
  /// What it counted before the request: its stored copy's bytes, or 0
  /// when the space held no copy of it.
  before : Int64
}

///|
/// No bucket reached yet, in a space that holds the copies `stored`.
fn WorkingCopies::new(stored : Copies?) -> WorkingCopies {
  { stored, reached: [], changes: [], }
}

///|
/// The names of the buckets reached, in the order first written.
fn WorkingCopies::names(self : WorkingCopies) -> Array[String] {
  let names = Array(capacity=self.reached.length())
  for reached in self.reached {
    names.push(reached.name)
  }
  names
}

///|
/// The index of the bucket named `name` among those reached, which it
/// reaches first when it has not yet: its value is then the space's copy,
/// or else the initial value `initial`.
fn WorkingCopies::reach(
  self : WorkingCopies,
  name : String,
  initial : Json,
) -> Int {
  for i in 0..<self.reached.length() {
    if self.reached[i].name == name {
      return i
    }
  }
  let copy = match self.stored {
    Some(stored) => stored.values.get(name)
    None => None
  }
  match copy {
    Some(value) => {
      let counted = match self.stored {
        Some(stored) => stored.bytes.get(name).unwrap_or(0L)
        None => 0L
      }
      self.reached.push({
        name,
        value,
        source: Stored,
        bytes: counted,
        before: counted,
      })
    }
    None =>
      self.reached.push({
        name,
        value: initial,
        source: Initial,
        bytes: 0L,
        before: 0L,
      })
  }
  self.reached.length() - 1
}

///|
/// Applies `write`, the write at index `index` of a Stub's `dataWrites`,
/// with its rendered key `key`, if it has one, and its rendered value
/// `value`, to the working copies. `buckets` are the buckets the Stub's
/// Mock declares now, and new `uuid` keys draw from `rand`. Raises
/// `ApplyFailed`, with why, when it cannot be applied.
fn WorkingCopies::apply(
  self : WorkingCopies,
  index : Int,
  write : @definitions.DataWrite,
  key : String?,
  value : Json,
  buckets : ReadOnlyArray[@definitions.DataBucket],
  rand : @prng.Generator,
) -> Unit raise WriteFailure {
  let at = "/dataWrites/\{index}"
  // The buckets of a Stub from the Definition files are always there, as
  // it was read; an Ephemeral Stub's may be gone or changed since a reload.
  guard bucket_named(buckets, write.bucket) is Some(bucket) else {
    raise apply_failed(
      at,
      "the Mock has no Data bucket \{write.bucket.escape()} since a reload",
    )
  }
  guard bucket.key is Some(key_member) else {
    if key is Some(_) {
      raise apply_failed(
        at,
        "the Data bucket \{bucket.name.escape()} has no \"key\" since a reload, and a write with \"key\" needs a keyed bucket",
      )
    }
    return self.apply_whole(at, write.op, bucket, value)
  }
  // Without a key, `set` replaces the whole bucket, and `append` adds an
  // item, as with a key.
  if key is None {
    match write.op {
      Replace => {
        let problems = @definitions.keyed_problems(value, key=key_member)
        if !problems.is_empty() {
          raise apply_failed(
            at,
            broken_rules(bucket.name, key_member, problems),
          )
        }
        return self.apply_whole(at, write.op, bucket, value)
      }
      Merge =>
        raise apply_failed(
          at,
          "the Data bucket \{bucket.name.escape()} has \"key\" since a reload, and \"merge\" without \"key\" cannot write to a keyed bucket",
        )
      Remove => return self.apply_whole(at, write.op, bucket, value)
      Append => ()
    }
  }
  let i = self.reach(bucket.name, bucket.initial)
  let failure = try {
    match key {
      None => self.append_item(i, bucket, key_member, value, rand) |> ignore
      Some(key) =>
        match write.op {
          Replace => self.set_item(i, bucket, key_member, key, value) |> ignore
          Merge => self.merge_item(i, bucket, key_member, key, value) |> ignore
          Remove => self.remove_item(i, bucket, key_member, key) |> ignore
          // An `append` never has a key.
          Append =>
            self.append_item(i, bucket, key_member, value, rand) |> ignore
        }
    }
    return
  } catch {
    failure => failure
  }
  raise apply_failed(at, failure.message(bucket.name, key_member, write.op))
}

///|
/// Applies a write without a key, whose op is `op`, with its rendered
/// value `value`, to the whole of `bucket`. Raises `ApplyFailed`, at `at`,
/// when it cannot be applied.
fn WorkingCopies::apply_whole(
  self : WorkingCopies,
  at : String,
  op : @definitions.DataOp,
  bucket : @definitions.DataBucket,
  value : Json,
) -> Unit raise WriteFailure {
  let i = self.reach(bucket.name, bucket.initial)
  match op {
    Replace => {
      self.reached[i].value = value
      self.reached[i].source = Own
      self.reached[i].bytes = copy_bytes(bucket.name, value)
    }
    Merge => {
      guard value is Object(members) else {
        raise apply_failed(
          at,
          "the value of \"merge\" must be an object, and it is \{kind_of(value)}",
        )
      }
      guard self.reached[i].value is Object(_) else {
        raise apply_failed(
          at,
          "the Data bucket \{bucket.name.escape()} holds \{kind_of(self.reached[i].value)}, and \"merge\" needs an object",
        )
      }
      guard self.own(i, bucket.name) is Object(object) else {
        abort("own() keeps the value's kind")
      }
      self.merge_members(i, object, members, except=None)
    }
    Append => {
      guard self.reached[i].value is Array(_) else {
        raise apply_failed(
          at,
          "the Data bucket \{bucket.name.escape()} holds \{kind_of(self.reached[i].value)}, and \"append\" needs an array",
        )
      }
      guard self.own(i, bucket.name) is Array(array) else {
        abort("own() keeps the value's kind")
      }
      self.push_element(i, array, value)
    }
    // A `remove` always has a key, so this is never reached.
    Remove => raise apply_failed(at, "\"remove\" needs \"key\"")
  }
}

///|
/// Merges `members` into `object`, a part of the value of the bucket at
/// index `i`, which is ready to change in place: each replaces the member
/// of the same name in its place, or is added at the end. The member named
/// `except`, if any, is left as it is. The bucket's count follows.
fn WorkingCopies::merge_members(
  self : WorkingCopies,
  i : Int,
  object : Map[String, Json],
  members : Map[String, Json],
  except~ : String?,
) -> Unit {
  let stored = self.reached[i].source is Stored
  let mut more = 0L
  for name, member_value in members {
    if except is Some(skipped) && name == skipped {
      continue
    }
    let old = object.get(name)
    match old {
      Some(old) => more += value_bytes(member_value) - value_bytes(old)
      None =>
        more += member_bytes(name, member_value) +
          (if object.is_empty() { 0L } else { 1L })
    }
    if stored {
      self.changes.push(Member(object, name, old))
    }
    object[name] = member_value
  }
  self.reached[i].bytes += more
}

///|
/// Appends `element` to `array`, the value of the bucket at index `i`,
/// which is ready to change in place. The bucket's count follows.
fn WorkingCopies::push_element(
  self : WorkingCopies,
  i : Int,
  array : Array[Json],
  element : Json,
) -> Unit {
  self.reached[i].bytes += value_bytes(element) +
    (if array.is_empty() { 0L } else { 1L })
  if self.reached[i].source is Stored {
    self.changes.push(Element(array))
  }
  array.push(element)
}

///|
/// The failure of the write at `at`, for the reason `message`.
fn apply_failed(at : String, message : String) -> WriteFailure {
  ApplyFailed({ at, message, })
}

///|
/// The value of the bucket at index `i`, ready to change in place: the
/// space's copy, or the request's own; an initial value is copied first,
/// and its copy counted, since the definition set's never changes. The
/// copy is deep, so that no change to it, at any depth, reaches the initial
/// value.
fn WorkingCopies::own(self : WorkingCopies, i : Int, bucket : String) -> Json {
  if self.reached[i].source is Initial {
    self.reached[i].value = deep_copy(self.reached[i].value)
    self.reached[i].source = Own
    self.reached[i].bytes = copy_bytes(bucket, self.reached[i].value)
  }
  self.reached[i].value
}

///|
/// A copy of `json` that shares no object or array with it.
fn deep_copy(json : Json) -> Json {
  match json {
    Array(items) => {
      let copy = Array(capacity=items.length())
      for item in items {
        copy.push(deep_copy(item))
      }
      Json::array(copy)
    }
    Object(members) => {
      let copy = Map([])
      for name, member_value in members {
        copy[name] = deep_copy(member_value)
      }
      Json::object(copy)
    }
    _ => json
  }
}

///|
/// What kind of JSON value `json` is, as messages name it, such as `an
/// object` or `a number`.
fn kind_of(json : Json) -> String {
  match json {
    Null => "null"
    True | False => "a boolean"
    Number(_, ..) => "a number"
    String(_) => "a string"
    Array(_) => "an array"
    Object(_) => "an object"
  }
}

///|
/// Undoes every change made in place to the space's copies, last first,
/// so that they are as they were before the request.
fn WorkingCopies::undo(self : WorkingCopies) -> Unit {
  for i = self.changes.length() - 1; i >= 0; i = i - 1 {
    match self.changes[i] {
      Member(object, name, Some(value)) => object[name] = value
      Member(object, name, None) => object.remove(name)
      Element(array) => array.pop() |> ignore
      Replaced(array, index, element) => array[index] = element
      Removed(array, index, element) => array.insert(index, element)
    }
  }
  self.changes.clear()
}

///|
/// How many bytes the count of per-Session state grows by when the working
/// copies are stored, beside what the space counts.
fn WorkingCopies::growth(self : WorkingCopies) -> Int64 {
  let mut growth = 0L
  for reached in self.reached {
    growth += reached.bytes - reached.before
  }
  growth
}

///|
/// Stores the working copies as the copies of `mock` that `session` holds,
/// and grows the count by what they and, by `space_growth`, their space
/// count, which must fit.
fn WorkingCopies::store(
  self : WorkingCopies,
  store : SessionStore,
  mock : String,
  session : String?,
  space_growth~ : Int64,
) -> Unit {
  for i, reached in self.reached {
    let growth = reached.bytes -
      reached.before +
      (if i == 0 { space_growth } else { 0L })
    store.write_copy(
      mock,
      session,
      reached.name,
      reached.value,
      bytes=reached.bytes,
      growth~,
    )
  }
}

///|
/// The response to a request whose data write could not be applied: 500,
/// with the write and what went wrong.
fn data_write_failed(stub : String, error : DataError) -> ResponsePlan {
  json_failure(500, {
    "error": "data write failed",
    "stub": Json::string(stub),
    "at": Json::string(error.at),
    "message": Json::string(error.message),
  })
}
