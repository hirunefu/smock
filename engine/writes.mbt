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
///   written, then the value of each of its `dataWrites`, all against the
///   state of `mock` and `session` from before the request. `first` is the
///   first rendering for the request, which reads that state; each value
///   has a rendering of its own, with its own bounds, and they draw from
///   the request's helper generator in turn.
/// - The writes of `dataWrites` are applied in order, as if to working
///   copies of the buckets.
/// - The bound on per-Session state is checked.
/// - The Variables and the copies are stored at once.
///
/// Returns the rendering the response continues with, which reads the
/// state after the writes, and the buckets written. When a value fails to
/// render, a write cannot be applied, or the writes do not fit, it raises
/// why and writes nothing; the bound counts a refusal.
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
  let write_values = Array(capacity=writes.length())
  let last = try {
    let mut context = render_values(variables, first, before, values)
    for i in 0..<writes.length() {
      if i > 0 || values.length() > 0 {
        context = context.next(vars?=before)
      }
      write_values.push(writes[i].value.render_value(context))
    }
    context
  } catch {
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
        write_values,
        buckets,
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
        buckets: ReadOnlyArray::from_array(working.names),
      }
    }
  }
}

///|
/// Applies `writes`, a Stub's `dataWrites`, with their rendered values
/// `values`, in order, to working copies of the buckets `buckets` of the
/// Stub's Mock, in a space that holds the copies `stored`. Raises
/// `ApplyFailed` when a write cannot be applied, and then leaves the copies
/// as they were.
fn apply_writes(
  stored : Copies?,
  writes : ReadOnlyArray[@definitions.DataWrite],
  values : Array[Json],
  buckets : ReadOnlyArray[@definitions.DataBucket],
) -> WorkingCopies raise WriteFailure {
  let working = WorkingCopies::new(stored)
  errdefer working.undo()
  for i in 0..<writes.length() {
    working.apply(i, writes[i], values[i], buckets)
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
}

///|
/// The working copies of one request's data writes: each bucket the writes
/// have reached so far, by the index of its name, with the value it holds
/// after them. "Working copies" describe the result, not the method: only
/// a space's first write to a bucket copies the bucket. Later writes change
/// the space's copy in place, and are undone when the request fails.
priv struct WorkingCopies {
  /// The copies the space held before the request, if any.
  stored : Copies?
  /// The names of the buckets reached, in the order first written.
  names : Array[String]
  /// The value each holds after the writes so far.
  values : Array[Json]
  /// Where each value comes from.
  sources : Array[Source]
  /// What each would count as a copy, as `copy_bytes` gives it, kept up to
  /// date as it changes; unknown while it is the initial value.
  bytes : Array[Int64]
  /// What each counted before the request: its stored copy's bytes, or 0
  /// when the space held no copy of it.
  before : Array[Int64]
  /// The changes made in place to the stored copies, in order.
  changes : Array[Undo]
}

///|
/// No bucket reached yet, in a space that holds the copies `stored`.
fn WorkingCopies::new(stored : Copies?) -> WorkingCopies {
  {
    stored,
    names: [],
    values: [],
    sources: [],
    bytes: [],
    before: [],
    changes: [],
  }
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
  for i in 0..<self.names.length() {
    if self.names[i] == name {
      return i
    }
  }
  let copy = match self.stored {
    Some(stored) => stored.values.get(name)
    None => None
  }
  self.names.push(name)
  match copy {
    Some(value) => {
      let counted = match self.stored {
        Some(stored) => stored.bytes.get(name).unwrap_or(0L)
        None => 0L
      }
      self.values.push(value)
      self.sources.push(Stored)
      self.bytes.push(counted)
      self.before.push(counted)
    }
    None => {
      self.values.push(initial)
      self.sources.push(Initial)
      self.bytes.push(0L)
      self.before.push(0L)
    }
  }
  self.names.length() - 1
}

///|
/// Applies `write`, the write at index `index` of a Stub's `dataWrites`,
/// with its rendered value `value`, to the working copies. `buckets` are
/// the buckets the Stub's Mock declares now. Raises `ApplyFailed`, with
/// why, when it cannot be applied.
fn WorkingCopies::apply(
  self : WorkingCopies,
  index : Int,
  write : @definitions.DataWrite,
  value : Json,
  buckets : ReadOnlyArray[@definitions.DataBucket],
) -> Unit raise WriteFailure {
  let at = "/dataWrites/\{index}"
  let mut declared = None
  for i in 0..<buckets.length() {
    if buckets[i].name == write.bucket {
      declared = Some(buckets[i])
      break
    }
  }
  // The buckets of a Stub from the Definition files are always there, as
  // it was read; an Ephemeral Stub's may be gone or changed since a reload.
  guard declared is Some(bucket) else {
    raise apply_failed(
      at,
      "the Mock has no Data bucket \{write.bucket.escape()} since a reload",
    )
  }
  if bucket.key is Some(_) {
    raise apply_failed(
      at,
      "the Data bucket \{bucket.name.escape()} has \"key\" since a reload, and dataWrites cannot write to a keyed bucket yet",
    )
  }
  let i = self.reach(bucket.name, bucket.initial)
  match write.op {
    Replace => {
      self.values[i] = value
      self.sources[i] = Own
      self.bytes[i] = copy_bytes(bucket.name, value)
    }
    Merge => {
      guard value is Object(members) else {
        raise apply_failed(
          at,
          "the value of \"merge\" must be an object, and it is \{kind_of(value)}",
        )
      }
      guard self.values[i] is Object(_) else {
        raise apply_failed(
          at,
          "the Data bucket \{bucket.name.escape()} holds \{kind_of(self.values[i])}, and \"merge\" needs an object",
        )
      }
      let target = self.own(i, bucket.name)
      guard target is Object(object) else { return }
      let stored = self.sources[i] is Stored
      let mut more = 0L
      for name, member_value in members {
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
      self.bytes[i] += more
    }
    Append => {
      guard self.values[i] is Array(_) else {
        raise apply_failed(
          at,
          "the Data bucket \{bucket.name.escape()} holds \{kind_of(self.values[i])}, and \"append\" needs an array",
        )
      }
      let target = self.own(i, bucket.name)
      guard target is Array(array) else { return }
      self.bytes[i] += value_bytes(value) +
        (if array.is_empty() { 0L } else { 1L })
      if self.sources[i] is Stored {
        self.changes.push(Element(array))
      }
      array.push(value)
    }
  }
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
  if self.sources[i] is Initial {
    self.values[i] = deep_copy(self.values[i])
    self.sources[i] = Own
    self.bytes[i] = copy_bytes(bucket, self.values[i])
  }
  self.values[i]
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
    }
  }
  self.changes.clear()
}

///|
/// How many bytes the count of per-Session state grows by when the working
/// copies are stored, beside what the space counts.
fn WorkingCopies::growth(self : WorkingCopies) -> Int64 {
  let mut growth = 0L
  for i in 0..<self.names.length() {
    growth += self.bytes[i] - self.before[i]
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
  for i in 0..<self.names.length() {
    let growth = self.bytes[i] -
      self.before[i] +
      (if i == 0 { space_growth } else { 0L })
    store.write_copy(
      mock,
      session,
      self.names[i],
      self.values[i],
      bytes=self.bytes[i],
      growth~,
    )
  }
}

///|
/// The response to a request whose data write could not be applied: 500,
/// with the write and what went wrong.
fn data_write_failed(stub : String, error : DataError) -> ResponsePlan {
  let body : Json = {
    "error": "data write failed",
    "stub": Json::string(stub),
    "at": Json::string(error.at),
    "message": Json::string(error.message),
  }
  {
    status: 500,
    headers: [("Content-Type", "application/json")],
    body: Bytes(@template.compact_json_bytes(body)),
    delay_ms: 0,
    fault: None,
  }
}
