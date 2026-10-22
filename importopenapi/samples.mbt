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
/// The most collections a sample nests: an object or an array inside as
/// many others is null.
let max_sample_depth : Int = 32

///|
/// The most bytes of compact JSON that a sample with every property takes:
/// 64 KiB. A larger one is made again, cut to its required parts below the
/// first level.
let max_full_sample_bytes : Int = 64 * 1024

///|
/// The most bytes of compact JSON that a cut sample takes: 1 MiB. A larger
/// one leaves the body empty.
let max_cut_sample_bytes : Int = 1024 * 1024

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
/// A JSON Schema type.
priv enum SchemaType {
  Null
  Boolean
  Object
  Array
  Number
  Integer
  String
}

///|
/// The JSON Schema type that `name` names, such as `"string"`, or `None`
/// when it names none.
fn schema_type(name : String) -> SchemaType? {
  match name {
    "null" => Some(Null)
    "boolean" => Some(Boolean)
    "object" => Some(Object)
    "array" => Some(Array)
    "number" => Some(Number)
    "integer" => Some(Integer)
    "string" => Some(String)
    _ => None
  }
}

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
/// A sample has passed the bytes it may take, so that it stops at once.
priv suberror Passed

///|
/// Draws one fixed sample from a schema. The sample depends only on the
/// schema: nothing is random. A keyword that the sampler reads but that has
/// the wrong type is ignored, with a warning at its pointer.
priv struct Sampler {
  report : Report
  /// The document whose schemas it samples, where a `$ref` is followed.
  document : Document
  /// Whether the document is OpenAPI 3.0, whose schemas have no
  /// `examples`, and where the keywords beside a `$ref` are ignored.
  v30 : Bool
  /// The pointers of the schemas merged into those whose samples are
  /// being generated: the samples that hold the one being generated now.
  generating : Array[String]
  /// Whether the sample is cut: below its first level, objects have only
  /// their required properties, and arrays only `minItems` items.
  cut : Bool
  /// How many more bytes of compact JSON the sample may take.
  mut left : Int
}

///|
/// A sampler for the schemas of `document`, whose sample is `cut` or not.
fn Report::sampler(self : Report, document : Document, cut~ : Bool) -> Sampler {
  {
    report: self,
    document,
    v30: document.openapi.has_prefix("3.0."),
    generating: [],
    cut,
    left: if cut {
      max_cut_sample_bytes
    } else {
      max_full_sample_bytes
    },
  }
}

///|
/// A body sampled from a schema: the sample, or `None` when there is none,
/// and whether it was cut to its required parts.
priv struct BodySample {
  value : Json?
  cut : Bool
  /// Whether there is no sample because it would pass 1 MiB, even cut, as
  /// a warning says, rather than because the schema allows no value.
  too_large : Bool
}

///|
/// The sample of the schema `json` at `pointer`, as a body. It is first
/// made with every property. When its compact JSON would pass 64 KiB, it is
/// made again with only the required properties, and only `minItems`
/// items, none when it is 0, in every object and array nested more than one
/// level below the body. When that would pass 1 MiB, there is no body, with
/// a warning. Each sample stops as soon as it passes its bound. Only the
/// problems of the sample that is written are reported. A header's value
/// is sampled the same way, with `part` naming it in the warning.
fn Report::body_sample(
  self : Report,
  document : Document,
  pointer : String,
  json : Json,
  part? : String = "the body",
) -> BodySample {
  let mark = self.mark()
  for cut in [false, true] {
    let sampler = self.sampler(document, cut~)
    try sampler.sample(pointer, json, 0) catch {
      Passed => self.rollback(mark)
    } noraise {
      value => return { value, cut, too_large: false, }
    }
  }
  self.warning_at(
    pointer,
    "left out: \{part} is empty, since its sample would be more than \{size_text(max_cut_sample_bytes)}, even cut to its required parts",
  )
  { value: None, cut: false, too_large: true, }
}

