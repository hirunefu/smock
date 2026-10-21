// Numbers sampled within their bounds. The tests show each body as the
// file writes it, so that the exact digits show, and CI runs them on native
// and on wasm-gc, against the same snapshots.

///|
/// The body that a `200` response of the media type `application/json`
/// with the schema `schema`, given as JSON text, gets in a document of the
/// OpenAPI version `openapi`: the problems, each on a line, then its `json`
/// as the JSON file writes it, with the line breaks and the indentation
/// taken out, so that each number shows the exact text the file holds; or
/// `nothing written`.
fn number_of(schema : String, openapi? : String = "3.1.0") -> String {
  let document = "{ \"openapi\": \"\{openapi}\", \"paths\": { \"/r\": { \"get\": { \"responses\": { \"200\": { \"content\": { \"application/json\": { \"schema\": \{schema} } } } } } } } }"
  let conversion = @importopenapi.convert(
    [("petstore.json", @utf8.encode(document))],
    @importopenapi.Options(root="petstore.json", mock="m", output="m.json"),
  )
  let out = StringBuilder()
  for problem in conversion.problems() {
    out.write_string(
      problem
      .to_string()
      .replace(
        old="/paths/~1r/get/responses/200/content/application~1json",
        new="",
      ),
    )
    out.write_char('\n')
  }
  guard conversion is Converted(file~, ..) else {
    out.write_string("nothing written")
    return out.to_string()
  }
  // The body is the last member of the response, which is the last member
  // of the one Stub, which ends the file.
  let compact = StringBuilder()
  let text = @utf8.decode_lossy(file)
  let mut indent = false
  for c in text {
    if c == '\n' {
      indent = true
    } else if !(indent && c == ' ') {
      indent = false
      compact.write_char(c)
    }
  }
  let compact = compact.to_string().replace_all(old="\": ", new="\":")
  guard compact.find("\"json\":") is Some(start) && compact.has_suffix("}}]}") else {
    out.write_string("no body")
    return out.to_string()
  }
  out.write_string(
    compact
    .view(start_offset=start + 7, end_offset=compact.length() - 4)
    .to_owned(),
  )
  out.to_string()
}

///|
/// What `number_of` gives for each of `schemas`, each on its own line,
/// after the schema.
fn numbers_of(schemas : Array[String], openapi? : String = "3.1.0") -> String {
  let out = StringBuilder()
  for schema in schemas {
    out.write_string("\{schema} => \{number_of(schema, openapi~)}\n")
  }
  out.to_string()
}

///|
test "a number samples as 0 when its bounds allow it, else as the nearest bound" {
  inspect(
    numbers_of([
      "{ \"type\": \"integer\", \"minimum\": 10, \"maximum\": 20 }", "{ \"type\": \"integer\", \"minimum\": -5 }",
      "{ \"type\": \"number\", \"minimum\": -5, \"maximum\": 5 }", "{ \"type\": \"number\", \"minimum\": 0 }",
      "{ \"type\": \"number\", \"maximum\": 0 }", "{ \"type\": \"number\", \"minimum\": 2.5 }",
      "{ \"type\": \"number\", \"maximum\": -2.5 }", "{ \"type\": \"integer\", \"minimum\": -20, \"maximum\": -10 }",
      "{ \"minimum\": 7 }", "{ \"type\": \"number\" }",
    ]),
    content=(
      #|{ "type": "integer", "minimum": 10, "maximum": 20 } => 10
      #|{ "type": "integer", "minimum": -5 } => 0
      #|{ "type": "number", "minimum": -5, "maximum": 5 } => 0
      #|{ "type": "number", "minimum": 0 } => 0
      #|{ "type": "number", "maximum": 0 } => 0
      #|{ "type": "number", "minimum": 2.5 } => 2.5
      #|{ "type": "number", "maximum": -2.5 } => -2.5
      #|{ "type": "integer", "minimum": -20, "maximum": -10 } => -10
      #|{ "minimum": 7 } => 7
      #|{ "type": "number" } => 0
      #|
    ),
  )
}

