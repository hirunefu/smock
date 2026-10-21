// Writes to keyed Data buckets: to one item, found by its key text, and
// appends, which give an item without a key a new one. These are the write
// operations of a CRUD Stub too. Each keeps the rules of keyed buckets,
// changes the working copy in place, records how to undo the change, and
// moves the copy's count by what the item changed.

///|
/// Why a write to a keyed Data bucket cannot be applied. A data write then
/// fails with the message `message` gives.
priv suberror KeyedFailure {
  /// No item has this key text.
  NoItem(String)
  /// The value, which must be an object, is not one.
  NotAnObject(Json)
  /// The value's key member holds what is given, which is not the key text
  /// of the item written to.
  OtherKey(Json, String)
  /// The key member of an item to add holds what is given, which is not a
  /// key.
  InvalidKey(Json)
  /// An item has this key text already.
  KeyTaken(String)
  /// No integer key is left: the next would pass
  /// `@definitions.max_integer_key`.
  NoNewKey
}

///|
/// What went wrong, as a failed data write of the op `op` says it: the
/// write was to the Data bucket `bucket`, keyed by the member
/// `key_member`.
fn KeyedFailure::message(
  self : KeyedFailure,
  bucket : String,
  key_member : String,
  op : @definitions.DataOp,
) -> String {
  match self {
    NoItem(key) =>
      "the Data bucket \{bucket.escape()} has no item with the key \{key.escape()}"
    NotAnObject(value) => {
      let what = match op {
        Replace => "\"set\" with \"key\""
        Merge => "\"merge\""
        Append | Remove => "\"\{op.name()}\" to a keyed bucket"
      }
      "the value of \{what} must be an object, and it is \{kind_of(value)}"
    }
    OtherKey(held, key) =>
      "the value's \{key_member.escape()} must be absent or hold the item's key \{key.escape()}, and it holds \{held_key(held)}"
    InvalidKey(held) =>
      "the value's \{key_member.escape()} \{@definitions.not_a_key}, and it holds \{held_key(held)}"
    KeyTaken(key) =>
      "the Data bucket \{bucket.escape()} already has an item with the key \{key.escape()}"
    NoNewKey =>
      "no new key: the next integer key of the Data bucket \{bucket.escape()} would pass \{@definitions.max_integer_key}"
  }
}

///|
/// What a key member holds, as messages name it: `the key "1003"`, or the
/// kind of what is not a key, such as `null`.
fn held_key(held : Json) -> String {
  match @definitions.key_text(held) {
    Some(text) => "the key \{text.escape()}"
    None => kind_of(held)
  }
}

///|
/// The message of a value that breaks the rules of the Data bucket
/// `bucket`, keyed by the member `key_member`, in each of the ways
/// `problems` gives: the first, and how many more there are.
fn broken_rules(
  bucket : String,
  key_member : String,
  problems : Array[@definitions.KeyedProblem],
) -> String {
  let first = problems[0]
  let at = if first.pointer == "" { "" } else { "\{first.pointer} " }
  let more = if problems.length() > 1 {
    " (and \{problems.length() - 1} more)"
  } else {
    ""
  }
  "the value breaks the rules of the Data bucket \{bucket.escape()}, keyed by \{key_member.escape()}: \{at}\{first.message}\{more}"
}

///|
/// The value of `key`, a key text, as an integer key: the number whose
/// text it is, when it is the text of one. `None` for the text of a string
/// key.
fn integer_key(key : String) -> Double? {
  let negative = key.has_prefix("-")
  let digits = if negative { key.view(start_offset=1) } else { key.view() }
  // No leading zeros, and no `-0`: the text of 0 is `0`.
  if digits.is_empty() ||
    (digits.has_prefix("0") && (negative || digits.length() > 1)) {
    return None
  }
  let mut value = 0L
  for c in digits {
    guard c >= '0' && c <= '9' else { return None }
    value = value * 10L + (c.to_int() - '0'.to_int()).to_int64()
    if value > @definitions.max_integer_key {
      return None
    }
  }
  let signed = if negative { -value } else { value }
  Some(signed.to_double())
}

///|
/// The index of the item of `items`, the value of a bucket keyed by the
/// member `key_member`, whose key text is `key`, if one has it. A string
/// key has the text it holds, and an integer key the text of its digits,
/// so no key text is written out to find an item.
fn item_index(items : Array[Json], key_member : String, key : String) -> Int? {
  let number = integer_key(key)
  for i, item in items {
    guard item is Object(members) else { continue }
    match members.get(key_member) {
      Some(String(text)) if text == key => return Some(i)
      Some(Number(n, ..)) if number is Some(k) && n == k => return Some(i)
      _ => ()
    }
  }
  None
}

///|
/// The value of `value`'s key member `key_member`, checked to keep the item
/// at index `j` of `items` the item it is: absent, or holding the item's
/// key text `key`. Returns the item's own key value, which the item keeps.
fn kept_key(
  items : Array[Json],
  j : Int,
  key_member : String,
  key : String,
  value : Map[String, Json],
) -> Json raise KeyedFailure {
  if value.get(key_member) is Some(held) &&
    @definitions.key_text(held) != Some(key) {
    raise OtherKey(held, key)
  }
  guard items[j] is Object(item) && item.get(key_member) is Some(stored) else {
    raise NoItem(key)
  }
  stored
}