///|
/// Takes `bytes` from what the sample may still take, or stops it when
/// they are more.
fn Sampler::charge(self : Sampler, bytes : Int) -> Unit raise Passed {
  if bytes > self.left {
    raise Passed
  }
  self.left -= bytes
}

///|
/// `json`, after taking its compact JSON from what the sample may still
/// take.
fn Sampler::charged(self : Sampler, json : Json) -> Json raise Passed {
  self.charge(compact_size(json, self.left))
  json
}

///|
/// Whether a collection inside `depth` sampled collections is cut: in a
/// cut sample, those nested more than one level below the body are.
fn Sampler::cuts(self : Sampler, depth : Int) -> Bool {
  self.cut && depth >= 2
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
  /// The pointers of the schemas that a `$ref` named, merged into it. In
  /// 3.0, one that has a `$ref` itself is not a layer.
  refs : Array[String]
  /// Whether one of them is the schema `false`, so that it gives no value.
  mut never : Bool
  /// Whether a `oneOf` or `anyOf` in it has only branches that are only
  /// null, so that the sample is null.
  mut only_null : Bool
  /// Whether a `$ref` in it names a schema whose sample is being generated,
  /// so that it would hold itself.
  mut recursive : Bool
}

///|
/// A merged schema with nothing in it yet.
fn Merged::new() -> Merged {
  { layers: [], refs: [], never: false, only_null: false, recursive: false, }
}

///|
/// Whether `json`, at `pointer`, is a schema: an object, or `true` or
/// `false`. When it is not, it is ignored, with a warning.
fn Sampler::is_schema(self : Sampler, pointer : String, json : Json) -> Bool {
  guard json is (Object(_) | True | False) else {
    self.report.warning_at(
      pointer, "ignored: must be a schema, an object or a boolean",
    )
    return false
  }
  true
}

///|
/// The sample of the schema `json` at `pointer`, inside `depth` sampled
/// collections, or `None` when it gives no value: it is `false`, it would
/// hold itself, or a value it names would nest too deep for the file. The
/// schema is first merged with its branches.
fn Sampler::sample(
  self : Sampler,
  pointer : String,
  json : Json,
  depth : Int,
) -> Json? raise Passed {
  let merged = Merged::new()
  self.merge(merged, pointer, json, branch=false)
  self.merged_sample(merged, depth)
}

///|
/// Adds the schema `json` at `pointer` to `merged`, a `branch` or the
/// schema itself, then its branches: each of `allOf`, in order, then the
/// branch that `oneOf` takes, then the one that `anyOf` takes. `oneOf` and
/// `anyOf` take their first branch that is neither only null nor `false`,
/// which allows no value, as written or at the end of its `$ref`s; when
/// each branch is only null or `false`, the sample is null if one is only
/// null, and else there is no value. `true` adds nothing, and `false`, as
/// the schema or in `allOf`, leaves no value.
fn Sampler::merge(
  self : Sampler,
  merged : Merged,
  pointer : String,
  json : Json,
  branch~ : Bool,
) -> Unit {
  let schema = match json {
    Object(schema) => schema
    False => {
      merged.never = true
      return
    }
    _ => return
  }
  // In 3.0, a schema with a `$ref` is the schema it names: the keywords
  // beside it are ignored.
  if self.v30 && schema.contains("$ref") {
    if self.referenced(merged, pointer, schema) is Some(target) {
      self.merge(merged, target.pointer, target.json, branch~)
    }
    return
  }
  if schema.contains("$dynamicRef") {
    self.report.error_at(
      @definitions.child_pointer(pointer, "$dynamicRef"),
      "smock does not follow $dynamicRef: write a $ref with a JSON Pointer, such as #/components/schemas/Pet",
    )
  }
  merged.layers.push({ pointer, schema, branch, })
  // From 3.1, the schema a `$ref` names is merged with the keywords beside
  // it, which come first, as part of the same schema.
  if self.referenced(merged, pointer, schema) is Some(target) {
    self.merge(merged, target.pointer, target.json, branch~)
  }
  let all_of = @definitions.child_pointer(pointer, "allOf")
  match schema.get("allOf") {
    None => ()
    Some(Array(branches)) =>
      for i, json in branches {
        let at = @definitions.child_pointer(all_of, i.to_string())
        if self.is_schema(at, json) {
          self.merge(merged, at, json, branch=true)
        }
      }
    Some(_) => self.report.warning_at(all_of, "ignored: must be an array")
  }
  for keyword in ["oneOf", "anyOf"] {
    let branches_pointer = @definitions.child_pointer(pointer, keyword)
    match schema.get(keyword) {
      None => ()
      Some(Array(branches)) => {
        let mut nulls = false
        let mut nevers = false
        let mut taken = false
        for i, json in branches {
          let at = @definitions.child_pointer(branches_pointer, i.to_string())
          if !self.is_schema(at, json) {
            continue
          }
          let target = self.branch_target(at, json)
          if target is False {
            nevers = true
            continue
          }
          if is_only_null(json) || is_only_null(target) {
            nulls = true
            continue
          }
          self.merge(merged, at, json, branch=true)
          taken = true
          break
        }
        if !taken && nulls {
          merged.only_null = true
        } else if !taken && nevers {
          merged.never = true
        }
      }
      Some(_) =>
        self.report.warning_at(branches_pointer, "ignored: must be an array")
    }
  }
}

