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
/// The keywords that give a schema's sample as written, in the order they
/// are tried.
let value_keywords : Array[String] = [
  "const", "examples", "example", "default", "enum",
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
/// One schema object that a merged schema is made of, and where it is
/// written.
priv struct Layer {
  pointer : String
  schema : Map[String, Json]
  /// Whether it is a branch: one of `allOf`, the branch that `oneOf` or
  /// `anyOf` takes, or a property met again, rather than the schema
  /// itself.
  branch : Bool
}

///|
/// A schema merged with its branches, as one schema: the schema's own
/// keywords first, then each branch's, in order. For a keyword, the first
/// layer that has one gives it; `properties` are joined by name.
priv struct Merged {
  layers : Array[Layer]
  /// Whether one of them is the schema `false`, so that it gives no value.
  mut never : Bool
  /// Whether a `oneOf` or `anyOf` in it has only branches that are only
  /// null, so that the sample is null.
  mut only_null : Bool
}

///|
/// A merged schema with nothing in it yet.
fn Merged::new() -> Merged {
  { layers: [], never: false, only_null: false, }
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
/// `false`, or a value it names would nest deeper than `room`. The schema
/// is first merged with its branches.
fn Sampler::sample(
  self : Sampler,
  pointer : String,
  json : Json,
  room : Int,
) -> Json? {
  let merged = Merged::new()
  self.merge(merged, pointer, json, false)
  self.merged_sample(merged, room)
}

///|
/// Adds the schema `json` at `pointer` to `merged`, a `branch` or the
/// schema itself, then its branches: each of `allOf`, in order, then the
/// branch that `oneOf` takes, then the one that `anyOf` takes. `oneOf` and
/// `anyOf` take their first branch that is neither only null nor `false`,
/// which allows no value; when each branch is only null or `false`, the
/// sample is null if one is only null, and else there is no value. `true`
/// adds nothing, and `false`, as the schema or in `allOf`, leaves no
/// value.
fn Sampler::merge(
  self : Sampler,
  merged : Merged,
  pointer : String,
  json : Json,
  branch : Bool,
) -> Unit {
  let schema = match json {
    Object(schema) => schema
    False => {
      merged.never = true
      return
    }
    _ => return
  }
  merged.layers.push({ pointer, schema, branch, })
  let all_of = @definitions.child_pointer(pointer, "allOf")
  match schema.get("allOf") {
    None => ()
    Some(Array(branches)) =>
      for i, json in branches {
        let at = @definitions.child_pointer(all_of, i.to_string())
        if self.is_schema(at, json) {
          self.merge(merged, at, json, true)
        }
      }
    Some(_) => self.report.root_warning(all_of, "ignored: must be an array")
  }
  for keyword in ["oneOf", "anyOf"] {
    let one_of = @definitions.child_pointer(pointer, keyword)
    match schema.get(keyword) {
      None => ()
      Some(Array(branches)) => {
        let mut nulls = false
        let mut nevers = false
        let mut taken = false
        for i, json in branches {
          let at = @definitions.child_pointer(one_of, i.to_string())
          if !self.is_schema(at, json) {
            continue
          }
          if json is False {
            nevers = true
            continue
          }
          if is_only_null(json) {
            nulls = true
            continue
          }
          self.merge(merged, at, json, true)
          taken = true
          break
        }
        if !taken && nulls {
          merged.only_null = true
        } else if !taken && nevers {
          merged.never = true
        }
      }
      Some(_) => self.report.root_warning(one_of, "ignored: must be an array")
    }
  }
}

///|
/// Whether the schema `json` allows only null: its `type` is `"null"`, or
/// a type array of only `"null"`, or its `const` is null, or its `enum`
/// holds only null.
fn is_only_null(json : Json) -> Bool {
  guard json is Object(schema) else { return false }
  match schema.get("type") {
    Some(String("null")) => return true
    Some(Array(names)) if names.length() > 0 &&
      names.iter().all(name => name is String("null")) => return true
    _ => ()
  }
  match schema.get("const") {
    Some(Null) => return true
    _ => ()
  }
  match schema.get("enum") {
    Some(Array(values)) if values.length() > 0 &&
      values.iter().all(value => value is Null) => true
    _ => false
  }
}

///|
/// The sample of the merged schema `merged`, whose collections may nest
/// `room` levels deep, or `None` when it gives no value. Per keyword, the
/// first of `const`, the first of `examples` (from 3.1), `example`,
/// `default` and the first of `enum` gives the sample, as written. Else
/// the type does.
fn Sampler::merged_sample(self : Sampler, merged : Merged, room : Int) -> Json? {
  if merged.never {
    return None
  }
  // Until schema references are followed.
  let mut referenced = false
  for layer in merged.layers {
    if layer.schema.contains("$ref") {
      self.report.root_error(
        @definitions.child_pointer(layer.pointer, "$ref"),
        "schema references are not followed yet: write the schema it names in its place",
      )
      referenced = true
    }
  }
  if referenced || merged.only_null {
    return Some(Json::null())
  }
  if self.value(merged) is Some((at, value)) {
    return self.copied(at, value, room)
  }
  match self.type_of(merged) {
    "boolean" => Some(Json::boolean(true))
    "number" => Some(self.number(merged, false).to_json())
    "integer" => Some(self.number(merged, true).to_json())
    "string" => Some(Json::string(self.string(merged)))
    "array" => Some(self.array(merged, room))
    "object" => Some(self.object(merged, room))
    _ => Some(Json::null())
  }
}

///|
/// The value of `merged` that gives its sample as written, and its
/// pointer: per keyword, the schema's own, else the first branch's. A
/// branch's value is used only when the merged schema is not an object,
/// since it shows only the branch's part of an object.
fn Sampler::value(self : Sampler, merged : Merged) -> (String, Json)? {
  let mut object : Bool? = None
  for keyword in value_keywords {
    if keyword == "examples" && self.v30 {
      continue
    }
    for layer in merged.layers {
      guard layer.schema.get(keyword) is Some(value) else { continue }
      if layer.branch {
        if object is None {
          object = Some(self.type_of(merged) == "object")
        }
        // The layers after a branch are branches too.
        if object is Some(true) {
          break
        }
      }
      match keyword {
        "examples" | "enum" =>
          if self.first_of(layer.pointer, layer.schema, keyword) is Some(found) {
            return Some(found)
          }
        _ =>
          return Some(
            (@definitions.child_pointer(layer.pointer, keyword), value),
          )
      }
    }
  }
  None
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
/// The type of `merged`: the first type other than `null` in a type
/// array, and `null` when it is the only one. Without a type, the one the
/// keywords of any layer imply, tried in this order: object, array,
/// integer, number, then string; else `null`.
fn Sampler::type_of(self : Sampler, merged : Merged) -> String {
  for layer in merged.layers {
    match layer.schema.get("type") {
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
          @definitions.child_pointer(layer.pointer, "type"),
          "ignored: must be a type, such as \"string\", or a non-empty array of types",
        )
    }
  }
  let format = self.format(merged)
  if merged.has_any(object_keywords) {
    "object"
  } else if merged.has_any(array_keywords) {
    "array"
  } else if format is Some("int32" | "int64") {
    "integer"
  } else if format is Some("float" | "double") ||
    merged.has_any(number_keywords) {
    "number"
  } else if format is Some(_) || merged.has_any(string_keywords) {
    "string"
  } else {
    "null"
  }
}

///|
/// Whether a layer of `merged` has one of `keywords`.
fn Merged::has_any(self : Merged, keywords : Array[String]) -> Bool {
  for layer in self.layers {
    for keyword in keywords {
      if layer.schema.contains(keyword) {
        return true
      }
    }
  }
  false
}

///|
/// The `format` of `merged`, or `None` when it has none. One that is not a
/// string is ignored, with a warning.
fn Sampler::format(self : Sampler, merged : Merged) -> String? {
  for layer in merged.layers {
    match layer.schema.get("format") {
      None => ()
      Some(String(format)) => return Some(format)
      Some(_) =>
        self.report.root_warning(
          @definitions.child_pointer(layer.pointer, "format"),
          "ignored: must be a string",
        )
    }
  }
  None
}

///|
/// The non-negative integer `keyword` of `merged`, and its pointer, or
/// `None` when it has none. A value of another type is ignored, with a
/// warning. One above the largest `Int` counts as it.
fn Sampler::count(
  self : Sampler,
  merged : Merged,
  keyword : String,
) -> (String, Int)? {
  for layer in merged.layers {
    let at = @definitions.child_pointer(layer.pointer, keyword)
    match layer.schema.get(keyword) {
      None => ()
      Some(Number(n, ..)) if n >= 0.0 && n == n.floor() =>
        return Some(
          (at, if n >= 2147483647.0 { 2147483647 } else { n.to_int() }),
        )
      Some(_) =>
        self.report.root_warning(at, "ignored: must be a non-negative integer")
    }
  }
  None
}

///|
/// The sample of a string: the one of its `format` when the format has
/// one, whatever its length bounds; else `"string"`, repeated or cut to
/// fit `minLength` and `maxLength`.
fn Sampler::string(self : Sampler, merged : Merged) -> String {
  if self.format(merged) is Some(format) &&
    format_samples.get(format) is Some(sample) {
    return sample
  }
  let word = "string"
  let min = self.count(merged, "minLength")
  let max = self.count(merged, "maxLength")
  let mut length = word.length()
  if max is Some((_, max)) && length > max {
    length = max
  }
  if min is Some((_, min)) && length < min {
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
fn Sampler::array(self : Sampler, merged : Merged, room : Int) -> Json {
  let items : Array[Json] = []
  let min = self.count(merged, "minItems")
  if self.count(merged, "maxItems") is Some((_, 0)) {
    return Json::array(items)
  }
  let mut length = 1
  if min is Some((at, min)) && min > length {
    length = min
    if length > max_sample_items {
      self.report.root_warning(
        at,
        "changed: the sample has \{max_sample_items} items, the most a sample has, not \{length}",
      )
      length = max_sample_items
    }
  }
  let mut prefix_at = ""
  let mut prefix : Array[Json] = []
  for layer in merged.layers {
    let at = @definitions.child_pointer(layer.pointer, "prefixItems")
    match layer.schema.get("prefixItems") {
      None => continue
      Some(Array(items)) => {
        prefix_at = at
        prefix = items
        break
      }
      Some(_) => self.report.root_warning(at, "ignored: must be an array")
    }
  }
  // Every item after `prefixItems` is the same sample of `items`.
  let mut rest : Json? = None
  let mut rest_drawn = false
  for i in 0..<length {
    let item = if i < prefix.length() {
      let at = @definitions.child_pointer(prefix_at, i.to_string())
      if !self.is_schema(at, prefix[i]) {
        break
      }
      self.sample(at, prefix[i], room - 1)
    } else {
      if !rest_drawn {
        rest_drawn = true
        for layer in merged.layers {
          let at = @definitions.child_pointer(layer.pointer, "items")
          if layer.schema.get("items") is Some(json) && self.is_schema(at, json) {
            rest = self.sample(at, json, room - 1)
            break
          }
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
/// schema is `false`. The `properties` of the layers are joined by name: a
/// property met again is merged with the one met first, as a branch.
fn Sampler::object(self : Sampler, merged : Merged, room : Int) -> Json {
  let properties : Map[String, Array[(String, Json)]] = Map([])
  for layer in merged.layers {
    let at = @definitions.child_pointer(layer.pointer, "properties")
    match layer.schema.get("properties") {
      None => ()
      Some(Object(members)) =>
        for name, json in members {
          let property = (@definitions.child_pointer(at, name), json)
          match properties.get(name) {
            Some(met) => met.push(property)
            None => properties[name] = [property]
          }
        }
      Some(_) => self.report.root_warning(at, "ignored: must be an object")
    }
  }
  let members : Map[String, Json] = Map([])
  for name, met in properties {
    let property = Merged::new()
    let mut schemas = false
    for (at, json) in met {
      if self.is_schema(at, json) {
        self.merge(property, at, json, property.layers.length() > 0)
        schemas = true
      }
    }
    if !schemas {
      continue
    }
    if self.write_only(property) {
      continue
    }
    if self.merged_sample(property, room - 1) is Some(value) {
      members[name] = value
    }
  }
  Json::object(members)
}

///|
/// Whether the merged property `merged` is `writeOnly`, so that a response
/// leaves it out. In 3.0, the fields beside a `$ref` are ignored.
fn Sampler::write_only(self : Sampler, merged : Merged) -> Bool {
  for layer in merged.layers {
    if self.v30 && layer.schema.contains("$ref") {
      continue
    }
    match layer.schema.get("writeOnly") {
      None => ()
      Some(False) => return false
      Some(True) => return true
      Some(_) =>
        self.report.root_warning(
          @definitions.child_pointer(layer.pointer, "writeOnly"),
          "ignored: must be true or false",
        )
    }
  }
  false
}
