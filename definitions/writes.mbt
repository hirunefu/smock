// A Stub's `dataWrites`: writes to the Data buckets of its Mock, applied
// in order when the Stub matches, together with its `variables`, all or
// nothing.

///|
/// One write of a Stub's `dataWrites`: what it does, the bucket it writes
/// to, and the template of its value.
pub struct DataWrite {
  op : DataOp
  /// The name of the bucket written to, one of the buckets of the Stub's
  /// Mock when the Stub was read.
  bucket : String
  /// The template of the value, a structured template whose pointer is
  /// `/dataWrites/<i>/value`, parsed whether or not a response has
  /// `template` on.
  value : @template.Structured
} derive(Debug, Eq)

///|
/// What a write does to its bucket, by its `op`.
pub enum DataOp {
  /// `set`: the bucket becomes the value.
  Replace
  /// `merge`: the members of the value, an object, are merged into the
  /// bucket, which holds an object: each replaces the member of the same
  /// name in its place, or is added at the end.
  Merge
  /// `append`: the value is appended to the bucket, which holds an array.
  Append
} derive(Debug, Eq)

///|
/// The op's name, as `dataWrites` writes it: `set`, `merge` or `append`.
pub fn DataOp::name(self : DataOp) -> String {
  match self {
    Replace => "set"
    Merge => "merge"
    Append => "append"
  }
}

///|
/// The most writes a Stub's `dataWrites` holds.
pub let max_data_writes : Int = 100

///|
/// What a Stub without `dataWrites` writes: nothing.
let no_data_writes : ReadOnlyArray[DataWrite] = ReadOnlyArray::from_array([])

///|
/// The Data buckets of one Mock, as the Stubs of the Mock see them when
/// they are read: the names their templates may read, and whether each
/// bucket is keyed.
priv struct MockBuckets {
  /// The buckets templates may read as `data.NAME`.
  templates : @template.Buckets
  /// Whether each bucket is keyed, by its name.
  keyed : Map[String, Bool]
}

///|
/// The buckets `keyed` names, each with whether it is keyed.
fn MockBuckets::new(keyed : Map[String, Bool]) -> MockBuckets {
  { templates: @template.Buckets(keyed.keys().collect()), keyed, }
}

///|
/// The buckets of a Mock that declares none.
let no_mock_buckets : MockBuckets = MockBuckets::new(Map([]))

///|
/// Reads the `dataWrites` of the Stub at `stub_pointer`: the value `json`
/// at `pointer`, a list of 1 to `max_data_writes` writes, each to one of
/// the Data buckets `buckets` of the Stub's Mock. Each write is an object
/// with `op`, `bucket`, and the members its op takes: `value`, a
/// structured template parsed whether or not a response has `template` on,
/// and `key`. Returns the writes in the order written.
///
/// Writes to keyed buckets, and so `remove` and `key`, do not load yet.
fn File::read_data_writes(
  self : File,
  stub_pointer : String,
  pointer : String,
  json : Json,
  buckets~ : MockBuckets,
) -> ReadOnlyArray[DataWrite] {
  let items = self.array(pointer, json)
  if json is Array(_) &&
    (items.length() < 1 || items.length() > max_data_writes) {
    self.error(pointer, "must hold 1 to \{max_data_writes} writes")
  }
  let writes = []
  for i, item in items {
    if self.read_data_write(
        stub_pointer,
        child_pointer(pointer, i.to_string()),
        item,
        buckets~,
      )
      is Some(write) {
      writes.push(write)
    }
  }
  ReadOnlyArray::from_array(writes)
}

///|
/// Reads one write of `dataWrites`, the value `json` at `pointer`, of the
/// Stub at `stub_pointer`, to one of the Data buckets `buckets` of the
/// Stub's Mock. It has none when it has a problem.
fn File::read_data_write(
  self : File,
  stub_pointer : String,
  pointer : String,
  json : Json,
  buckets~ : MockBuckets,
) -> DataWrite? {
  guard json is Object(members) else {
    self.error(pointer, "must be an object")
    return None
  }
  let problems = self.diagnostics.length()
  // The op's name, as written, when it is one of the four.
  let mut op_name = None
  let mut bucket = None
  let mut value = None
  for name, field_value in members {
    let field = child_pointer(pointer, name)
    match name {
      "op" =>
        match field_value {
          String("set" | "merge" | "append" | "remove" as op) =>
            op_name = Some(op)
          _ =>
            self.error(
              field, "must be \"set\", \"merge\", \"append\" or \"remove\"",
            )
        }
      "bucket" => bucket = self.name(field, field_value)
      "value" =>
        match
          @template.Structured::parse(
            field_value,
            pointer=template_pointer(stub_pointer, field),
            env=self.env,
            buckets=buckets.templates,
            value="a data write's value",
          ) {
          Ok(template) => value = Some(template)
          Err(problems) =>
            for problem in problems {
              self.report_template_problem(stub_pointer, problem)
            }
        }
      "key" => self.string(field, field_value) |> ignore
      _ => self.unknown_field(field)
    }
  }
  self.require(members, pointer, "op")
  self.require(members, pointer, "bucket")
  let key_pointer = child_pointer(pointer, "key")
  // The members each op takes: `remove` takes `key` alone, `append`
  // `value` alone, and `set` and `merge` `value` and, optionally, `key`.
  if op_name is Some(op) {
    if op == "remove" {
      self.require(members, pointer, "key")
      if members.contains("value") {
        self.error(child_pointer(pointer, "value"), "\"remove\" takes no value")
      }
    } else {
      self.require(members, pointer, "value")
      if op == "append" && members.contains("key") {
        self.error(key_pointer, "\"append\" takes no key")
      }
    }
  }
  if bucket is Some(name) {
    match buckets.keyed.get(name) {
      None =>
        self.error(
          child_pointer(pointer, "bucket"),
          "the Mock has no Data bucket \{name.escape()}",
        )
      Some(true) =>
        self.error(
          child_pointer(pointer, "bucket"),
          "the Data bucket \{name.escape()} is keyed, and dataWrites cannot write to a keyed bucket yet",
        )
      Some(false) =>
        if members.contains("key") && op_name != Some("append") {
          self.error(
            key_pointer,
            "is allowed only on a keyed bucket, and the Data bucket \{name.escape()} has no \"key\"",
          )
        }
    }
  }
  // A literal value that already breaks its op never loads.
  if op_name == Some("merge") &&
    value is Some(template) &&
    template.literal() is Some(literal) &&
    !(literal is Object(_)) {
    self.error(
      child_pointer(pointer, "value"),
      "must be an object: \"merge\" merges the members of an object into the bucket",
    )
  }
  guard self.diagnostics.length() == problems &&
    bucket is Some(bucket) &&
    value is Some(value) else {
    return None
  }
  let op : DataOp = match op_name {
    Some("merge") => Merge
    Some("append") => Append
    _ => Replace
  }
  Some({ op, bucket, value, })
}