///|
test "in 3.1 and 3.2, exclusiveMinimum and exclusiveMaximum are numbers: the nearest bound moves by 1 inside an exclusive one, or to the middle of the two bounds when that leaves the range; the tighter of a bound and its exclusive form counts" {
  inspect(
    numbers_of([
      "{ \"type\": \"number\", \"exclusiveMinimum\": 0 }", "{ \"type\": \"number\", \"exclusiveMinimum\": 0, \"exclusiveMaximum\": 1 }",
      "{ \"type\": \"number\", \"exclusiveMaximum\": 0 }", "{ \"type\": \"number\", \"exclusiveMinimum\": -1 }",
      "{ \"type\": \"number\", \"exclusiveMinimum\": 2.5 }", "{ \"type\": \"number\", \"exclusiveMinimum\": 0, \"maximum\": 0.5 }",
      "{ \"type\": \"number\", \"exclusiveMinimum\": 0.1, \"exclusiveMaximum\": 0.2 }",
      "{ \"type\": \"number\", \"exclusiveMinimum\": -3, \"exclusiveMaximum\": -2 }",
      "{ \"type\": \"number\", \"minimum\": 0, \"exclusiveMinimum\": 5 }", "{ \"type\": \"number\", \"minimum\": 5, \"exclusiveMinimum\": 0 }",
      "{ \"type\": \"number\", \"minimum\": 5, \"exclusiveMinimum\": 5 }", "{ \"type\": \"number\", \"maximum\": -1, \"exclusiveMaximum\": -0.5 }",
      "{ \"type\": \"number\", \"maximum\": -1, \"exclusiveMaximum\": -1 }",
    ]),
    content=(
      #|{ "type": "number", "exclusiveMinimum": 0 } => 1
      #|{ "type": "number", "exclusiveMinimum": 0, "exclusiveMaximum": 1 } => 0.5
      #|{ "type": "number", "exclusiveMaximum": 0 } => -1
      #|{ "type": "number", "exclusiveMinimum": -1 } => 0
      #|{ "type": "number", "exclusiveMinimum": 2.5 } => 3.5
      #|{ "type": "number", "exclusiveMinimum": 0, "maximum": 0.5 } => 0.25
      #|{ "type": "number", "exclusiveMinimum": 0.1, "exclusiveMaximum": 0.2 } => 0.15
      #|{ "type": "number", "exclusiveMinimum": -3, "exclusiveMaximum": -2 } => -2.5
      #|{ "type": "number", "minimum": 0, "exclusiveMinimum": 5 } => 6
      #|{ "type": "number", "minimum": 5, "exclusiveMinimum": 0 } => 5
      #|{ "type": "number", "minimum": 5, "exclusiveMinimum": 5 } => 6
      #|{ "type": "number", "maximum": -1, "exclusiveMaximum": -0.5 } => -1
      #|{ "type": "number", "maximum": -1, "exclusiveMaximum": -1 } => -2
      #|
    ),
  )
}