///|
/// The schema that the `oneOf` or `anyOf` branch `json` at `pointer`
/// stands for, to tell whether it is only null or `false`: the schema at
/// the end of its chain of `$ref`s, or `json` itself when it has no `$ref`,
/// or when a `$ref` in the chain cannot be followed, lies under a `$id`,
/// or leads back into the chain. Nothing is reported here, and nothing is
/// marked as being generated: a branch that is merged reports its own
/// problems then.
fn Sampler::branch_target(
  self : Sampler,
  pointer : String,
  json : Json,
) -> Json {
  let mark = self.report.mark()
  let chain = []
  let mut pointer = pointer
  let mut target = json
  while target is Object(schema) &&
        schema.get("$ref") is Some(String(reference)) {
    if chain.contains(pointer) || self.under_id(pointer) {
      target = json
      break
    }
    chain.push(pointer)
    let at = @definitions.child_pointer(pointer, "$ref")
    guard self.report.target(self.document, at, reference) is Some(part) else {
      target = json
      break
    }
    pointer = part.pointer
    target = part.json
  }
  self.report.rollback(mark)
  target
}

///|
/// The schema that the `$ref` of `schema`, at `pointer`, names, or `None`
/// when it has none, or after reporting why it cannot be followed. It is
/// followed by the rules of other references, except that a cycle is
/// allowed. `None` too when it names a schema whose sample is being
/// generated, which makes `merged` recursive, or one already merged into
/// `merged`, which is skipped.
fn Sampler::referenced(
  self : Sampler,
  merged : Merged,
  pointer : String,
  schema : Map[String, Json],
) -> Part? {
  guard schema.get("$ref") is Some(reference) else { return None }
  let at = @definitions.child_pointer(pointer, "$ref")
  guard reference is String(reference) else {
    self.report.error_at(at, "must be a string")
    return None
  }
  if self.under_id(pointer) {
    return None
  }
  guard self.report.target(self.document, at, reference) is Some(target) else {
    return None
  }
  guard self.is_schema(target.pointer, target.json) else { return None }
  if self.generating.contains(target.pointer) {
    merged.recursive = true
    return None
  }
  if merged.refs.contains(target.pointer) {
    return None
  }
  for layer in merged.layers {
    if layer.pointer == target.pointer {
      return None
    }
  }
  merged.refs.push(target.pointer)
  Some(target)
}

