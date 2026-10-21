///|
/// The deepest the file nests collections, empty ones included: the limit
/// of the parsers, which the loader and the YAML writer share.
let max_nesting : Int = 1024

///|
/// How deep a body may nest collections: the file's root, `stubs`, the
/// Stub and its `response` hold it.
let body_nesting : Int = max_nesting - 4

///|
/// The most items a sampled array has.
let max_sample_items : Int = 100

///|
/// The sample of each `format` that has its own, from the table in the
/// guide. Any other format gives the sample of a string without one.
let format_samples : Map[String, String] = {
  "date-time": "2000-01-01T00:00:00Z",
  "date": "2000-01-01",
  "time": "00:00:00Z",
  "duration": "P1D",
  "email": "user@example.com",
  "idn-email": "user@example.com",
  "hostname": "example.com",
  "idn-hostname": "example.com",
  "ipv4": "192.0.2.1",
  "ipv6": "2001:db8::1",
  "uri": "https://example.com/",
  "uri-reference": "https://example.com/",
  "iri": "https://example.com/",
  "iri-reference": "https://example.com/",
  "uri-template": "https://example.com/{id}",
  "uuid": "00000000-0000-4000-8000-000000000000",
  "json-pointer": "/a",
  "relative-json-pointer": "0",
  "regex": ".*",
  "byte": "c3RyaW5n",
}

///|
/// The names of the JSON Schema types.
let type_names : Array[String] = [
  "null", "boolean", "object", "array", "number", "integer", "string",
]

///|
/// The keywords that make a schema without `type` an object.
let object_keywords : Array[String] = [
  "properties", "required", "additionalProperties", "patternProperties", "propertyNames",
  "minProperties", "maxProperties",
]

///|
/// The keywords that make a schema without `type` an array.
let array_keywords : Array[String] = [
  "items", "prefixItems", "contains", "minItems", "maxItems", "uniqueItems",
]

///|
/// The keywords that make a schema without `type` a number.
let number_keywords : Array[String] = [
  "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
]

///|
/// The keywords that make a schema without `type` a string, besides a
/// `format` that is not a number's.
let string_keywords : Array[String] = ["minLength", "maxLength", "pattern"]

///|
/// Draws one fixed sample from a schema. The sample depends only on the
/// schema: nothing is random. A keyword that the sampler reads but that has
/// the wrong type is ignored, with a warning at its pointer.
priv struct Sampler {
  report : Report
  /// Whether the document is OpenAPI 3.0, whose schemas have no
  /// `examples`.
  v30 : Bool
}

///|
/// The sampler for the schemas of `document`.
fn Report::sampler(self : Report, document : Document) -> Sampler {
  { report: self, v30: document.openapi.has_prefix("3.0."), }
}

///|
/// Whether `json`, at `pointer`, is a schema: an object, or `true` or
/// `false`. When it is not, it is ignored, with a warning.
fn Sampler::is_schema(self : Sampler, pointer : String, json : Json) -> Bool {
  guard json is (Object(_) | True | False) else {
    self.report.root_warning(
      pointer, "ignored: must be a schema, an object or a boolean",
    )
    return false
  }
  true
}

///|
/// The sample of the schema `json` at `pointer`, whose collections may
/// nest `room` levels deep, or `None` when it gives no value: it is
/// `false`, or a value it names would nest deeper than `room`. Per schema,
/// the first of `const`, the first of `examples` (from 3.1), `example`,
/// `default` and the first of `enum` gives the sample, as written. Else the
/// type does.
fn Sampler::sample(
  self : Sampler,
  pointer : String,
  json : Json,
  room : Int,
) -> Json? {
  let schema = match json {
    Object(schema) => schema
    False => return None
    _ => return Some(Json::null())
  }
  // Until schema references are followed.
  if schema.get("$ref") is Some(_) {
    self.report.root_error(
      @definitions.child_pointer(pointer, "$ref"),
      "schema references are not followed yet: write the schema it names in its place",
    )
    return Some(Json::null())
  }
  if schema.get("const") is Some(value) {
    return self.copied(
      @definitions.child_pointer(pointer, "const"),
      value,
      room,
    )
  }
  if !self.v30 &&
    self.first_of(pointer, schema, "examples") is Some((at, value)) {
    return self.copied(at, value, room)
  }
  if schema.get("example") is Some(value) {
    return self.copied(
      @definitions.child_pointer(pointer, "example"),
      value,
      room,
    )
  }
  if schema.get("default") is Some(value) {
    return self.copied(
      @definitions.child_pointer(pointer, "default"),
      value,
      room,
    )
  }
  if self.first_of(pointer, schema, "enum") is Some((at, value)) {
    return self.copied(at, value, room)
  }
  match self.type_of(pointer, schema) {
    "boolean" => Some(Json::boolean(true))
    // Until numbers are sampled within their bounds.
    "number" | "integer" => Some(Json::number(0))
    "string" => Some(Json::string(self.string(pointer, schema)))
    "array" => Some(self.array(pointer, schema, room))
    "object" => Some(self.object(pointer, schema, room))
    _ => Some(Json::null())
  }
}

