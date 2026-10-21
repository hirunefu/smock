// The size of samples: a sample is first made with every property. When its
// compact JSON would pass 64 KiB, it is made again with only the required
// parts below the first level. When that would pass 1 MiB, the body is left
// empty, with a warning. The sampler stops as soon as a bound is passed.

///|
/// Converts a document whose only operation is `GET /r`, whose `200`
/// response is `application/json` with the schema `schema` and whose
/// `components.schemas` are `schemas`, into a YAML file, and renders the
/// problems, each on a line, then the Stub's comment, then its body as
/// compact JSON, `no body`, or `nothing written`. A body longer than 200
/// characters is given by its length. Pointers into the media type are
/// written from `/schema`.
fn sized(schema : String, schemas? : String = "{}") -> String raise {
  let document = "{ \"openapi\": \"3.1.0\", \"paths\": { \"/r\": { \"get\": { \"responses\": { \"200\": { \"content\": { \"application/json\": { \"schema\": \{schema} } } } } } } }, \"components\": { \"schemas\": \{schemas} } }"
  let conversion = @importopenapi.convert(
    [("petstore.json", @utf8.encode(document))],
    @importopenapi.Options(root="petstore.json", mock="m", output="m.yaml"),
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
  let text = @utf8.decode_lossy(file)
  for line in text.split("\n") {
    if line.has_prefix("  # ") {
      out.write_string("\{line[4:]}\n")
    }
  }
  let json = @yaml.parse(text) catch { _ => fail("the file is not YAML") }
  match json {
    Object(
      { "stubs": Array([Object({ "response": Object(response), .. })]), .. }
    ) =>
      match response.get("json") {
        Some(json) => {
          let body = @template.compact_json(json)
          if body.length() > 200 {
            out.write_string("a body of \{body.length()} bytes")
          } else {
            out.write_string(body)
          }
        }
        None => out.write_string("no body")
      }
    _ => fail("unexpected file: \{json.stringify()}")
  }
  out.to_string()
}

///|
test "a sample whose compact JSON would pass 64 KiB is made again with only the required properties, and only minItems items, in every object and array nested more than one level below the body; the Stub's comment says sample cut" {
  let schemas =
    #|{
    #|  "Item": {
    #|    "type": "object",
    #|    "required": ["id"],
    #|    "properties": { "id": { "type": "string" }, "blob": { "type": "string", "minLength": 30000 } }
    #|  }
    #|}
  let schema =
    #|{
    #|  "type": "object",
    #|  "properties": {
    #|    "items": { "type": "array", "minItems": 3, "items": { "$ref": "#/components/schemas/Item" } },
    #|    "meta": {
    #|      "type": "object",
    #|      "properties": {
    #|        "a": { "type": "string" },
    #|        "inner": { "type": "object", "required": ["x"], "properties": { "x": { "type": "integer" }, "y": { "type": "integer" } } },
    #|        "tags": { "type": "array", "items": { "type": "string" } },
    #|        "pair": { "type": "array", "minItems": 2, "items": { "type": "boolean" } }
    #|      }
    #|    },
    #|    "note": { "type": "string", "minLength": 10 }
    #|  }
    #|}
  inspect(
    sized(schema, schemas~),
    content=(
      #|GET /r, 200, sample cut
      #|{"items":[{"id":"string"},{"id":"string"},{"id":"string"}],"meta":{"a":"string","inner":{"x":0},"tags":[],"pair":[true,true]},"note":"stringstri"}
    ),
  )
}

///|
test "the bound is on the compact JSON of the sample: 64 KiB exactly is not cut, one byte more is" {
  // {"a":{"b":{"s":"…"}}} is 20 bytes and the string's length.
  let schema = fn(length : Int) {
    "{ \"type\": \"object\", \"properties\": { \"a\": { \"type\": \"object\", \"properties\": { \"b\": { \"type\": \"object\", \"properties\": { \"s\": { \"type\": \"string\", \"minLength\": \{length} } } } } } } }"
  }
  inspect(
    sized(schema(65516)) + "\n" + sized(schema(65517)),
    content=(
      #|GET /r, 200
      #|a body of 65536 bytes
      #|GET /r, 200, sample cut
      #|{"a":{"b":{}}}
    ),
  )
}

///|
test "when the second sample would pass 1 MiB, the body is left empty, with a warning; 1 MiB exactly is written" {
  inspect(
    sized("{ \"type\": \"string\", \"minLength\": 1048574 }") +
    "\n" +
    sized("{ \"type\": \"string\", \"minLength\": 1048575 }"),
    content=(
      #|GET /r, 200, sample cut
      #|a body of 1048576 bytes
      #|petstore.json: /schema: warning: left out: the body is empty, since its sample would be more than 1 MiB, even cut to its required parts
      #|GET /r, 200
      #|no body
    ),
  )
}

///|
test "only the problems of the sample that is written are reported: those of a sample that is made again are not" {
  let schema =
    #|{
    #|  "type": "object",
    #|  "properties": {
    #|    "a": {
    #|      "type": "object",
    #|      "properties": {
    #|        "b": {
    #|          "type": "object",
    #|          "required": ["kept"],
    #|          "properties": {
    #|            "kept": { "type": "string", "maxLength": "3" },
    #|            "dropped": { "type": "string", "minLength": 70000, "format": 5 }
    #|          }
    #|        }
    #|      }
    #|    }
    #|  }
    #|}
  inspect(
    sized(schema),
    content=(
      #|petstore.json: /schema/properties/a/properties/b/properties/kept/maxLength: warning: ignored: must be a non-negative integer
      #|GET /r, 200, sample cut
      #|{"a":{"b":{"kept":"string"}}}
    ),
  )
}

///|
test "a schema whose full sample would be enormous ends quickly, with a bounded result" {
  // 40 levels of objects with 12 properties each, every one naming the next
  // level: 12^40 values with every property.
  let levels = []
  for i in 0..<40 {
    let properties = []
    for p in 0..<12 {
      properties.push(
        "\"p\{p}\": { \"$ref\": \"#/components/schemas/L\{i + 1}\" }",
      )
    }
    levels.push(
      "\"L\{i}\": { \"type\": \"object\", \"required\": [\"p0\"], \"properties\": { \{properties.join(", ")} } }",
    )
  }
  levels.push("\"L40\": { \"type\": \"integer\" }")
  let wide = sized(
    "{ \"$ref\": \"#/components/schemas/L0\" }",
    schemas="{ \{levels.join(", ")} }",
  )
  // Arrays of 100 arrays, 6 levels: 100^6 items.
  let mut arrays = "{ \"type\": \"string\", \"format\": \"uuid\" }"
  for _ in 0..<6 {
    arrays = "{ \"type\": \"array\", \"minItems\": 100, \"items\": \{arrays} }"
  }
  inspect(
    [
      wide,
      sized(arrays),
      sized("{ \"type\": \"string\", \"minLength\": 1000000000 }"),
    ].join("\n"),
    content=(
      #|GET /r, 200, sample cut
      #|a body of 31791 bytes
      #|petstore.json: /schema: warning: left out: the body is empty, since its sample would be more than 1 MiB, even cut to its required parts
      #|GET /r, 200
      #|no body
      #|petstore.json: /schema: warning: left out: the body is empty, since its sample would be more than 1 MiB, even cut to its required parts
      #|GET /r, 200
      #|no body
    ),
  )
}

///|
test "in YAML, the Stub's comment says sample cut after the response key, before deprecated" {
  let document =
    #|{
    #|  "openapi": "3.1.0",
    #|  "paths": {
    #|    "/r": {
    #|      "get": {
    #|        "summary": "Read it",
    #|        "deprecated": true,
    #|        "responses": {
    #|          "200": { "content": { "application/json": { "schema": { "type": "string", "minLength": 70000 } } } },
    #|          "404": { "content": { "application/json": { "schema": { "type": "string" } } } }
    #|        }
    #|      }
    #|    }
    #|  }
    #|}
  let conversion = @importopenapi.convert(
    [("petstore.json", @utf8.encode(document))],
    @importopenapi.Options(root="petstore.json", mock="m", output="m.yaml"),
  )
  guard conversion is Converted(file~, ..) else { fail("nothing written") }
  let comments = []
  for line in @utf8.decode_lossy(file).split("\n") {
    if line.has_prefix("  # ") {
      comments.push(line[4:].to_owned())
    }
  }
  inspect(
    comments.join("\n"),
    content=(
      #|GET /r, 404, deprecated: Read it
      #|GET /r, 200, sample cut, deprecated: Read it
    ),
  )
}
