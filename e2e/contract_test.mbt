// The Admin API contract: Seam 2 tests check every Admin API response they
// get against the OpenAPI document, openapi/admin.json. The checker below
// knows the JSON Schema keywords the document uses. A keyword it does not
// know is reported as a problem, never skipped, so that a check cannot pass
// by ignoring part of a schema.

///|
/// The OpenAPI document, relative to the module root.
let document : String = "openapi/admin.json"

///|
/// The OpenAPI document and the JSON Schemas it refers to, by their paths
/// relative to the module root.
struct Contract {
  files : Map[String, Json]
}

///|
/// The contract, read once per test process.
let contract : @async.Lazy[Contract] = @async.Lazy(() => {
  let files = Map([])
  let pending = [document]
  while pending.pop() is Some(path) {
    if files.contains(path) {
      continue
    }
    let json = @fs.read_file(path).json()
    files[path] = json
    for reference in refs(json) {
      let file = ref_file(reference)
      if file != "" {
        pending.push(join_path(path, file))
      }
    }
  }
  { files, }
})

///|
/// Every `$ref` in `json`.
fn refs(json : Json) -> Array[String] {
  let out = []
  fn walk(json : Json) {
    match json {
      Object(members) =>
        for key, value in members {
          match (key, value) {
            ("$ref", String(reference)) => out.push(reference)
            _ => walk(value)
          }
        }
      Array(items) =>
        for item in items {
          walk(item)
        }
      _ => ()
    }
  }
  walk(json)
  out
}

///|
/// The file part of a reference: what comes before `#`.
fn ref_file(reference : String) -> String {
  match reference.find("#") {
    Some(i) => reference[:i].to_owned()
    None => reference
  }
}

///|
/// The path of `relative`, a path relative to the file at `base`.
fn join_path(base : String, relative : String) -> String {
  let parts : Array[String] = base.split("/").map(p => p.to_owned()).collect()
  let _ = parts.pop()
  for part in relative.split("/") {
    match part {
      "." | "" => ()
      ".." => {
        let _ = parts.pop()
      }
      _ => parts.push(part.to_owned())
    }
  }
  parts.join("/")
}

///|
/// A schema or another part of a file of the contract.
struct Located {
  /// The file it is in.
  file : String
  json : Json
}

///|
/// What `reference`, found in `file`, refers to.
fn Contract::resolve(
  self : Contract,
  file : String,
  reference : String,
) -> Located raise {
  let target = match ref_file(reference) {
    "" => file
    other => join_path(file, other)
  }
  guard self.files.get(target) is Some(root) else {
    fail("\{reference}: no file \{target}")
  }
  let pointer = match reference.find("#") {
    Some(i) => reference[i + 1:].to_owned()
    None => ""
  }
  let mut json = root
  if pointer != "" {
    for token in pointer[1:].split("/") {
      let key = token
        .replace_all(old="~1", new="/")
        .replace_all(old="~0", new="~")
      json = match json {
        Object(members) =>
          match members.get(key.to_owned()) {
            Some(value) => value
            None => fail("\{reference}: no member \{key.escape()} in \{target}")
          }
        _ =>
          fail("\{reference}: \{key.escape()} is not in an object in \{target}")
      }
    }
  }
  { file: target, json, }
}

///|
/// Follows `located` while it is a reference object, as OpenAPI responses,
/// parameters and headers can be.
fn Contract::follow(self : Contract, located : Located) -> Located raise {
  let mut at = located
  while at.json is Object(members) &&
        members.get("$ref") is Some(String(reference)) {
    at = self.resolve(at.file, reference)
  }
  at
}

///|
/// The problems with `response` as the answer to `meth path`, by the
/// document: none when it conforms. A path the document does not list, or a
/// method it does not list for the path, must be answered as the document's
/// `Error` response says.
fn Contract::check(
  self : Contract,
  meth : String,
  path : String,
  response : AdminResponse,
) -> Array[String] raise {
  let path = match path.find("?") {
    Some(i) => path[:i].to_owned()
    None => path
  }
  guard self.files[document] is Object(root) &&
    root.get("paths") is Some(Object(paths)) else {
    fail("\{document} has no paths")
  }
  let mut item = None
  for template, value in paths {
    if path_matches(template, path) {
      item = Some(value)
    }
  }
  let operation = match item {
    Some(Object(item)) =>
      match item.get(meth.to_lower()) {
        Some(Object(operation)) => Some(operation)
        _ => None
      }
    _ => None
  }
  let response_object = match operation {
    None => self.resolve(document, "#/components/responses/Error")
    Some(operation) => {
      guard operation.get("responses") is Some(Object(responses)) else {
        fail("\{meth} \{path} has no responses in \{document}")
      }
      let status = response.status.to_string()
      let keys = [status, "\{status[:1]}XX", "default"]
      match keys.iter().filter_map(key => responses.get(key)).head() {
        Some(object) => { file: document, json: object, }
        None => return ["\{meth} \{path} documents no \{status} response"]
      }
    }
  }
  self.check_response(response_object, response)
}

