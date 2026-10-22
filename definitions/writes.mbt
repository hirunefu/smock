// A Stub's `dataWrites`: writes to the Data buckets of its Mock, applied
// in order when the Stub matches, together with its `variables`, all or
// nothing.

///|
/// One write of a Stub's `dataWrites`: what it does, the bucket it writes
/// to, and the templates of its key and its value.
pub struct DataWrite {
  op : DataOp
  /// The name of the bucket written to, one of the buckets of the Stub's
  /// Mock when the Stub was read.
  bucket : String
  /// The template of the key of the one item written to, when the write
  /// has `key`: a text template whose pointer is `/dataWrites/<i>/key`,
  /// always parsed, whose output is compared as a key text. Only a write
  /// to a keyed bucket has it: `set` and `merge` may, and `remove` always
  /// does.
  key : @template.Text?
  /// The template of the value, a structured template whose pointer is
  /// `/dataWrites/<i>/value`, parsed whether or not a response has
  /// `template` on. Every op but `remove` has one.
  value : @template.Structured?
} derive(Debug, Eq)

///|
/// What a write does to its bucket, by its `op`.
pub enum DataOp {
  /// `set`: the bucket becomes the value; with a key, the item with that
  /// key does, in its place.
  Replace
  /// `merge`: the members of the value, an object, are merged into the
  /// bucket, which holds an object, or with a key into the item with that
  /// key: each replaces the member of the same name in its place, or is
  /// added at the end.
  Merge
  /// `append`: the value is appended to the bucket, which holds an array.
  /// In a keyed bucket, it is an item, which gets a new key when it has
  /// none.
  Append
  /// `remove`: the item with the key is removed from the keyed bucket.
  Remove
} derive(Debug, Eq)

///|
/// The op's name, as `dataWrites` writes it: `set`, `merge`, `append` or
/// `remove`.
pub fn DataOp::name(self : DataOp) -> String {
  match self {
    Replace => "set"
    Merge => "merge"
    Append => "append"
    Remove => "remove"
  }
}

///|
/// The most writes a Stub's `dataWrites` holds.
pub let max_data_writes : Int = 100

///|
/// What a Stub without `dataWrites` writes: nothing.
let no_data_writes : ReadOnlyArray[DataWrite] = ReadOnlyArray::from_array([])

///|
/// What a Stub that names a Data bucket knows of the bucket's `key` when it
/// is read.
priv enum BucketKey {
  /// The bucket has no `key`.
  Unkeyed
  /// The bucket is keyed by this member.
  KeyedBy(String)
  /// The bucket's `key` is not a member name, a problem reported where the
  /// bucket is read, so a Stub checks nothing that depends on it.
  Malformed
}

///|
/// The Data buckets of one Mock, as the Stubs of the Mock see them when
/// they are read: the names their templates may read, and the key of each.
priv struct MockBuckets {
  /// The buckets templates may read as `data.NAME`.
  templates : @template.Buckets
  /// The key of each bucket, by its name.
  keys : Map[String, BucketKey]
}

///|
/// The buckets `keys` names, each with its key.
fn MockBuckets::new(keys : Map[String, BucketKey]) -> MockBuckets {
  { templates: @template.Buckets(keys.keys().collect()), keys, }
}