///|
test "for an integer, a bound that is not whole is rounded inward, a lower bound up and an upper bound down, so an exclusive one then allows the integer it gives" {
  inspect(
    numbers_of([
      "{ \"type\": \"integer\", \"minimum\": 2.5 }", "{ \"type\": \"integer\", \"maximum\": -2.5 }",
      "{ \"type\": \"integer\", \"exclusiveMinimum\": 2.5 }", "{ \"type\": \"integer\", \"exclusiveMaximum\": -2.5 }",
      "{ \"type\": \"integer\", \"exclusiveMinimum\": 2 }", "{ \"type\": \"integer\", \"exclusiveMaximum\": -2 }",
      "{ \"type\": \"integer\", \"exclusiveMinimum\": 0.5, \"exclusiveMaximum\": 1.5 }",
      "{ \"type\": \"integer\", \"minimum\": 1.5, \"maximum\": 2.5 }", "{ \"type\": \"integer\", \"exclusiveMinimum\": 1.5, \"maximum\": 2 }",
      "{ \"type\": \"integer\", \"minimum\": -0.5, \"maximum\": 0.5 }", "{ \"format\": \"int32\", \"minimum\": 0.001 }",
    ]),
    content=(
      #|{ "type": "integer", "minimum": 2.5 } => 3
      #|{ "type": "integer", "maximum": -2.5 } => -3
      #|{ "type": "integer", "exclusiveMinimum": 2.5 } => 3
      #|{ "type": "integer", "exclusiveMaximum": -2.5 } => -3
      #|{ "type": "integer", "exclusiveMinimum": 2 } => 3
      #|{ "type": "integer", "exclusiveMaximum": -2 } => -3
      #|{ "type": "integer", "exclusiveMinimum": 0.5, "exclusiveMaximum": 1.5 } => 1
      #|{ "type": "integer", "minimum": 1.5, "maximum": 2.5 } => 2
      #|{ "type": "integer", "exclusiveMinimum": 1.5, "maximum": 2 } => 2
      #|{ "type": "integer", "minimum": -0.5, "maximum": 0.5 } => 0
      #|{ "format": "int32", "minimum": 0.001 } => 1
      #|
    ),
  )
}

///|
test "when no integer fits the bounds, the sample is the lower bound, rounded up, with a warning; so is a number's when no number fits" {
  inspect(
    numbers_of([
      "{ \"type\": \"integer\", \"minimum\": 0.25, \"maximum\": 0.75 }", "{ \"type\": \"integer\", \"exclusiveMinimum\": 0, \"exclusiveMaximum\": 1 }",
      "{ \"type\": \"integer\", \"exclusiveMinimum\": 2, \"maximum\": 2.5 }", "{ \"type\": \"integer\", \"minimum\": 3, \"maximum\": 2 }",
      "{ \"type\": \"integer\", \"minimum\": -3, \"maximum\": -5 }", "{ \"type\": \"number\", \"minimum\": 5, \"maximum\": 3 }",
      "{ \"type\": \"number\", \"exclusiveMinimum\": 1, \"exclusiveMaximum\": 1 }",
      "{ \"type\": \"number\", \"minimum\": 1, \"exclusiveMaximum\": 1 }",
    ]),
    content=(
      #|{ "type": "integer", "minimum": 0.25, "maximum": 0.75 } => petstore.json: /schema/minimum: warning: changed: no integer fits the bounds; the sample is the lower bound, rounded up
      #|1
      #|{ "type": "integer", "exclusiveMinimum": 0, "exclusiveMaximum": 1 } => petstore.json: /schema/exclusiveMinimum: warning: changed: no integer fits the bounds; the sample is the lower bound, rounded up
      #|0
      #|{ "type": "integer", "exclusiveMinimum": 2, "maximum": 2.5 } => petstore.json: /schema/exclusiveMinimum: warning: changed: no integer fits the bounds; the sample is the lower bound, rounded up
      #|2
      #|{ "type": "integer", "minimum": 3, "maximum": 2 } => petstore.json: /schema/minimum: warning: changed: no integer fits the bounds; the sample is the lower bound, rounded up
      #|3
      #|{ "type": "integer", "minimum": -3, "maximum": -5 } => petstore.json: /schema/minimum: warning: changed: no integer fits the bounds; the sample is the lower bound, rounded up
      #|-3
      #|{ "type": "number", "minimum": 5, "maximum": 3 } => petstore.json: /schema/minimum: warning: changed: no number fits the bounds; the sample is the lower bound
      #|5
      #|{ "type": "number", "exclusiveMinimum": 1, "exclusiveMaximum": 1 } => petstore.json: /schema/exclusiveMinimum: warning: changed: no number fits the bounds; the sample is the lower bound
      #|1
      #|{ "type": "number", "minimum": 1, "exclusiveMaximum": 1 } => petstore.json: /schema/minimum: warning: changed: no number fits the bounds; the sample is the lower bound
      #|1
      #|
    ),
  )
}

