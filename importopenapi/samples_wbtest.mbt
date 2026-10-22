// The nesting bound of bodies. The parsers read at most 1024 levels, and a
// body sits deeper in a document than in the file, so no document read from
// bytes passes the bound until samples nest through references. These tests
// give the converter a document built in memory instead.

///|
/// The conversion of `document`, a root document built in memory, with the
/// options `options` and no other document.
fn in_memory(options : Options, document : Document) -> Conversion {
  let report = Report::new(options)
  {
    options,
    documents: report.documents,
    needed: report.needed,
    document,
    report,
  }
}

///|
/// An array nested `levels` deep, empty ones included.
fn nested(levels : Int) -> Json {
  let mut json = Json::array([])
  for _ in 1..<levels {
    json = Json::array([json])
  }
  json
}

///|
/// Converts a document whose only operation is `GET /r`, whose `200`
/// response is `application/json` with the schema `schema`, into the file
/// `output`, and renders the problems, one per line, then the keys of the
/// body, or what else the conversion gave.
fn deep_sample(schema : Json, output : String) -> String {
  let top : Map[String, Json] = {
    "openapi": "3.1.0",
    "paths": {
      "/r": {
        "get": {
          "responses": {
            "200": { "content": { "application/json": { "schema": schema } } },
          },
        },
      },
    },
  }
  let conversion = in_memory(Options(root="api.json", mock="m", output~), {
    top,
    openapi: "3.1.0",
    title: "",
    info_version: "",
    prefix: "",
  })
  let outcome = conversion.file(conversion.operations())
  let lines = outcome.problems().map(problem => problem.to_string())
  match outcome {
    // The converter wrote the file only after loading it.
    Converted(file~, ..) => {
      let text = @utf8.decode_lossy(file)
      let json = if output.has_suffix(".yaml") {
        @yaml.parse(text) catch {
          _ => Json::null()
        }
      } else {
        @json.parse(text) catch {
          _ => Json::null()
        }
      }
      match json {
        Object({ "stubs": [{ "response": Object(response), .. }], .. }) =>
          match response.get("json") {
            Some(Object(body)) =>
              lines.push(
                "written, with the body keys \{body.keys().collect().join(", ")}",
              )
            Some(_) => lines.push("written, with a body")
            None => lines.push("written, with no body")
          }
        _ => lines.push("written, but not read back")
      }
    }
    Failed(_) | Needs(_) => lines.push("nothing written")
  }
  lines.join("\n")
}

///|
test "a value nested so deep that the file would pass the parsers' limit of 1024 levels is left out of its body, with a warning, in JSON and in YAML" {
  let schema : Json = {
    "type": "object",
    "properties": {
      "fits": { "const": nested(max_nesting - 5) },
      "deep": { "const": nested(max_nesting - 4) },
    },
  }
  for output in ["m.json", "m.yaml"] {
    inspect(
      deep_sample(schema, output),
      content=(
        #|api.json: /paths/~1r/get/responses/200/content/application~1json/schema/properties/deep/const: warning: left out: the value would nest deeper than 1024 levels in the file, the most the parsers read
        #|written, with the body keys fits
      ),
    )
  }
  inspect(
    deep_sample({ "const": nested(max_nesting - 4) }, "m.json"),
    content="written, with a body",
  )
  inspect(
    deep_sample({ "const": nested(max_nesting - 3) }, "m.yaml"),
    content=(
      #|api.json: /paths/~1r/get/responses/200/content/application~1json/schema/const: warning: left out: the value would nest deeper than 1024 levels in the file, the most the parsers read
      #|written, with no body
    ),
  )
}

///|
test "compact_size gives the length of the compact JSON smock writes, and stops past its limit" {
  let values : Array[Json] = [
    Json::null(),
    true,
    false,
    Json::number(1.5),
    Json::number(10, repr="10.000"),
    "plain",
    "quote \" backslash \\ tab \t newline \n return \r back \b feed \u{0c}",
    "control \u{01}\u{1f} DEL \u{7f}",
    "café 中文 😀",
    [],
    {},
    [1, [2, [3, []]], { "a": {} }],
    { "k\"ey": "v", "é": [true, null], "": { "x": -0.25 } },
  ]
  for value in values {
    let bytes = @template.compact_json_bytes(value).length()
    assert_eq(compact_size(value, 1000), bytes)
    assert_true(compact_size(value, bytes) == bytes)
    if bytes > 4 {
      assert_true(compact_size(value, bytes - 2) > bytes - 2)
    }
  }
  // A long value is not walked to its end.
  let long : Json = { "a": ["x".repeat(1000000), "y".repeat(1000000)] }
  let size = compact_size(long, 1000)
  assert_true(size > 1000 && size < 1010)
}

///|
test "a sample takes exactly the bytes of its compact JSON" {
  let schemas : Array[Json] = [
    {
      "type": "object",
      "required": ["self"],
      "properties": {
        "k\"é": { "const": "a\tb\u{01}c 😀" },
        "n": {
          "type": "number",
          "exclusiveMinimum": 0,
          "exclusiveMaximum": Json::number(1.0e-18, repr="1e-18"),
        },
        "i": { "type": "integer", "minimum": 12 },
        "f": { "format": "date-time" },
        "s": { "minLength": 9 },
        "b": { "type": "boolean" },
        "z": { "type": "null" },
        "tuple": {
          "prefixItems": [{ "type": "string" }, { "type": "integer" }],
          "items": { "type": "object", "properties": { "x": {} } },
          "minItems": 5,
        },
        "w": { "writeOnly": true, "type": "string" },
        "self": { "$ref": "#/components/schemas/Node" },
        "kids": { "items": { "$ref": "#/components/schemas/Node" } },
        "deep": { "$ref": "#/components/schemas/Chain" },
      },
    },
  ]
  let mut chain : Json = { "type": "string" }
  for _ in 0..<40 {
    chain = { "type": "array", "items": chain }
  }
  let top : Map[String, Json] = {
    "openapi": "3.1.0",
    "components": {
      "schemas": {
        "Node": { "type": "object", "properties": { "n": schemas[0] } },
        "Chain": chain,
      },
    },
  }
  let document = {
    top,
    openapi: "3.1.0",
    title: "",
    info_version: "",
    prefix: "",
  }
  for schema in schemas {
    let conversion = in_memory(
      Options(root="api.json", mock="m", output="m.json"),
      document,
    )
    let sampler = conversion.sampler(cut=false)
    let sample = sampler.sample(Place::root("/s"), schema, 0) catch {
      Passed => fail("the sample passed its bound")
    }
    guard sample is Some(sample) else { fail("no sample") }
    assert_eq(
      max_full_sample_bytes - sampler.left,
      @template.compact_json_bytes(sample).length(),
    )
  }
}
