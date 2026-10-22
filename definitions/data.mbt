// Data buckets: named JSON values that Mocks declare under the top-level
// `data` of Definition files, each with its initial value, inline or in a
// JSON file of the body-file subdirectory. This file also holds the rules
// of keyed buckets, in one place, since every write that changes a keyed
// bucket keeps them too.

///|
/// A Data bucket: a named JSON value that a Mock declares in Definition
/// files, with its initial value. Each Session reads and writes its own
/// copy; until it writes, it reads the initial value.
pub struct DataBucket {
  /// The bucket's name, unique within its Mock, as `is_bucket_name` allows.
  name : String
  /// The member that holds each item's key, when the bucket is keyed. Its
  /// value is then always an array of objects with unique keys, as
  /// `keyed_problems` checks.
  key : String?
  /// How a keyed bucket makes new keys: `Integer` unless `newKey` says
  /// otherwise. A bucket without `key` makes none.
  new_key : NewKey
  /// The initial value: static JSON, never templated, as written inline or
  /// read from the bucket's JSON file.
  initial : Json
} derive(Debug, Eq)

///|
/// How a keyed bucket makes new keys.
pub enum NewKey {
  /// One more than the highest integer key.
  Integer
  /// A version 4 UUID.
  Uuid
} derive(Debug, Eq)

///|
/// The way's name, as `newKey` writes it: `integer` or `uuid`.
pub fn NewKey::name(self : NewKey) -> String {
  match self {
    Integer => "integer"
    Uuid => "uuid"
  }
}

///|
/// Whether `name` can name a Data bucket: 1 to 128 name characters, which
/// are ASCII letters, digits, `_` and `-`, as for a Variable. So
/// `data.NAME` needs no quotes, and a URL no escapes.
pub fn is_bucket_name(name : String) -> Bool {
  is_variable_name(name)
}

///|
/// The largest integer key, 2^53 - 1, and the smallest is its negative: up
/// to it, a JSON number holds every integer exactly.
pub let max_integer_key : Int64 = 9_007_199_254_740_991L

///|
/// The text of `json` as a key of a keyed bucket, or `None` when it cannot
/// be a key. A key is a non-empty string without `/`, whose text is the
/// string, or an integer: a number whose value is a whole number from
/// `-max_integer_key` to `max_integer_key`, whose text is its decimal
/// digits, with `-` when it is negative and no leading zeros. So `42`,
/// `42.0` and `4.2e1` all have the text `42`, which the string `"42"` has
/// too.
///
/// `/` is refused because a path segment cannot carry it once
/// percent-decoded, so an item with such a key could never be reached.
pub fn key_text(json : Json) -> String? {
  match json {
    String(text) if text != "" && !text.contains("/") => Some(text)
    Number(n, ..) if n == n.floor() &&
      n >= -max_integer_key.to_double() &&
      n <= max_integer_key.to_double() => Some(n.to_int64().to_string())
    _ => None
  }
}

///|
/// What is wrong with a key member that holds no key, as `key_text` says.
pub let not_a_key : String = "must be a key: a non-empty string without /, or an integer from \{-max_integer_key} to \{max_integer_key}"

///|
/// A way the value of a keyed bucket breaks the rules of keyed buckets: a
/// JSON Pointer (RFC 6901) into the value, `""` for the value itself, and
/// what is wrong there.
pub(all) struct KeyedProblem {
  pointer : String
  message : String
} derive(Debug, Eq)

///|
/// Every way `value` breaks the rules of a bucket keyed by the member
/// `key`, in the order of its items; none when it keeps them. The value
/// must be an array of objects. Each object must have the member `key`,
/// taken literally (`a.b` is the member `a.b`), holding a key, as
/// `key_text` says, and no two may have keys with the same text.
pub fn keyed_problems(value : Json, key~ : String) -> Array[KeyedProblem] {
  guard value is Array(items) else {
    return [
      {
        pointer: "",
        message: "must be an array of objects, since the bucket has \"key\"",
      },
    ]
  }
  let problems = []
  // The index of the item that has each key text so far.
  let seen : Map[String, Int] = Map([])
  for i, item in items {
    let at = child_pointer("", i.to_string())
    guard item is Object(members) else {
      problems.push({
        pointer: at,
        message: "must be an object with the key member \{key.escape()}",
      })
      continue
    }
    guard members.get(key) is Some(key_value) else {
      problems.push({
        pointer: at,
        message: "needs the key member \{key.escape()}",
      })
      continue
    }
    let member_at = child_pointer(at, key)
    match key_text(key_value) {
      None => problems.push({ pointer: member_at, message: not_a_key, })
      Some(text) =>
        match seen.get(text) {
          Some(earlier) =>
            problems.push({
              pointer: member_at,
              message: "has the key text \{text.escape()}, as item \{earlier} does",
            })
          None => seen[text] = i
        }
    }
  }
  problems
}