///|
test "in 3.0, exclusiveMinimum and exclusiveMaximum are true or false, and true makes minimum or maximum exclusive" {
  inspect(
    numbers_of(
      [
        "{ \"type\": \"integer\", \"minimum\": 0, \"exclusiveMinimum\": true }",
        "{ \"type\": \"number\", \"minimum\": 0, \"maximum\": 1, \"exclusiveMinimum\": true, \"exclusiveMaximum\": true }",
        "{ \"type\": \"number\", \"maximum\": 0, \"exclusiveMaximum\": true }", "{ \"type\": \"number\", \"minimum\": 5, \"exclusiveMinimum\": false }",
        "{ \"type\": \"number\", \"exclusiveMinimum\": true }", "{ \"type\": \"integer\", \"minimum\": 2.5, \"exclusiveMinimum\": true }",
        "{ \"type\": \"integer\", \"minimum\": 2, \"maximum\": 3, \"exclusiveMinimum\": true, \"exclusiveMaximum\": true }",
      ],
      openapi="3.0.3",
    ),
    content=(
      #|{ "type": "integer", "minimum": 0, "exclusiveMinimum": true } => 1
      #|{ "type": "number", "minimum": 0, "maximum": 1, "exclusiveMinimum": true, "exclusiveMaximum": true } => 0.5
      #|{ "type": "number", "maximum": 0, "exclusiveMaximum": true } => -1
      #|{ "type": "number", "minimum": 5, "exclusiveMinimum": false } => 5
      #|{ "type": "number", "exclusiveMinimum": true } => 0
      #|{ "type": "integer", "minimum": 2.5, "exclusiveMinimum": true } => 3
      #|{ "type": "integer", "minimum": 2, "maximum": 3, "exclusiveMinimum": true, "exclusiveMaximum": true } => petstore.json: /schema/minimum: warning: changed: no integer fits the bounds; the sample is the lower bound, rounded up
      #|2
      #|
    ),
  )
}

///|
test "a bound of the wrong type for the version is ignored, with a warning at its pointer, and the next layer that has a usable one gives it" {
  inspect(
    numbers_of(
      [
        "{ \"type\": \"number\", \"minimum\": 1, \"exclusiveMinimum\": 5 }", "{ \"type\": \"number\", \"minimum\": \"3\", \"maximum\": null }",
      ],
      openapi="3.0.3",
    ) +
    numbers_of([
      "{ \"type\": \"number\", \"minimum\": 1, \"exclusiveMinimum\": true }", "{ \"type\": \"number\", \"maximum\": -1, \"exclusiveMaximum\": \"-5\" }",
      "{ \"type\": \"number\", \"minimum\": \"3\", \"allOf\": [{ \"minimum\": true }, { \"minimum\": 3 }] }",
    ]) +
    numbers_of(
      ["{ \"type\": \"number\", \"exclusiveMinimum\": 0 }"],
      openapi="3.2.0",
    ),
    content=(
      #|{ "type": "number", "minimum": 1, "exclusiveMinimum": 5 } => petstore.json: /schema/exclusiveMinimum: warning: ignored: must be true or false in OpenAPI 3.0
      #|1
      #|{ "type": "number", "minimum": "3", "maximum": null } => petstore.json: /schema/minimum: warning: ignored: must be a number
      #|petstore.json: /schema/maximum: warning: ignored: must be a number
      #|0
      #|{ "type": "number", "minimum": 1, "exclusiveMinimum": true } => petstore.json: /schema/exclusiveMinimum: warning: ignored: must be a number in OpenAPI 3.1 and 3.2
      #|1
      #|{ "type": "number", "maximum": -1, "exclusiveMaximum": "-5" } => petstore.json: /schema/exclusiveMaximum: warning: ignored: must be a number in OpenAPI 3.1 and 3.2
      #|-1
      #|{ "type": "number", "minimum": "3", "allOf": [{ "minimum": true }, { "minimum": 3 }] } => petstore.json: /schema/minimum: warning: ignored: must be a number
      #|petstore.json: /schema/allOf/0/minimum: warning: ignored: must be a number
      #|3
      #|{ "type": "number", "exclusiveMinimum": 0 } => 1
      #|
    ),
  )
}