///|
/// Whether `path` fits `template`, such as `/v1/mocks/users/stubs` and
/// `/v1/mocks/{mock}/stubs`.
fn path_matches(template : String, path : String) -> Bool {
  let expected = template.split("/").collect()
  let actual = path.split("/").collect()
  expected.length() == actual.length() &&
  expected
  .iter()
  .zip(actual.iter())
  .all(pair => {
    let (t, a) = pair
    (t.has_prefix("{") && t.has_suffix("}") && a != "") || t == a
  })
}

///|
/// The problems with `response` by the OpenAPI response object `object`.
fn Contract::check_response(
  self : Contract,
  object : Located,
  response : AdminResponse,
) -> Array[String] raise {
  let object = self.follow(object)
  guard object.json is Object(members) else {
    fail("a response object is not an object")
  }
  let problems = []
  if members.get("headers") is Some(Object(headers)) {
    for name, header in headers {
      let header = self.follow({ file: object.file, json: header, })
      guard header.json is Object(header_members) else { continue }
      match response.header(name) {
        Some(value) =>
          match header_members.get("schema") {
            Some(schema) =>
              self.validate(
                { file: header.file, json: schema, },
                Json::string(value),
                "header \{name}",
                problems,
              )
            None => ()
          }
        None =>
          if header_members.get("required") is Some(True) {
            problems.push("header \{name} is missing")
          }
      }
    }
  }
  match members.get("content") {
    Some(Object(content)) => {
      let media_type = match response.header("Content-Type") {
        Some(value) =>
          match value.find(";") {
            Some(i) => value[:i].trim().to_lower()
            None => value.trim().to_lower()
          }
        None => {
          problems.push("header Content-Type is missing")
          return problems
        }
      }
      guard content.get(media_type.to_owned()) is Some(Object(media)) else {
        problems.push("content type \{media_type} is not documented")
        return problems
      }
      let body = if media_type == "application/json" {
        @json.parse(response.body) catch {
          err => {
            problems.push("the body is not JSON: \{err}")
            return problems
          }
        }
      } else {
        Json::string(response.body)
      }
      match media.get("schema") {
        Some(schema) =>
          self.validate(
            { file: object.file, json: schema, },
            body,
            "",
            problems,
          )
        None => ()
      }
    }
    _ =>
      if response.body != "" {
        problems.push("the response documents no body, but has one")
      }
  }
  problems
}

///|
/// Keywords that only annotate a schema.
let annotations : Set[String] = Set::from_array([
  "description", "title", "default", "examples", "example", "format", "deprecated",
  "readOnly", "writeOnly", "$comment", "$id", "$schema", "contentMediaType", "contentEncoding",
])