///|
/// Whether a `$id` lies above the schema at the place `pointer` in its
/// document, or in it, so that it would change what a `$ref` in the schema
/// names. Each one is reported, since smock does not resolve `$id`. A
/// `$id` at the root of a document is not: the document's location is its
/// base. In 3.0, a `$id` beside a `$ref` is ignored with the other fields
/// there.
fn Sampler::under_id(self : Sampler, pointer : String) -> Bool {
  let (number, pointer) = number_of(pointer)
  guard pointer_keys(pointer) is Some(keys) else { return false }
  let mut json = self.report.tree(self.document, number)
  let mut at = place_in(number, "")
  let mut found = false
  for key in keys {
    guard step(json, key) is Some(value) else { break }
    at = @definitions.child_pointer(at, key)
    json = value
    if value is Object(schema) &&
      schema.get("$id") is Some(String(_)) &&
      !(self.v30 && schema.contains("$ref")) {
      self.report.error_at(
        @definitions.child_pointer(at, "$id"),
        "a $ref lies under this $id, which would change what the $ref names: smock does not resolve $id",
      )
      found = true
    }
  }
  found
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
/// The sample of the merged schema `merged`, inside `depth` sampled
/// collections, or `None` when it gives no value. Per keyword, the first
/// of `const`, the first of `examples` (from 3.1), `example`, `default`
/// and the first of `enum` gives the sample, as written. Else the type
/// does. An object or an array inside 32 others is null.
fn Sampler::merged_sample(
  self : Sampler,
  merged : Merged,
  depth : Int,
) -> Json? raise Passed {
  if merged.never || merged.recursive {
    return None
  }
  if merged.only_null {
    return Some(self.charged(Json::null()))
  }
  if self.value(merged) is Some((at, value)) {
    // Its size counts before its depth is checked, so that a large value
    // stops the sample before it is walked.
    let bytes = compact_size(value, self.left)
    self.charge(bytes)
    guard self.report.copied(at, value, body_nesting - depth) is Some(value) else {
      self.left += bytes
      return None
    }
    return Some(value)
  }
  match self.type_of(merged) {
    Boolean => Some(self.charged(Json::boolean(true)))
    Number => Some(self.charged(self.number(merged, integer=false).to_json()))
    Integer => Some(self.charged(self.number(merged, integer=true).to_json()))
    String => Some(self.string(merged))
    Array | Object if depth >= max_sample_depth =>
      Some(self.charged(Json::null()))
    Array | Object as kind => {
      // The schemas merged into it are being generated until its members
      // are.
      let held = self.generating.length()
      for layer in merged.layers {
        self.generating.push(layer.pointer)
      }
      self.generating.append(merged.refs)
      let sample = if kind is Array {
        self.array(merged, depth)
      } else {
        self.object(merged, depth)
      }
      self.generating.truncate(held)
      Some(sample)
    }
    Null => Some(self.charged(Json::null()))
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
          object = Some(self.type_of(merged) is Object)
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
      self.report.warning_at(at, "ignored: must be an array")
      None
    }
  }
}