///|
test "the arithmetic is exact on the decimal text smock writes for a bound, with no float, and the file keeps every digit; a bound with more than 18 digits before or after the point is ignored, with a warning" {
  inspect(
    numbers_of([
      "{ \"type\": \"number\", \"minimum\": 123456789012345678 }", "{ \"type\": \"integer\", \"exclusiveMinimum\": 9007199254740993 }",
      "{ \"type\": \"number\", \"exclusiveMinimum\": 0.000000000000000001 }", "{ \"type\": \"number\", \"exclusiveMinimum\": 0, \"exclusiveMaximum\": 0.000000000000000001 }",
      "{ \"type\": \"number\", \"exclusiveMinimum\": 999999999999999998, \"exclusiveMaximum\": 999999999999999999 }",
      "{ \"type\": \"number\", \"exclusiveMinimum\": -999999999999999999, \"exclusiveMaximum\": -999999999999999998 }",
      "{ \"type\": \"number\", \"minimum\": 1E+2 }", "{ \"type\": \"number\", \"maximum\": -2.5e-3 }",
      "{ \"type\": \"number\", \"minimum\": 1e-7 }", "{ \"type\": \"number\", \"minimum\": 0.30000000000000001 }",
      "{ \"type\": \"number\", \"minimum\": 1234567890123456789 }", "{ \"type\": \"number\", \"exclusiveMinimum\": 1e-19 }",
      "{ \"type\": \"number\", \"minimum\": 1e20 }", "{ \"type\": \"number\", \"minimum\": 1e400, \"maximum\": -1e400 }",
      "{ \"type\": \"integer\", \"minimum\": 5e-324 }",
    ]),
    content=(
      #|{ "type": "number", "minimum": 123456789012345678 } => 123456789012345678
      #|{ "type": "integer", "exclusiveMinimum": 9007199254740993 } => 9007199254740994
      #|{ "type": "number", "exclusiveMinimum": 0.000000000000000001 } => 1.000000000000000001
      #|{ "type": "number", "exclusiveMinimum": 0, "exclusiveMaximum": 0.000000000000000001 } => 0.0000000000000000005
      #|{ "type": "number", "exclusiveMinimum": 999999999999999998, "exclusiveMaximum": 999999999999999999 } => 999999999999999998.5
      #|{ "type": "number", "exclusiveMinimum": -999999999999999999, "exclusiveMaximum": -999999999999999998 } => -999999999999999998.5
      #|{ "type": "number", "minimum": 1E+2 } => 100
      #|{ "type": "number", "maximum": -2.5e-3 } => -0.0025
      #|{ "type": "number", "minimum": 1e-7 } => 0.0000001
      #|{ "type": "number", "minimum": 0.30000000000000001 } => 0.3
      #|{ "type": "number", "minimum": 1234567890123456789 } => petstore.json: /schema/minimum: warning: ignored: a bound may have at most 18 digits before the point and 18 after
      #|0
      #|{ "type": "number", "exclusiveMinimum": 1e-19 } => petstore.json: /schema/exclusiveMinimum: warning: ignored: a bound may have at most 18 digits before the point and 18 after
      #|0
      #|{ "type": "number", "minimum": 1e20 } => petstore.json: /schema/minimum: warning: ignored: a bound may have at most 18 digits before the point and 18 after
      #|0
      #|{ "type": "number", "minimum": 1e400, "maximum": -1e400 } => petstore.json: /schema/minimum: warning: ignored: a bound may have at most 18 digits before the point and 18 after
      #|petstore.json: /schema/maximum: warning: ignored: a bound may have at most 18 digits before the point and 18 after
      #|0
      #|{ "type": "integer", "minimum": 5e-324 } => petstore.json: /schema/minimum: warning: ignored: a bound may have at most 18 digits before the point and 18 after
      #|0
      #|
    ),
  )
}