///|
/// Validates `value` against `schema`, adding a problem for each way it
/// fails, each prefixed with `at`, a JSON Pointer to the value.
fn Contract::validate(
  self : Contract,
  schema : Located,
  value : Json,
  at : String,
  problems : Array[String],
) -> Unit raise {
  let file = schema.file
  let members = match schema.json {
    True => return
    False => {
      problems.push("\{at}: no value is allowed here")
      return
    }
    Object(members) => members
    _ => fail("a schema in \{file} is neither an object nor a boolean")
  }
  let sub = (json : Json) => Located::{ file, json, }
  for keyword, argument in members {
    match (keyword, argument) {
      (k, _) if annotations.contains(k) => ()
      ("$ref", String(reference)) =>
        self.validate(self.resolve(file, reference), value, at, problems)
      ("type", String(t)) =>
        if !has_type(value, t) {
          problems.push("\{at}: \{describe(value)} is not of type \{t}")
        }
      ("type", Array(types)) =>
        if !types.iter().any(t => t is String(t) && has_type(value, t)) {
          problems.push(
            "\{at}: \{describe(value)} is not of type \{argument.stringify()}",
          )
        }
      ("enum", Array(allowed)) =>
        if !allowed.contains(value) {
          problems.push(
            "\{at}: \{describe(value)} is not one of \{argument.stringify()}",
          )
        }
      ("const", _) =>
        if value != argument {
          problems.push(
            "\{at}: \{describe(value)} is not \{argument.stringify()}",
          )
        }
      ("properties", Object(properties)) =>
        if value is Object(object) {
          for name, property in properties {
            if object.get(name) is Some(v) {
              self.validate(sub(property), v, "\{at}/\{name}", problems)
            }
          }
        }
      ("required", Array(required)) =>
        if value is Object(object) {
          for name in required {
            if name is String(name) && !object.contains(name) {
              problems.push("\{at}: \{name} is missing")
            }
          }
        }
      ("patternProperties", Object(patterns)) =>
        if value is Object(object) {
          for name, v in object {
            for pattern, property in patterns {
              if matches(pattern, name, file) {
                self.validate(sub(property), v, "\{at}/\{name}", problems)
              }
            }
          }
        }
      ("additionalProperties", _) =>
        if value is Object(object) {
          let known = match members.get("properties") {
            Some(Object(properties)) => properties
            _ => Map([])
          }
          let patterns = match members.get("patternProperties") {
            Some(Object(patterns)) => patterns
            _ => Map([])
          }
          for name, v in object {
            if !known.contains(name) && !matches_any(patterns, name, file) {
              self.validate(sub(argument), v, "\{at}/\{name}", problems)
            }
          }
        }
      ("unevaluatedProperties", _) =>
        if value is Object(object) {
          let seen : Set[String] = Set([])
          for other, other_argument in members {
            if other != keyword {
              self.evaluated_by(other, other_argument, file, value, seen)
            }
          }
          for name, v in object {
            if !seen.contains(name) {
              self.validate(sub(argument), v, "\{at}/\{name}", problems)
            }
          }
        }
      ("propertyNames", _) =>
        if value is Object(object) {
          for name, _ in object {
            self.validate(
              sub(argument),
              Json::string(name),
              "\{at} (name \{name})",
              problems,
            )
          }
        }
      ("dependentSchemas", Object(dependents)) =>
        if value is Object(object) {
          for name, dependent in dependents {
            if object.contains(name) {
              self.validate(sub(dependent), value, at, problems)
            }
          }
        }
      ("items", _) =>
        if value is Array(items) {
          for i, item in items {
            self.validate(sub(argument), item, "\{at}/\{i}", problems)
          }
        }
      ("minItems", Number(n, ..)) =>
        if value is Array(items) && items.length().to_double() < n {
          problems.push("\{at}: fewer than \{n} items")
        }
      ("maxItems", Number(n, ..)) =>
        if value is Array(items) && items.length().to_double() > n {
          problems.push("\{at}: more than \{n} items")
        }
      ("allOf", Array(schemas)) =>
        for s in schemas {
          self.validate(sub(s), value, at, problems)
        }
      ("anyOf", Array(schemas)) => {
        let passing = schemas.filter(s => self.passes(sub(s), value))
        if passing.is_empty() {
          problems.push("\{at}: \{describe(value)} matches none of anyOf")
        }
      }
      ("oneOf", Array(schemas)) => {
        let passing = schemas.filter(s => self.passes(sub(s), value))
        if passing.length() != 1 {
          problems.push(
            "\{at}: \{describe(value)} matches \{passing.length()} of oneOf, not 1",
          )
        }
      }
      ("not", _) =>
        if self.passes(sub(argument), value) {
          problems.push(
            "\{at}: \{describe(value)} matches a schema it must not",
          )
        }
      ("minimum", Number(n, ..)) =>
        if value is Number(v, ..) && v < n {
          problems.push("\{at}: \{v} is below \{n}")
        }
      ("maximum", Number(n, ..)) =>
        if value is Number(v, ..) && v > n {
          problems.push("\{at}: \{v} is above \{n}")
        }
      ("minLength", Number(n, ..)) =>
        if value is String(s) && s.char_length().to_double() < n {
          problems.push("\{at}: \{s.escape()} is shorter than \{n}")
        }
      ("maxLength", Number(n, ..)) =>
        if value is String(s) && s.char_length().to_double() > n {
          problems.push("\{at}: \{s.escape()} is longer than \{n}")
        }
      ("pattern", String(pattern)) =>
        if value is String(s) && !matches(pattern, s, file) {
          problems.push("\{at}: \{s.escape()} does not match \{pattern}")
        }
      _ =>
        problems.push(
          "\{at}: the contract checker does not know the keyword \{keyword} in \{file}",
        )
    }
  }
}

///|
/// Adds to `seen` the names of the properties of `value`, an object, that
/// the keyword `keyword` with `argument`, in a schema in `file`, evaluates:
/// those `properties` names, those a `patternProperties` pattern matches,
/// every one for `additionalProperties` and
/// `unevaluatedProperties`, and those that the subschemas applied in place
/// evaluate (`$ref`, `allOf`, the passing ones of `anyOf` and `oneOf`, and
/// `dependentSchemas`). The properties no keyword evaluates are the ones
/// `unevaluatedProperties` applies to.
fn Contract::evaluated_by(
  self : Contract,
  keyword : String,
  argument : Json,
  file : String,
  value : Json,
  seen : Set[String],
) -> Unit raise {
  guard value is Object(object) else { return }
  let in_place = (schema : Located) => {
    if schema.json is Object(members) {
      for k, a in members {
        self.evaluated_by(k, a, schema.file, value, seen)
      }
    }
  }
  let sub = (json : Json) => Located::{ file, json, }
  match (keyword, argument) {
    ("properties", Object(properties)) =>
      for name, _ in object {
        if properties.contains(name) {
          seen.add(name)
        }
      }
    ("patternProperties", Object(patterns)) =>
      for name, _ in object {
        if matches_any(patterns, name, file) {
          seen.add(name)
        }
      }
    ("additionalProperties" | "unevaluatedProperties", _) =>
      for name, _ in object {
        seen.add(name)
      }
    ("$ref", String(reference)) => in_place(self.resolve(file, reference))
    ("allOf", Array(schemas)) =>
      for s in schemas {
        in_place(sub(s))
      }
    ("anyOf" | "oneOf", Array(schemas)) =>
      for s in schemas {
        if self.passes(sub(s), value) {
          in_place(sub(s))
        }
      }
    ("dependentSchemas", Object(dependents)) =>
      for name, dependent in dependents {
        if object.contains(name) {
          in_place(sub(dependent))
        }
      }
    _ => ()
  }
}