///|
/// `value`, written at `pointer`, copied as data, so that a `$ref` member
/// in it stays as written; or `None` when it would nest deeper than `room`
/// levels, which the parsers would not read back. It is then left out,
/// with a warning.
fn Report::copied(
  self : Report,
  pointer : String,
  value : Json,
  room : Int,
) -> Json? {
  if nests_deeper(value, room) {
    self.warning_at(
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
fn Sampler::type_of(self : Sampler, merged : Merged) -> SchemaType {
  for layer in merged.layers {
    guard layer.schema.get("type") is Some(written) else { continue }
    if type_named(written) is Some(kind) {
      return kind
    }
    self.report.warning_at(
      @definitions.child_pointer(layer.pointer, "type"),
      "ignored: must be a type, such as \"string\", or a non-empty array of types",
    )
  }
  let format = self.format(merged)
  if merged.has_any(object_keywords) {
    Object
  } else if merged.has_any(array_keywords) {
    Array
  } else if format is Some("int32" | "int64") {
    Integer
  } else if format is Some("float" | "double") ||
    merged.has_any(number_keywords) {
    Number
  } else if format is Some(_) || merged.has_any(string_keywords) {
    String
  } else {
    Null
  }
}

///|
/// The type that `json`, a schema's `type`, gives: the type it names, or,
/// for a non-empty array of names, the first other than `null`, and `null`
/// when it is the only one. `None` when it is neither.
fn type_named(json : Json) -> SchemaType? {
  match json {
    String(name) => schema_type(name)
    Array(names) if names.length() > 0 => {
      let mut found : SchemaType = Null
      for name in names {
        guard name is String(name) && schema_type(name) is Some(kind) else {
          return None
        }
        if found is Null {
          found = kind
        }
      }
      Some(found)
    }
    _ => None
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
        self.report.warning_at(
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
        self.report.warning_at(at, "ignored: must be a non-negative integer")
    }
  }
  None
}

///|
/// The sample of a string: the one of its `format` when the format has
/// one, whatever its length bounds; else `"string"`, repeated or cut to
/// fit `minLength` and `maxLength`. Its bytes are taken before it is made.
fn Sampler::string(self : Sampler, merged : Merged) -> Json raise Passed {
  if self.format(merged) is Some(format) &&
    format_samples.get(format) is Some(sample) {
    return self.charged(Json::string(sample))
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
  // The quotes and the letters, which need no escape.
  self.charge(2)
  self.charge(length)
  let sample = StringBuilder()
  for i in 0..<length {
    sample.write_char(word.unsafe_get(i % word.length()).unsafe_to_char())
  }
  Json::string(sample.to_string())
}

///|
/// The sample of an array inside `depth` sampled collections: `minItems`
/// items, at least 1 and at most 100, with a warning past 100, and none
/// when `maxItems` is 0. When the sample is cut there, only `minItems`
/// items, none when it is 0. The items come from `prefixItems`, then
/// `items`, and stop where neither gives one.
fn Sampler::array(
  self : Sampler,
  merged : Merged,
  depth : Int,
) -> Json raise Passed {
  self.charge(2)
  let items : Array[Json] = []
  let min = self.count(merged, "minItems")
  if self.count(merged, "maxItems") is Some((_, 0)) {
    return Json::array(items)
  }
  let mut length = if self.cuts(depth) { 0 } else { 1 }
  if min is Some((at, min)) && min > length {
    length = min
    if length > max_sample_items {
      self.report.warning_at(
        at,
        "changed: the sample has \{max_sample_items} items, the most a sample has, not \{length}",
      )
      length = max_sample_items
    }
  }
  let mut prefix_at = ""
  let mut prefix : Array[Json] = []
  for layer in merged.layers {
    if length == 0 {
      break
    }
    let at = @definitions.child_pointer(layer.pointer, "prefixItems")
    match layer.schema.get("prefixItems") {
      None => continue
      Some(Array(items)) => {
        prefix_at = at
        prefix = items
        break
      }
      Some(_) => self.report.warning_at(at, "ignored: must be an array")
    }
  }
  // Every item after `prefixItems` is the same sample of `items`, which
  // takes its bytes again for each.
  let mut rest : Json? = None
  let mut rest_drawn = false
  let mut rest_bytes = 0
  for i in 0..<length {
    let item = if i < prefix.length() {
      let at = @definitions.child_pointer(prefix_at, i.to_string())
      if !self.is_schema(at, prefix[i]) {
        break
      }
      self.sample(at, prefix[i], depth + 1)
    } else if rest_drawn {
      if rest is Some(_) {
        self.charge(rest_bytes)
      }
      rest
    } else {
      rest_drawn = true
      let before = self.left
      for layer in merged.layers {
        let at = @definitions.child_pointer(layer.pointer, "items")
        if layer.schema.get("items") is Some(json) && self.is_schema(at, json) {
          rest = self.sample(at, json, depth + 1)
          break
        }
      }
      rest_bytes = before - self.left
      rest
    }
    guard item is Some(item) else { break }
    // The comma before it.
    if i > 0 {
      self.charge(1)
    }
    items.push(item)
  }
  Json::array(items)
}

///|
/// The names in the `required` of each layer of `merged`, joined. One that
/// is not an array, or a name in it that is not a string, is ignored, with
/// a warning.
fn Sampler::required(self : Sampler, merged : Merged) -> Array[String] {
  let names = []
  for layer in merged.layers {
    let at = @definitions.child_pointer(layer.pointer, "required")
    match layer.schema.get("required") {
      None => ()
      Some(Array(items)) =>
        for i, item in items {
          match item {
            String(name) => if !names.contains(name) { names.push(name) }
            _ =>
              self.report.warning_at(
                @definitions.child_pointer(at, i.to_string()),
                "ignored: must be a string",
              )
          }
        }
      Some(_) => self.report.warning_at(at, "ignored: must be an array")
    }
  }
  names
}

///|
/// The sample of an object inside `depth` sampled collections: every
/// property in `properties`, required or not, in the order written, except
/// `writeOnly` ones and those whose schema is `false`. When the sample is
/// cut there, only the required ones. The `properties` of the layers are
/// joined by name: a property met again is merged with the one met first,
/// as a branch. A property that would hold the object again is left out,
/// or null when it is required.
fn Sampler::object(
  self : Sampler,
  merged : Merged,
  depth : Int,
) -> Json raise Passed {
  self.charge(2)
  let cut = self.cuts(depth)
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
      Some(_) => self.report.warning_at(at, "ignored: must be an object")
    }
  }
  let required = self.required(merged)
  let members : Map[String, Json] = Map([])
  for name, met in properties {
    if cut && !required.contains(name) {
      continue
    }
    let property = Merged::new()
    let mut schemas = false
    let mut own_write_only = false
    for (at, json) in met {
      if !self.is_schema(at, json) {
        continue
      }
      // A property that is `writeOnly` itself is left out before the
      // schema that a `$ref` beside it names is read.
      if !schemas && self.is_own_write_only(json) {
        own_write_only = true
        break
      }
      self.merge(property, at, json, branch=property.layers.length() > 0)
      schemas = true
    }
    if !schemas || own_write_only {
      continue
    }
    if self.write_only(property) {
      continue
    }
    let value = if !property.recursive {
      self.merged_sample(property, depth + 1)
    } else if required.contains(name) {
      Some(self.charged(Json::null()))
    } else {
      None
    }
    guard value is Some(value) else { continue }
    // The name, the colon, and the comma before them.
    self.charge(
      compact_size(Json::string(name), self.left) +
      (if members.is_empty() { 1 } else { 2 }),
    )
    members[name] = value
  }
  Json::object(members)
}

///|
/// Whether the schema `json` has `writeOnly: true` of its own. In 3.0, the
/// fields beside a `$ref` are ignored.
fn Sampler::is_own_write_only(self : Sampler, json : Json) -> Bool {
  json is Object(schema) &&
  schema.get("writeOnly") is Some(True) &&
  !(self.v30 && schema.contains("$ref"))
}

///|
/// Whether the merged property `merged` is `writeOnly`, so that a response
/// leaves it out.
fn Sampler::write_only(self : Sampler, merged : Merged) -> Bool {
  for layer in merged.layers {
    match layer.schema.get("writeOnly") {
      None => ()
      Some(False) => return false
      Some(True) => return true
      Some(_) =>
        self.report.warning_at(
          @definitions.child_pointer(layer.pointer, "writeOnly"),
          "ignored: must be true or false",
        )
    }
  }
  false
}

///|
/// The length of `json` as compact JSON in UTF-8, as smock writes it, or a
/// length above `limit` as soon as it passes it, so that a large value is
/// not walked to its end.
fn compact_size(json : Json, limit : Int) -> Int {
  match json {
    Null | True => 4
    False => 5
    Number(n, repr~) => @template.number_text(n, repr).length()
    String(s) => @template.json_string_bytes(s, limit~)
    Array(items) => {
      let mut size = if items.is_empty() { 2 } else { 1 + items.length() }
      for item in items {
        if size > limit {
          break
        }
        size += compact_size(item, limit - size)
      }
      size
    }
    Object(members) => {
      let mut size = if members.is_empty() { 2 } else { 1 + members.length() }
      for name, value in members {
        if size > limit {
          break
        }
        size += @template.json_string_bytes(name, limit=limit - size) + 1
        size += compact_size(value, limit - size)
      }
      size
    }
  }
}