///|
/// The first item of the array `keyword` of `schema`, and its pointer, or
/// `None` when the array is empty or absent. A value that is not an array
/// is ignored, with a warning.
fn Sampler::first_of(
  self : Sampler,
  pointer : String,
  schema : Map[String, Json],
  keyword : String,
) -> (String, Json)? {
  let at = @definitions.child_pointer(pointer, keyword)
  match schema.get(keyword) {
    None | Some(Array([])) => None
    Some(Array(items)) => Some((@definitions.child_pointer(at, "0"), items[0]))
    Some(_) => {
      self.report.root_warning(at, "ignored: must be an array")
      None
    }
  }
}

///|
/// `value`, written at `pointer`, copied as data, so that a `$ref` member
/// in it stays as written; or `None` when it would nest deeper than `room`
/// levels, which the parsers would not read back. It is then left out,
/// with a warning.
fn Sampler::copied(
  self : Sampler,
  pointer : String,
  value : Json,
  room : Int,
) -> Json? {
  if nests_deeper(value, room) {
    self.report.root_warning(
      pointer,
      "left out: the value would nest deeper than \{max_nesting} levels in the file, the most the parsers read",
    )
    return None
  }
  Some(value)
}

///|
/// Whether `json` nests more than `levels` collections, empty ones
/// included.
fn nests_deeper(json : Json, levels : Int) -> Bool {
  match json {
    Array(items) => {
      if levels <= 0 {
        return true
      }
      for item in items {
        if nests_deeper(item, levels - 1) {
          return true
        }
      }
      false
    }
    Object(members) => {
      if levels <= 0 {
        return true
      }
      for _, value in members {
        if nests_deeper(value, levels - 1) {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
/// The type of `schema`: the first type other than `null` in a type
/// array, and `null` when it is the only one. Without a type, the one the
/// keywords imply, tried in this order: object, array, integer, number,
/// then string; else `null`.
fn Sampler::type_of(
  self : Sampler,
  pointer : String,
  schema : Map[String, Json],
) -> String {
  match schema.get("type") {
    None => ()
    Some(String(name)) if type_names.contains(name) => return name
    Some(Array(names)) if names.length() > 0 &&
      names
      .iter()
      .all(name => name is String(name) && type_names.contains(name)) => {
      for name in names {
        if name is String(name) && name != "null" {
          return name
        }
      }
      return "null"
    }
    Some(_) =>
      self.report.root_warning(
        @definitions.child_pointer(pointer, "type"),
        "ignored: must be a type, such as \"string\", or a non-empty array of types",
      )
  }
  let format = self.format(pointer, schema)
  if object_keywords.iter().any(keyword => schema.contains(keyword)) {
    "object"
  } else if array_keywords.iter().any(keyword => schema.contains(keyword)) {
    "array"
  } else if format is Some("int32" | "int64") {
    "integer"
  } else if format is Some("float" | "double") ||
    number_keywords.iter().any(keyword => schema.contains(keyword)) {
    "number"
  } else if format is Some(_) ||
    string_keywords.iter().any(keyword => schema.contains(keyword)) {
    "string"
  } else {
    "null"
  }
}

///|
/// The `format` of `schema`, or `None` when it has none. One that is not a
/// string is ignored, with a warning.
fn Sampler::format(
  self : Sampler,
  pointer : String,
  schema : Map[String, Json],
) -> String? {
  match schema.get("format") {
    None => None
    Some(String(format)) => Some(format)
    Some(_) => {
      self.report.root_warning(
        @definitions.child_pointer(pointer, "format"),
        "ignored: must be a string",
      )
      None
    }
  }
}

///|
/// The non-negative integer `keyword` of `schema`, or `None` when it has
/// none. A value of another type is ignored, with a warning. One above the
/// largest `Int` counts as it.
fn Sampler::count(
  self : Sampler,
  pointer : String,
  schema : Map[String, Json],
  keyword : String,
) -> Int? {
  match schema.get(keyword) {
    None => None
    Some(Number(n, ..)) if n >= 0.0 && n == n.floor() =>
      Some(if n >= 2147483647.0 { 2147483647 } else { n.to_int() })
    Some(_) => {
      self.report.root_warning(
        @definitions.child_pointer(pointer, keyword),
        "ignored: must be a non-negative integer",
      )
      None
    }
  }
}

///|
/// The sample of a string: the one of its `format` when the format has
/// one, whatever its length bounds; else `"string"`, repeated or cut to
/// fit `minLength` and `maxLength`.
fn Sampler::string(
  self : Sampler,
  pointer : String,
  schema : Map[String, Json],
) -> String {
  if self.format(pointer, schema) is Some(format) &&
    format_samples.get(format) is Some(sample) {
    return sample
  }
  let word = "string"
  let min = self.count(pointer, schema, "minLength")
  let max = self.count(pointer, schema, "maxLength")
  let mut length = word.length()
  if max is Some(max) && length > max {
    length = max
  }
  if min is Some(min) && length < min {
    length = min
  }
  let sample = StringBuilder()
  for i in 0..<length {
    sample.write_char(word.unsafe_get(i % word.length()).unsafe_to_char())
  }
  sample.to_string()
}

///|
/// The sample of an array: `minItems` items, at least 1 and at most 100,
/// with a warning past 100, and none when `maxItems` is 0. The items come
/// from `prefixItems`, then `items`, and stop where neither gives one.
fn Sampler::array(
  self : Sampler,
  pointer : String,
  schema : Map[String, Json],
  room : Int,
) -> Json {
  let items : Array[Json] = []
  let min = self.count(pointer, schema, "minItems")
  if self.count(pointer, schema, "maxItems") is Some(0) {
    return Json::array(items)
  }
  let mut length = 1
  if min is Some(min) && min > length {
    length = min
  }
  if length > max_sample_items {
    self.report.root_warning(
      @definitions.child_pointer(pointer, "minItems"),
      "changed: the sample has \{max_sample_items} items, the most a sample has, not \{length}",
    )
    length = max_sample_items
  }
  let prefix = match schema.get("prefixItems") {
    None => []
    Some(Array(prefix)) => prefix
    Some(_) => {
      self.report.root_warning(
        @definitions.child_pointer(pointer, "prefixItems"),
        "ignored: must be an array",
      )
      []
    }
  }
  // Every item after `prefixItems` is the same sample of `items`.
  let mut rest : Json? = None
  let mut rest_drawn = false
  for i in 0..<length {
    let item = if i < prefix.length() {
      let at = @definitions.child_pointer(
        @definitions.child_pointer(pointer, "prefixItems"),
        i.to_string(),
      )
      if !self.is_schema(at, prefix[i]) {
        break
      }
      self.sample(at, prefix[i], room - 1)
    } else {
      if !rest_drawn {
        rest_drawn = true
        let at = @definitions.child_pointer(pointer, "items")
        rest = match schema.get("items") {
          Some(json) if self.is_schema(at, json) =>
            self.sample(at, json, room - 1)
          _ => None
        }
      }
      rest
    }
    guard item is Some(item) else { break }
    items.push(item)
  }
  Json::array(items)
}

///|
/// The sample of an object: every property in `properties`, required or
/// not, in the order written, except `writeOnly` ones and those whose
/// schema is `false`.
fn Sampler::object(
  self : Sampler,
  pointer : String,
  schema : Map[String, Json],
  room : Int,
) -> Json {
  let members : Map[String, Json] = Map([])
  let at = @definitions.child_pointer(pointer, "properties")
  match schema.get("properties") {
    None => ()
    Some(Object(properties)) =>
      for name, json in properties {
        let property = @definitions.child_pointer(at, name)
        if !self.is_schema(property, json) || self.write_only(property, json) {
          continue
        }
        if self.sample(property, json, room - 1) is Some(value) {
          members[name] = value
        }
      }
    Some(_) => self.report.root_warning(at, "ignored: must be an object")
  }
  Json::object(members)
}

///|
/// Whether the schema `json` at `pointer` is `writeOnly`, so that a
/// response leaves it out. In 3.0, the fields beside a `$ref` are ignored.
fn Sampler::write_only(self : Sampler, pointer : String, json : Json) -> Bool {
  guard json is Object(schema) else { return false }
  if self.v30 && schema.contains("$ref") {
    return false
  }
  match schema.get("writeOnly") {
    None | Some(False) => false
    Some(True) => true
    Some(_) => {
      self.report.root_warning(
        @definitions.child_pointer(pointer, "writeOnly"),
        "ignored: must be true or false",
      )
      false
    }
  }
}