///|
/// Whether `pattern`, a regular expression in a schema in `file`, matches
/// somewhere in `s`.
fn matches(pattern : String, s : String, file : String) -> Bool raise {
  let regex = @re2.compile(re2_syntax(pattern)) catch {
    err => fail("pattern \{pattern.escape()} in \{file}: \{err}")
  }
  regex.search(@utf8.encode(s)) is Some(_)
}

///|
/// Whether a pattern of `patterns`, the argument of `patternProperties` in
/// a schema in `file`, matches the name `name`.
fn matches_any(
  patterns : Map[String, Json],
  name : String,
  file : String,
) -> Bool raise {
  for pattern, _ in patterns {
    if matches(pattern, name, file) {
      return true
    }
  }
  false
}

///|
/// `pattern`, an ECMA-262 regular expression as JSON Schema writes it, in
/// the RE2 subset of `smock/re2`: its `\uXXXX`, `\r`, `\n` and `\t`
/// escapes, which the subset lacks, as the characters they stand for. The
/// patterns of the contract use no other syntax that the subset lacks.
fn re2_syntax(pattern : String) -> String {
  let out = StringBuilder()
  let mut i = 0
  while i < pattern.length() {
    if pattern[i] == '\\' && i + 1 < pattern.length() {
      match pattern[i + 1] {
        'u' if i + 6 <= pattern.length() => {
          let mut code = 0
          for c in pattern[i + 2:i + 6] {
            let digit = match c {
              '0'..='9' => c.to_int() - '0'.to_int()
              'a'..='f' => c.to_int() - 'a'.to_int() + 10
              _ => c.to_int() - 'A'.to_int() + 10
            }
            code = code * 16 + digit
          }
          out.write_char(code.unsafe_to_char())
          i += 6
        }
        'r' => {
          out.write_char('\r')
          i += 2
        }
        'n' => {
          out.write_char('\n')
          i += 2
        }
        't' => {
          out.write_char('\t')
          i += 2
        }
        _ => {
          out.write_string(pattern[i:i + 2].to_owned())
          i += 2
        }
      }
    } else {
      out.write_char(pattern[i].unsafe_to_char())
      i += 1
    }
  }
  out.to_string()
}

///|
/// Whether `value` is valid against `schema`.
fn Contract::passes(self : Contract, schema : Located, value : Json) -> Bool {
  let problems = []
  self.validate(schema, value, "", problems) catch {
    _ => return false
  }
  problems.is_empty()
}

///|
fn has_type(value : Json, t : String) -> Bool {
  match (t, value) {
    ("object", Object(_)) => true
    ("array", Array(_)) => true
    ("string", String(_)) => true
    ("number", Number(_, ..)) => true
    ("integer", Number(n, ..)) => n == n.floor()
    ("boolean", True | False) => true
    ("null", Null) => true
    _ => false
  }
}

///|
fn describe(value : Json) -> String {
  let text = value.stringify()
  if text.length() > 60 {
    text[:57].to_owned() + "..."
  } else {
    text
  }
}

///|
/// Fails the test unless `response`, the answer to `meth path`, conforms to
/// the document.
async fn conforms(
  meth : String,
  path : String,
  response : AdminResponse,
) -> Unit {
  let problems = contract.wait().check(meth, path, response)
  if !problems.is_empty() {
    fail(
      "\{meth} \{path} does not conform to \{document}:\n\{problems.join("\n")}\n\n\{response.status}\n\{response.body}",
    )
  }
}

///|
async test "every reference in the Admin API document resolves" {
  let contract = contract.wait()
  let broken = []
  for file, json in contract.files {
    for reference in refs(json) {
      ignore(contract.resolve(file, reference)) catch {
        err => broken.push(err.to_string())
      }
    }
  }
  inspect(
    contract.files.keys().collect().join("\n"),
    content=(
      #|openapi/admin.json
      #|schema/v1/definitions.json
    ),
  )
  debug_inspect(broken, content="[]")
}