///|
/// The key of the bucket named `name`, which a Stub names at `pointer` in
/// `file`. When the Mock declares no such bucket, it is reported there,
/// and there is none.
fn MockBuckets::lookup(
  self : MockBuckets,
  file : File,
  pointer : String,
  name : String,
) -> BucketKey? {
  let key = self.keys.get(name)
  if key is None {
    file.error(pointer, "the Mock has no Data bucket \{name.escape()}")
  }
  key
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
/// and `key`, a text template, always parsed. Returns the writes in the
/// order written.
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
  // Whether the write has a problem: whether any is reported from here on.
  let reported = self.diagnostics.length()
  // The op, when it is one of the four.
  let mut op : DataOp? = None
  let mut bucket = None
  let mut key = None
  let mut value = None
  for name, field_value in members {
    let field = child_pointer(pointer, name)
    match name {
      "op" =>
        match field_value {
          String("set") => op = Some(Replace)
          String("merge") => op = Some(Merge)
          String("append") => op = Some(Append)
          String("remove") => op = Some(Remove)
          _ =>
            self.error(
              field, "must be \"set\", \"merge\", \"append\" or \"remove\"",
            )
        }
      "bucket" => bucket = self.name(field, field_value)
      "key" =>
        if self.string(field, field_value) is Some(source) {
          match
            @template.Text::parse(
              source,
              pointer=template_pointer(stub_pointer, field),
              kind=Body(Plain),
              env=self.env,
              buckets=buckets.templates,
            ) {
            Ok(template) => key = Some(template)
            Err(problem) => self.report_template_problem(stub_pointer, problem)
          }
        }
      "value" =>
        match
          @template.Structured::parse(
            field_value,
            pointer=template_pointer(stub_pointer, field),
            env=self.env,
            buckets=buckets.templates,
            role="a data write's value",
          ) {
          Ok(template) => value = Some(template)
          Err(problems) =>
            for problem in problems {
              self.report_template_problem(stub_pointer, problem)
            }
        }
      _ => self.unknown_field(field)
    }
  }
  self.require(members, pointer, "op")
  self.require(members, pointer, "bucket")
  let key_pointer = child_pointer(pointer, "key")
  let value_pointer = child_pointer(pointer, "value")
  let has_key = members.contains("key")
  // The members each op takes: `remove` takes `key` alone, `append`
  // `value` alone, and `set` and `merge` `value` and, optionally, `key`.
  if op is Some(op) {
    if op is Remove {
      self.require(members, pointer, "key")
      if members.contains("value") {
        self.error(value_pointer, "\"remove\" takes no value")
      }
    } else {
      self.require(members, pointer, "value")
      if op is Append && has_key {
        self.error(key_pointer, "\"append\" takes no key")
      }
    }
  }
  // A literal value that already breaks its op never loads.
  let literal = match value {
    Some(template) => template.literal()
    None => None
  }
  // The key of the bucket, when the Mock declares it.
  let mut bucket_key = None
  if bucket is Some(name) {
    bucket_key = buckets.lookup(self, child_pointer(pointer, "bucket"), name)
    match bucket_key {
      None => ()
      Some(Unkeyed) =>
        if has_key && !(op is Some(Append)) {
          self.error(
            key_pointer,
            "is allowed only on a keyed bucket, and the Data bucket \{name.escape()} has no \"key\"",
          )
        }
      Some(KeyedBy(_) | Malformed) =>
        if op is Some(Merge) && !has_key {
          self.error(
            pointer,
            "\"merge\" into the keyed Data bucket \{name.escape()} needs \"key\": the bucket holds an array, and \"merge\" with \"key\" merges into one of its items",
          )
        }
    }
  }
  match (bucket_key, literal) {
    // A `key` that is reported as wrong checks nothing more.
    (Some(Malformed), _) | (_, None) => ()
    (Some(KeyedBy(key_member)), Some(literal)) => {
      // The key written to, when it is literal text.
      let literal_key = match key {
        Some(template) => template.literal()
        None => None
      }
      self.check_keyed_literal(
        value_pointer, op, has_key, literal_key, key_member, literal,
      )
    }
    (Some(Unkeyed) | None, Some(literal)) =>
      if op is Some(Merge) && !(literal is Object(_)) {
        self.error(
          value_pointer, "must be an object: \"merge\" merges the members of an object into the bucket",
        )
      }
  }
  guard self.diagnostics.length() == reported &&
    bucket is Some(bucket) &&
    op is Some(op) else {
    return None
  }
  Some({ op, bucket, key, value, })
}

///|
/// Reports how `literal`, the literal value at `pointer` of a write whose
/// op is `op`, with `key` or not as `has_key` says, breaks its op on a
/// bucket keyed by the member `key_member`, if it does: an item that `set`
/// or `merge` with `key` writes, or that `append` adds, must be an object,
/// and its key member must hold a key; that of `set` or `merge` with `key`
/// must also hold the key written to, `key`, when that is literal text; and
/// the value of `set` without `key` must keep the rules of keyed buckets.
fn File::check_keyed_literal(
  self : File,
  pointer : String,
  op : DataOp?,
  has_key : Bool,
  key : String?,
  key_member : String,
  literal : Json,
) -> Unit {
  match (op, has_key) {
    (Some(Replace), true) =>
      match literal {
        Object(item) => self.check_kept_key(pointer, item, key, key_member)
        _ =>
          self.error(
            pointer, "must be an object: \"set\" with \"key\" makes one item of the keyed bucket this value",
          )
      }
    (Some(Merge), true) =>
      match literal {
        Object(item) => self.check_kept_key(pointer, item, key, key_member)
        _ =>
          self.error(
            pointer, "must be an object: \"merge\" with \"key\" merges the members of an object into one item",
          )
      }
    (Some(Append), _) =>
      match literal {
        Object(item) =>
          if item.get(key_member) is Some(key) && key_text(key) is None {
            self.error(child_pointer(pointer, key_member), not_a_key)
          }
        _ =>
          self.error(
            pointer, "must be an object: \"append\" adds an item to the keyed bucket",
          )
      }
    (Some(Replace), false) =>
      for problem in keyed_problems(literal, key=key_member) {
        self.error(pointer + problem.pointer, problem.message)
      }
    // A `merge` without `key` is reported where the write is read, and a
    // `remove` has no value.
    (Some(Merge), false) | (Some(Remove), _) | (None, _) => ()
  }
}

///|
/// Reports how the key member `key_member` of `item`, the literal value at
/// `pointer` of a `set` or `merge` with a key, fails to keep the item
/// written to the item it is, if it does, as a request would find it: the
/// member may be absent, and else must hold a key, and the key written to,
/// `key`, when that is literal text.
fn File::check_kept_key(
  self : File,
  pointer : String,
  item : Map[String, Json],
  key : String?,
  key_member : String,
) -> Unit {
  guard item.get(key_member) is Some(held) else { return }
  let at = child_pointer(pointer, key_member)
  match key_text(held) {
    None => self.error(at, not_a_key)
    Some(text) =>
      if key is Some(key) && text != key {
        self.error(
          at,
          "must be absent or hold the item's key \{key.escape()}, and it holds the key \{text.escape()}",
        )
      }
  }
}