///|
test "numbers nested in objects and arrays sample within their bounds too, and the YAML file writes each as the JSON file does" {
  inspect(
    import_yaml(
      (
        #|openapi: 3.1.0
        #|paths:
        #|  /stock:
        #|    get:
        #|      operationId: stock
        #|      responses:
        #|        200:
        #|          content:
        #|            application/json:
        #|              schema:
        #|                type: object
        #|                properties:
        #|                  count: { type: integer, minimum: 10, maximum: 20 }
        #|                  offset: { type: integer, minimum: -5 }
        #|                  ratio: { type: number, exclusiveMinimum: 0 }
        #|                  weight: { type: number, exclusiveMinimum: 0, exclusiveMaximum: 1 }
        #|                  tiny: { type: number, exclusiveMinimum: 0, exclusiveMaximum: 0.000000000000000001 }
        #|                  scores:
        #|                    type: array
        #|                    minItems: 2
        #|                    items: { type: number, minimum: 0.5, maximum: 1 }
        #|                  levels:
        #|                    type: array
        #|                    minItems: 2
        #|                    prefixItems:
        #|                      - { type: integer, exclusiveMaximum: -3 }
        #|                      - type: object
        #|                        properties:
        #|                          depth: { type: integer, minimum: 1.5 }
      ),
      output="defs/stock.yaml",
    ),
    content=(
      #|1 Stubs from 1 operations
      #|# Generated by smock import-openapi from petstore.yaml
      #|# (OpenAPI 3.1.0), with --mock petstore.
      #|# Do not edit: the next import replaces this file.
      #|version: 1
      #|mocks:
      #|  - name: petstore
      #|stubs:
      #|  # GET /stock, 200
      #|  - id: petstore.stock.200
      #|    mock: petstore
      #|    request:
      #|      method: GET
      #|      path: /stock
      #|    response:
      #|      status: 200
      #|      json:
      #|        count: 10
      #|        offset: 0
      #|        ratio: 1
      #|        weight: 0.5
      #|        tiny: 0.0000000000000000005
      #|        scores:
      #|          - 0.5
      #|          - 0.5
      #|        levels:
      #|          - -4
      #|          - depth: 2
      #|
    ),
  )
}

///|
test "in allOf, each bound comes from the first layer that has a usable one, the schema's own first, not from the tightest" {
  inspect(
    numbers_of([
      "{ \"type\": \"integer\", \"allOf\": [{ \"minimum\": 3 }, { \"minimum\": 5 }] }",
      "{ \"type\": \"integer\", \"minimum\": 1, \"allOf\": [{ \"minimum\": 5 }] }",
      "{ \"type\": \"number\", \"exclusiveMinimum\": 1, \"allOf\": [{ \"minimum\": 4 }] }",
      "{ \"allOf\": [{ \"type\": \"integer\" }, { \"maximum\": -1.5 }] }", "{ \"type\": \"integer\", \"minimum\": 1, \"allOf\": [{ \"maximum\": 0.5 }] }",
    ]),
    content=(
      #|{ "type": "integer", "allOf": [{ "minimum": 3 }, { "minimum": 5 }] } => 3
      #|{ "type": "integer", "minimum": 1, "allOf": [{ "minimum": 5 }] } => 1
      #|{ "type": "number", "exclusiveMinimum": 1, "allOf": [{ "minimum": 4 }] } => 4
      #|{ "allOf": [{ "type": "integer" }, { "maximum": -1.5 }] } => -2
      #|{ "type": "integer", "minimum": 1, "allOf": [{ "maximum": 0.5 }] } => petstore.json: /schema/minimum: warning: changed: no integer fits the bounds; the sample is the lower bound, rounded up
      #|1
      #|
    ),
  )
}