///|
async test "the contract checker rejects responses that break the document" {
  let contract = contract.wait()
  let replica = [
    ("Smock-Replica", "host-1"),
    ("Content-Type", "application/json"),
  ]
  let cases = [
    (
      "status without warnings",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":null,"mocks":[]}
        ),
      },
    ),
    (
      "status without Smock-Replica",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: [("Content-Type", "application/json")],
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":null,"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "a digest that is not 12 hex digits",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"xyz","lastReload":null,"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "status without a digest",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":null,"lastReload":null,"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "a 401 without WWW-Authenticate",
      "GET",
      "/v1/status",
      {
        status: 401,
        headers: replica,
        body: (
          #|{"error":"unauthorized","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "an error code the document does not list",
      "GET",
      "/nowhere",
      {
        status: 404,
        headers: replica,
        body: (
          #|{"error":"nope","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "an undocumented field",
      "GET",
      "/v1/status",
      {
        status: 401,
        headers: [..replica, ("WWW-Authenticate", "Bearer")],
        body: (
          #|{"error":"unauthorized","message":"m","warnings":[],"extra":1}
        ),
      },
    ),
    (
      "a failed reload with its errors",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":{"at":"2026-10-13T01:02:03.004Z","result":"failed","errors":[{"file":"a.json","pointer":"/stubs/0","message":"m"}]},"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "a reload result the document does not list",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":{"at":"2026-10-13T01:02:03.004Z","result":"reloaded","errors":[]},"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "a reload without its errors",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":{"at":"2026-10-13T01:02:03.004Z","result":"swapped"},"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "a reload error without its pointer",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":{"at":"2026-10-13T01:02:03.004Z","result":"failed","errors":[{"file":"a.json","message":"m"}]},"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "a passing probe",
      "GET",
      "/startupz",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"status":"ok","warnings":[]}
        ),
      },
    ),
    (
      "a passing probe with another status",
      "GET",
      "/readyz",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"status":"ready","warnings":[]}
        ),
      },
    ),
    (
      "a failing probe",
      "GET",
      "/readyz",
      {
        status: 503,
        headers: replica,
        body: (
          #|{"error":"not_ready","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "a failing probe without its error code",
      "GET",
      "/startupz",
      {
        status: 503,
        headers: replica,
        body: (
          #|{"message":"m","warnings":[]}
        ),
      },
    ),
    (
      "a passing probe with an undocumented field",
      "GET",
      "/livez",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"status":"ok","warnings":[],"uptime":1}
        ),
      },
    ),
    (
      "a reload with an undocumented field",
      "GET",
      "/v1/status",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"version":"1","commit":"c","toolchain":"t","digest":"0123456789ab","lastReload":{"at":"2026-10-13T01:02:03.004Z","result":"unchanged","errors":[],"digest":"0123456789ab"},"mocks":[],"warnings":[]}
        ),
      },
    ),
    (
      "an added Ephemeral Stub",
      "POST",
      "/v1/mocks/users/stubs",
      {
        status: 201,
        headers: replica,
        body: (
          #|{"stub":{"id":"eph-12","mock":"users","session":null,"request":{"method":"GET"},"response":{"status":503,"body":"down"}},"warnings":[]}
        ),
      },
    ),
    (
      "an added Ephemeral Stub with weighted responses",
      "POST",
      "/v1/mocks/users/stubs",
      {
        status: 201,
        headers: replica,
        body: (
          #|{"stub":{"id":"eph-12","mock":"users","session":null,"request":{"method":"GET"},"responses":[{"weight":9,"status":200},{"status":503,"body":"down"}]},"warnings":[]}
        ),
      },
    ),
    (
      "an added Ephemeral Stub with both response and responses",
      "POST",
      "/v1/mocks/users/stubs",
      {
        status: 201,
        headers: replica,
        body: (
          #|{"stub":{"id":"eph-12","mock":"users","session":null,"response":{"status":200},"responses":[{"status":503}]},"warnings":[]}
        ),
      },
    ),
    (
      "an added Ephemeral Stub with a weight out of range",
      "POST",
      "/v1/mocks/users/stubs",
      {
        status: 201,
        headers: replica,
        body: (
          #|{"stub":{"id":"eph-12","mock":"users","session":null,"responses":[{"weight":0,"status":503}]},"warnings":[]}
        ),
      },
    ),
    (
      "an Ephemeral Stub ID that is not eph-<n>",
      "POST",
      "/v1/mocks/users/stubs",
      {
        status: 201,
        headers: replica,
        body: (
          #|{"stub":{"id":"eph-0","mock":"users","session":"s","response":{"status":200}},"warnings":[]}
        ),
      },
    ),
    (
      "an added Ephemeral Stub without its Session",
      "POST",
      "/v1/mocks/users/stubs",
      {
        status: 201,
        headers: replica,
        body: (
          #|{"stub":{"id":"eph-1","mock":"users","response":{"status":200}},"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with a status out of range",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","response":{"status":99}}],"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with an undocumented field",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","response":{"status":200},"addedAt":1}],"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with a header array",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","response":{"status":200,"headers":{"Content-Type":"text/plain","X-A":"1","Set-Cookie":["a=1","b=2"]}}}],"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with an empty header array",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","response":{"status":200,"headers":{"Set-Cookie":[]}}}],"warnings":[]}
        ),
      },
    ),
    (
      "a listed Ephemeral Stub with an array for Content-Type",
      "GET",
      "/v1/mocks/users/stubs",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"stubs":[{"id":"eph-1","mock":"users","session":"s","response":{"status":200,"headers":{"content-type":["text/plain"]}}}],"warnings":[]}
        ),
      },
    ),
    (
      "a deleted Ephemeral Stub with its Mock",
      "DELETE",
      "/v1/mocks/users/stubs/eph-1",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"id":"eph-1","mock":"users","warnings":[]}
        ),
      },
    ),
    (
      "an unknown Ephemeral Stub",
      "DELETE",
      "/v1/mocks/users/stubs/eph-1",
      {
        status: 404,
        headers: replica,
        body: (
          #|{"error":"unknown_stub","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "a reset without the count of Journal entries",
      "POST",
      "/v1/reset",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"scope":"all","removed":{"ephemeralStubs":1,"scenarioStates":0},"warnings":[]}
        ),
      },
    ),
    (
      "a reset without the count of Scenario states",
      "POST",
      "/v1/reset",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"scope":"session","removed":{"ephemeralStubs":0,"journalEntries":2},"warnings":[]}
        ),
      },
    ),
    (
      "a reset with a scope the document does not list",
      "POST",
      "/v1/reset",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"scope":"replica","removed":{"ephemeralStubs":0,"journalEntries":0,"scenarioStates":0},"warnings":[]}
        ),
      },
    ),
    (
      "a Journal page with an unmatched request",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":null,"session":"s","host":"users.example.com","mock":"users","viaDefault":false,"digest":"0123456789ab","request":{"method":"POST","target":"/users/1","version":"HTTP/1.1","headers":[{"name":"Host","value":"users.example.com"}],"body":{"encoding":"utf-8","data":"hi","size":2,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":{"stub":"get-user","stubSource":"file","failed":[{"condition":"method","expected":"GET","actual":["POST"]}]},"status":404,"fault":null,"templateError":null}],"more":false,"evicted":3,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry for an Ephemeral Stub",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"eph-1","stubSource":"ephemeral","scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":null,"status":503,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with the index of the response picked",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"eph-1","stubSource":"ephemeral","scenario":null,"responseIndex":1,"variablesWritten":[],"nearMiss":null,"status":503,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its response index",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"eph-1","stubSource":"ephemeral","scenario":null,"variablesWritten":[],"nearMiss":null,"status":503,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with a response index out of range",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"eph-1","stubSource":"ephemeral","scenario":null,"responseIndex":100,"variablesWritten":[],"nearMiss":null,"status":503,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with the Variables written",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"POST","target":"/login","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"login","stubSource":"file","scenario":null,"responseIndex":null,"variablesWritten":["user","previous"],"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its Variables written",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"shop","viaDefault":true,"digest":"0123456789ab","request":{"method":"POST","target":"/login","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"login","stubSource":"file","scenario":null,"responseIndex":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its Stub source",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"get-user","scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with a Stub source the document does not list",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"get-user","stubSource":"admin","scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with a Scenario move",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"payments","viaDefault":true,"digest":"0123456789ab","request":{"method":"POST","target":"/orders/42/pay","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"pay","stubSource":"file","scenario":{"name":"checkout","from":"Started","to":"Paid"},"responseIndex":null,"variablesWritten":[],"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its Scenario move",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"get-user","stubSource":"file","responseIndex":null,"variablesWritten":[],"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Scenario move without the state it came from",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":"s","host":null,"mock":"payments","viaDefault":true,"digest":"0123456789ab","request":{"method":"POST","target":"/orders/42/pay","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"pay","stubSource":"file","scenario":{"name":"checkout","to":"Paid"},"responseIndex":null,"variablesWritten":[],"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Near miss that failed a Scenario state",
      "GET",
      "/v1/journal/unmatched",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":1,"session":"s","host":null,"mock":"payments","viaDefault":true,"digest":"0123456789ab","request":{"method":"POST","target":"/orders/42/pay","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":{"stub":"pay","stubSource":"file","failed":[{"condition":"scenario:check out\nnow","expected":"Started","actual":["Paid"]}]},"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Near miss that failed a Scenario state without its name",
      "GET",
      "/v1/journal/unmatched",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":1,"session":"s","host":null,"mock":"payments","viaDefault":true,"digest":"0123456789ab","request":{"method":"POST","target":"/orders/42/pay","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":{"stub":"pay","stubSource":"file","failed":[{"condition":"scenario:","expected":"Started","actual":["Paid"]}]},"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Near miss without its Stub source",
      "GET",
      "/v1/journal/unmatched",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":1,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":{"stub":"get-user","failed":[]},"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its sequence number",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"get-user","stubSource":"file","scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry with the sequence number 0",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":0,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"get-user","stubSource":"file","scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":null,"status":200,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its timing",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","session":null,"host":null,"mock":null,"viaDefault":false,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.0","headers":[],"body":{"encoding":"base64","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":null,"status":null,"fault":"close","templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal entry without its digest",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":0,"session":null,"host":null,"mock":null,"viaDefault":false,"digest":null,"request":{"method":"GET","target":"/","version":"HTTP/1.0","headers":[],"body":{"encoding":"base64","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":null,"status":null,"fault":"close","templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal page without the eviction count",
      "POST",
      "/v1/journal/query",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[],"more":false,"warnings":[]}
        ),
      },
    ),
    (
      "a Journal query refused because the Journal is off",
      "POST",
      "/v1/journal/query",
      {
        status: 409,
        headers: replica,
        body: (
          #|{"error":"journal_off","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "a verification that passed",
      "POST",
      "/v1/journal/verify",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"ok":true,"count":2,"evicted":0,"reason":null,"warnings":[]}
        ),
      },
    ),
    (
      "a verification that failed because entries were evicted",
      "POST",
      "/v1/journal/verify",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"ok":false,"count":0,"evicted":2,"reason":"evicted","warnings":[]}
        ),
      },
    ),
    (
      "a verification with a reason the document does not list",
      "POST",
      "/v1/journal/verify",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"ok":false,"count":0,"evicted":0,"reason":"bound","warnings":[]}
        ),
      },
    ),
    (
      "a verification without the eviction count",
      "POST",
      "/v1/journal/verify",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"ok":true,"count":1,"reason":null,"warnings":[]}
        ),
      },
    ),
    (
      "a verification with a count below 0",
      "POST",
      "/v1/journal/verify",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"ok":true,"count":-1,"evicted":0,"reason":null,"warnings":[]}
        ),
      },
    ),
    (
      "a verification refused because the Journal is off",
      "POST",
      "/v1/journal/verify",
      {
        status: 409,
        headers: replica,
        body: (
          #|{"error":"journal_off","message":"m","warnings":[]}
        ),
      },
    ),
    (
      "unmatched requests, one with its Near miss and one for an unknown Host",
      "GET",
      "/v1/journal/unmatched?limit=2",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":1,"session":"s","host":"users.example.com","mock":"users","viaDefault":false,"digest":"0123456789ab","request":{"method":"GET","target":"/users/x?a=b","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":{"stub":"eph-1","stubSource":"ephemeral","failed":[{"condition":"path","expected":{"pattern":"/users/[0-9]+"},"actual":["/users/x"]},{"condition":"query:a","expected":"c","actual":["b"]}]},"status":404,"fault":null,"templateError":null},{"seq":8,"receivedAt":"2026-10-13T01:02:03.005Z","durationMs":0,"session":"s","host":"nowhere.example.com","mock":null,"viaDefault":false,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":null,"status":404,"fault":null,"templateError":null}],"more":true,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "unmatched requests without more",
      "GET",
      "/v1/journal/unmatched",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[],"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "a Near miss with a condition the document does not list",
      "GET",
      "/v1/journal/unmatched",
      {
        status: 200,
        headers: replica,
        body: (
          #|{"entries":[{"seq":7,"receivedAt":"2026-10-13T01:02:03.004Z","durationMs":1,"session":null,"host":null,"mock":"users","viaDefault":true,"digest":"0123456789ab","request":{"method":"GET","target":"/","version":"HTTP/1.1","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"variablesWritten":[],"nearMiss":{"stub":"get-user","stubSource":"file","failed":[{"condition":"trailer:x-id","expected":"1","actual":[]}]},"status":404,"fault":null,"templateError":null}],"more":false,"evicted":0,"warnings":[]}
        ),
      },
    ),
    (
      "unmatched requests refused because the Journal is off",
      "GET",
      "/v1/journal/unmatched",
      {
        status: 409,
        headers: replica,
        body: (
          #|{"error":"journal_off","message":"m","warnings":[]}
        ),
      },
    ),
  ]
  let out = []
  for case in cases {
    let (name, meth, path, response) = case
    let problems = match contract.check(meth, path, response) {
      [] => "conforms"
      problems => problems.join("; ")
    }
    out.push("\{name}: \{problems}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|status without warnings: : warnings is missing
      #|status without Smock-Replica: header Smock-Replica is missing
      #|a digest that is not 12 hex digits: /digest: "xyz" does not match ^[0-9a-f]{12}$
      #|status without a digest: /digest: null is not of type string
      #|a 401 without WWW-Authenticate: header WWW-Authenticate is missing
      #|an error code the document does not list: /error: "nope" is not one of ["unauthorized","not_found","method_not_allowed","malformed_json","invalid_request","invalid_stub","unknown_mock","unknown_stub","unknown_scenario","unknown_state","journal_off","not_started","not_ready","bad_request","content_too_large","header_fields_too_large","not_implemented","http_version_not_supported"]
      #|an undocumented field: /extra: no value is allowed here
      #|a failed reload with its errors: conforms
      #|a reload result the document does not list: /lastReload: {"at":"2026-10-13T01:02:03.004Z","result":"reloaded","err... matches 0 of oneOf, not 1
      #|a reload without its errors: /lastReload: {"at":"2026-10-13T01:02:03.004Z","result":"swapped"} matches 0 of oneOf, not 1
      #|a reload error without its pointer: /lastReload: {"at":"2026-10-13T01:02:03.004Z","result":"failed","error... matches 0 of oneOf, not 1
      #|a passing probe: conforms
      #|a passing probe with another status: /status: "ready" is not "ok"
      #|a failing probe: conforms
      #|a failing probe without its error code: : error is missing
      #|a passing probe with an undocumented field: /uptime: no value is allowed here
      #|a reload with an undocumented field: /lastReload: {"at":"2026-10-13T01:02:03.004Z","result":"unchanged","er... matches 0 of oneOf, not 1
      #|an added Ephemeral Stub: conforms
      #|an added Ephemeral Stub with weighted responses: conforms
      #|an added Ephemeral Stub with both response and responses: /stub: {"id":"eph-12","mock":"users","session":null,"response":{... matches 2 of oneOf, not 1
      #|an added Ephemeral Stub with a weight out of range: /stub/responses/0/weight: 0 is below 1
      #|an Ephemeral Stub ID that is not eph-<n>: /stub/id: "eph-0" does not match ^eph-[1-9][0-9]*$
      #|an added Ephemeral Stub without its Session: /stub: session is missing
      #|a listed Ephemeral Stub with a status out of range: /stubs/0/response/status: 99 is below 200
      #|a listed Ephemeral Stub with an undocumented field: /stubs/0/addedAt: no value is allowed here
      #|a listed Ephemeral Stub with a header array: conforms
      #|a listed Ephemeral Stub with an empty header array: /stubs/0/response/headers/Set-Cookie: [] matches 0 of oneOf, not 1
      #|a listed Ephemeral Stub with an array for Content-Type: /stubs/0/response/headers/content-type: ["text/plain"] is not of type string
      #|a deleted Ephemeral Stub with its Mock: /mock: no value is allowed here
      #|an unknown Ephemeral Stub: conforms
      #|a reset without the count of Journal entries: /removed: journalEntries is missing
      #|a reset without the count of Scenario states: /removed: scenarioStates is missing
      #|a reset with a scope the document does not list: /scope: "replica" is not one of ["session","mock","all"]
      #|a Journal page with an unmatched request: conforms
      #|a Journal entry for an Ephemeral Stub: conforms
      #|a Journal entry with the index of the response picked: conforms
      #|a Journal entry without its response index: /entries/0: responseIndex is missing
      #|a Journal entry with a response index out of range: /entries/0/responseIndex: 100 is above 99
      #|a Journal entry with the Variables written: conforms
      #|a Journal entry without its Variables written: /entries/0: variablesWritten is missing
      #|a Journal entry without its Stub source: /entries/0: stubSource is missing
      #|a Journal entry with a Stub source the document does not list: /entries/0/stubSource: "admin" is not one of ["file","ephemeral",null]
      #|a Journal entry with a Scenario move: conforms
      #|a Journal entry without its Scenario move: /entries/0: scenario is missing
      #|a Scenario move without the state it came from: /entries/0/scenario: {"name":"checkout","to":"Paid"} matches 0 of oneOf, not 1
      #|a Near miss that failed a Scenario state: conforms
      #|a Near miss that failed a Scenario state without its name: /entries/0/nearMiss: {"stub":"pay","stubSource":"file","failed":[{"condition":... matches 0 of oneOf, not 1
      #|a Near miss without its Stub source: /entries/0/nearMiss: {"stub":"get-user","failed":[]} matches 0 of oneOf, not 1
      #|a Journal entry without its sequence number: /entries/0: seq is missing
      #|a Journal entry with the sequence number 0: /entries/0/seq: 0 is below 1
      #|a Journal entry without its timing: /entries/0: durationMs is missing
      #|a Journal entry without its digest: /entries/0/digest: null is not of type string
      #|a Journal page without the eviction count: : evicted is missing
      #|a Journal query refused because the Journal is off: conforms
      #|a verification that passed: conforms
      #|a verification that failed because entries were evicted: conforms
      #|a verification with a reason the document does not list: /reason: "bound" is not one of ["count","evicted",null]
      #|a verification without the eviction count: : evicted is missing
      #|a verification with a count below 0: /count: -1 is below 0
      #|a verification refused because the Journal is off: conforms
      #|unmatched requests, one with its Near miss and one for an unknown Host: conforms
      #|unmatched requests without more: : more is missing
      #|a Near miss with a condition the document does not list: /entries/0/nearMiss: {"stub":"get-user","stubSource":"file","failed":[{"condit... matches 0 of oneOf, not 1
      #|unmatched requests refused because the Journal is off: conforms
    ),
  )
}