///|
/// The names of the Data buckets that the parsed files declare, by the
/// name of their Mock, in declaration order, each with its key, so that a
/// Stub may read and write a bucket declared in any file, earlier or
/// later. A `key` that is not a string, or is empty, a problem reported
/// where the bucket is read, is `Malformed`.
fn declared_buckets(
  files : Array[(String, Result[Map[String, Json], Diagnostic])],
) -> Map[String, Map[String, BucketKey]] {
  let names : Map[String, Map[String, BucketKey]] = Map([])
  for file in files {
    guard file.1 is Ok(top) && top.get("data") is Some(Array(entries)) else {
      continue
    }
    for entry in entries {
      guard entry is Object(entry) &&
        entry.get("mock") is Some(String(mock)) &&
        entry.get("name") is Some(String(name)) else {
        continue
      }
      let key = match entry.get("key") {
        Some(String(key)) if key != "" => KeyedBy(key)
        Some(_) => Malformed
        None => Unkeyed
      }
      match names.get(mock) {
        Some(declared) => declared[name] = key
        None => names[mock] = Map([(name, key)])
      }
    }
  }
  names
}

///|
/// Reads a Data bucket, the entry at `pointer`, and returns the name of its
/// Mock with it. It has none when it lacks a usable Mock, name or initial
/// value.
fn File::read_bucket(
  self : File,
  pointer : String,
  json : Json,
) -> (String, DataBucket)? {
  guard json is Object(entry) else {
    self.error(pointer, "must be an object")
    return None
  }
  let mut mock = None
  let mut name = None
  let mut initial = None
  let mut key = None
  let mut new_key = Integer
  for field_name, value in entry {
    let field = child_pointer(pointer, field_name)
    match field_name {
      "mock" => mock = self.name(field, value)
      "name" =>
        match value {
          String(value) if is_bucket_name(value) => name = Some(value)
          _ =>
            self.error(
              field, "is not a Data bucket name: 1 to 128 ASCII letters, digits, _ and -",
            )
        }
      "json" => initial = Some(value)
      "jsonFile" => initial = self.read_json_file(field, value)
      "key" => key = self.name(field, value)
      "newKey" =>
        match value {
          String("integer") => new_key = Integer
          String("uuid") => new_key = Uuid
          _ => self.error(field, "must be \"integer\" or \"uuid\"")
        }
      _ => self.unknown_field(field)
    }
  }
  self.require(entry, pointer, "mock")
  self.require(entry, pointer, "name")
  match (entry.contains("json"), entry.contains("jsonFile")) {
    (true, true) =>
      self.error(
        pointer, "has \"json\" and \"jsonFile\"; give exactly one of them",
      )
    (false, false) => self.error(pointer, "needs \"json\" or \"jsonFile\"")
    _ => ()
  }
  if entry.contains("newKey") && !entry.contains("key") {
    self.error(
      child_pointer(pointer, "newKey"),
      "is allowed only with \"key\": only a keyed bucket makes new keys",
    )
  }
  guard mock is Some(mock) && name is Some(name) && initial is Some(initial) else {
    return None
  }
  if key is Some(key) {
    let problems = keyed_problems(initial, key~)
    for problem in problems {
      if entry.get("jsonFile") is Some(String(path)) {
        self.error(
          child_pointer(pointer, "jsonFile"),
          in_json_file(path, problem.pointer, problem.message),
        )
      } else {
        self.error(
          child_pointer(pointer, "json") + problem.pointer,
          problem.message,
        )
      }
    }
  }
  Some((mock, { name, key, new_key, initial, }))
}

///|
/// Reads the JSON file a `jsonFile` names, the value `json` at `pointer`: a
/// body file, with the path rules of `bodyFile`, that holds JSON in UTF-8.
/// It has none, and the problem is reported, when the file is missing, is
/// not UTF-8, is not JSON or repeats a key in one object.
fn File::read_json_file(self : File, pointer : String, json : Json) -> Json? {
  guard self.string(pointer, json) is Some(path) else { return None }
  guard self.body_file(pointer, path) is Some(bytes) else { return None }
  let problem = (at : String, message : String) => {
    self.error(pointer, in_json_file(path, at, message))
    None
  }
  let text = @utf8.decode(bytes) catch {
    _ => return problem("", "not valid UTF-8")
  }
  let value = @json.parse(text) catch {
    err => return problem("", "not valid JSON: \{err}")
  }
  if first_duplicate_key(text) is Some(at) {
    return problem(at, "duplicate key")
  }
  Some(value)
}

///|
/// The message of a problem at `pointer` in the JSON file `path`, which a
/// `jsonFile` names, such as `"orders.json" at /2/id: needs …`.
fn in_json_file(path : String, pointer : String, message : String) -> String {
  if pointer == "" {
    "\{path.escape()}: \{message}"
  } else {
    "\{path.escape()} at \{pointer}: \{message}"
  }
}

///|
/// Declares `bucket`, of the Mock `mock`, at `pointer` in `file`, unless no
/// file declares the Mock or an earlier bucket of the Mock has its name.
fn Reader::declare_bucket(
  self : Reader,
  file : File,
  pointer : String,
  mock : String,
  bucket : DataBucket,
) -> Unit {
  if !self.declared.contains(mock) {
    file.error(
      child_pointer(pointer, "mock"),
      "no file declares the Mock \{mock.escape()}",
    )
    return
  }
  let names = match self.bucket_names.get(mock) {
    Some(names) => names
    None => {
      let names = Map([])
      self.bucket_names[mock] = names
      names
    }
  }
  let name_pointer = child_pointer(pointer, "name")
  if names.get(bucket.name) is Some(earlier) {
    file.error(
      name_pointer,
      "the Data bucket name \{bucket.name.escape()} is already declared for the Mock \{mock.escape()} at \{earlier}",
    )
    return
  }
  names[bucket.name] = file.at(name_pointer)
  self.buckets.push((mock, bucket))
}