///|
/// `set` with a key: the item with the key text `key`, in the bucket at
/// index `i`, keyed by `key_member`, becomes `value`, an object, in its
/// place. The value's key member may be absent, and is then added as its
/// last member, or hold the same key text; either way, the item keeps its
/// stored key value. Returns the item stored.
fn WorkingCopies::set_item(
  self : WorkingCopies,
  i : Int,
  bucket : @definitions.DataBucket,
  key_member : String,
  key : String,
  value : Json,
) -> Json raise KeyedFailure {
  guard value is Object(members) else { raise NotAnObject(value) }
  guard self.values[i] is Array(items) &&
    item_index(items, key_member, key) is Some(j) else {
    raise NoItem(key)
  }
  members[key_member] = kept_key(items, j, key_member, key, members)
  guard self.own(i, bucket.name) is Array(items) else { return value }
  let old = items[j]
  self.bytes[i] += value_bytes(value) - value_bytes(old)
  if self.sources[i] is Stored {
    self.changes.push(Replaced(items, j, old))
  }
  items[j] = value
  value
}

///|
/// `merge` with a key: a shallow merge of `value`, an object, into the item
/// with the key text `key`, in the bucket at index `i`, keyed by
/// `key_member`. Each member replaces the member of the same name in its
/// place, or is added at the end, and `null` is stored as null. The key
/// member follows the rule of `set_item`, and the item keeps its stored key
/// value. Returns the item after the merge.
fn WorkingCopies::merge_item(
  self : WorkingCopies,
  i : Int,
  bucket : @definitions.DataBucket,
  key_member : String,
  key : String,
  value : Json,
) -> Json raise KeyedFailure {
  guard value is Object(members) else { raise NotAnObject(value) }
  guard self.values[i] is Array(items) &&
    item_index(items, key_member, key) is Some(j) else {
    raise NoItem(key)
  }
  kept_key(items, j, key_member, key, members) |> ignore
  guard self.own(i, bucket.name) is Array(items) && items[j] is Object(item) else {
    return value
  }
  self.merge_members(i, item, members, except=Some(key_member))
  items[j]
}

///|
/// `remove`: the item with the key text `key` is removed from the bucket at
/// index `i`, keyed by `key_member`. Returns the item removed.
fn WorkingCopies::remove_item(
  self : WorkingCopies,
  i : Int,
  bucket : @definitions.DataBucket,
  key_member : String,
  key : String,
) -> Json raise KeyedFailure {
  guard self.values[i] is Array(items) &&
    item_index(items, key_member, key) is Some(j) else {
    raise NoItem(key)
  }
  guard self.own(i, bucket.name) is Array(items) else { return Json::null() }
  let removed = items.remove(j)
  // The comma before it, or after it when it was first, goes too.
  self.bytes[i] -= value_bytes(removed) +
    (if items.is_empty() { 0L } else { 1L })
  if self.sources[i] is Stored {
    self.changes.push(Removed(items, j, removed))
  }
  removed
}

///|
/// `append` to a keyed bucket: `value`, an object, is added at the end of
/// the bucket at index `i`, keyed by `key_member`. A key that is valid, and
/// that no item has, is kept. A value without the key member gets a new
/// key, as the bucket's `newKey` makes it, added as its last member; a new
/// `uuid` key draws from `rand`. Returns the item stored.
fn WorkingCopies::append_item(
  self : WorkingCopies,
  i : Int,
  bucket : @definitions.DataBucket,
  key_member : String,
  value : Json,
  rand : @prng.Generator,
) -> Json raise KeyedFailure {
  guard value is Object(members) else { raise NotAnObject(value) }
  guard self.values[i] is Array(items) else { return value }
  match members.get(key_member) {
    Some(held) => {
      guard @definitions.key_text(held) is Some(key) else {
        raise InvalidKey(held)
      }
      if item_index(items, key_member, key) is Some(_) {
        raise KeyTaken(key)
      }
    }
    None =>
      members[key_member] = new_key(items, key_member, bucket.new_key, rand)
  }
  guard self.own(i, bucket.name) is Array(items) else { return value }
  self.push_element(i, items, value)
  value
}

///|
/// A key that no item of `items`, the value of a bucket keyed by the member
/// `key_member`, has, made the way `way` says:
///
/// - `Integer`: one more than the highest integer key, or 1 when there is
///   none. String keys are not counted, but when one has the new key's
///   text, the next integer is tried, until one is free. Raises `NoNewKey`
///   when the new key would pass `@definitions.max_integer_key`.
/// - `Uuid`: a version 4 UUID drawn from `rand`, the request's helper
///   generator, as `fake.uuid()` draws it, and drawn again while an item
///   has it.
fn new_key(
  items : Array[Json],
  key_member : String,
  way : @definitions.NewKey,
  rand : @prng.Generator,
) -> Json raise KeyedFailure {
  match way {
    Integer => {
      let mut highest = None
      // The texts of the string keys that are also texts of integers, once
      // there is one.
      let mut taken : Set[String]? = None
      for item in items {
        guard item is Object(members) else { continue }
        match members.get(key_member) {
          Some(Number(n, ..)) => {
            let key = n.to_int64()
            if !(highest is Some(h) && h >= key) {
              highest = Some(key)
            }
          }
          Some(String(text)) if integer_key(text) is Some(_) =>
            match taken {
              Some(texts) => texts.add(text)
              None => taken = Some(Set::from_array([text]))
            }
          _ => ()
        }
      }
      let mut key = match highest {
        Some(h) => h + 1L
        None => 1L
      }
      while key <= @definitions.max_integer_key {
        guard taken is Some(texts) && texts.contains(key.to_string()) else {
          return Json::number(key.to_double())
        }
        key += 1L
      }
      raise NoNewKey
    }
    Uuid => {
      let mut key = @template.uuid(rand)
      while item_index(items, key_member, key) is Some(_) {
        key = @template.uuid(rand)
      }
      Json::string(key)
    }
  }
}
