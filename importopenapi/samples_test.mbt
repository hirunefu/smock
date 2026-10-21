///|
/// The body that a `200` response of the media type `application/json`
/// with the schema `schema`, given as JSON text, gets in a document of the
/// OpenAPI version `openapi`: the problems, each on a line, then its `json`
/// as compact JSON, or `no body`, or `nothing written`.
fn sample_of(schema : String, openapi? : String = "3.1.0") -> String raise {
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
  let json = @json.parse(@utf8.decode_lossy(file)) catch {
    _ => fail("the file is not JSON")
  }
  match json {
    Object(
      { "stubs": Array([Object({ "response": Object(response), .. })]), .. }
    ) =>
      match response.get("json") {
        Some(json) => out.write_string(json.stringify())
        None => out.write_string("no body")
      }
    _ => fail("unexpected file: \{json.stringify()}")
  }
  out.to_string()
}

///|
/// What `sample_of` gives for each of `schemas`, each on its own line,
/// after the schema.
fn samples_of(
  schemas : Array[String],
  openapi? : String = "3.1.0",
) -> String raise {
  let out = StringBuilder()
  for schema in schemas {
    out.write_string("\{schema} => \{sample_of(schema, openapi~)}\n")
  }
  out.to_string()
}

///|
test "per schema, the sample is the first of const, the first of examples, example, default and the first of enum; then the type gives it" {
  inspect(
    samples_of([
      "{ \"type\": \"string\", \"const\": \"c\", \"examples\": [\"x\"], \"example\": \"e\", \"default\": \"d\", \"enum\": [\"n\"] }",
      "{ \"type\": \"string\", \"examples\": [\"x\", \"y\"], \"example\": \"e\", \"default\": \"d\", \"enum\": [\"n\"] }",
      "{ \"type\": \"string\", \"example\": \"e\", \"default\": \"d\", \"enum\": [\"n\"] }",
      "{ \"type\": \"string\", \"default\": \"d\", \"enum\": [\"n\", \"m\"] }", "{ \"type\": \"string\", \"enum\": [\"n\", \"m\"] }",
      "{ \"type\": \"string\", \"examples\": [], \"enum\": [] }", "{ \"type\": \"integer\", \"const\": null, \"example\": 1 }",
      "{ \"type\": \"object\", \"properties\": { \"a\": { \"type\": \"string\", \"example\": \"a1\" } }, \"default\": { \"b\": 2 } }",
    ]),
    content=(
      #|{ "type": "string", "const": "c", "examples": ["x"], "example": "e", "default": "d", "enum": ["n"] } => "c"
      #|{ "type": "string", "examples": ["x", "y"], "example": "e", "default": "d", "enum": ["n"] } => "x"
      #|{ "type": "string", "example": "e", "default": "d", "enum": ["n"] } => "e"
      #|{ "type": "string", "default": "d", "enum": ["n", "m"] } => "d"
      #|{ "type": "string", "enum": ["n", "m"] } => "n"
      #|{ "type": "string", "examples": [], "enum": [] } => "string"
      #|{ "type": "integer", "const": null, "example": 1 } => null
      #|{ "type": "object", "properties": { "a": { "type": "string", "example": "a1" } }, "default": { "b": 2 } } => {"b":2}
      #|
    ),
  )
}

///|
test "in 3.0, a schema has no examples; example comes first" {
  inspect(
    samples_of(
      [
        "{ \"type\": \"string\", \"examples\": [\"x\"], \"example\": \"e\" }", "{ \"type\": \"string\", \"examples\": \"x\" }",
      ],
      openapi="3.0.3",
    ),
    content=(
      #|{ "type": "string", "examples": ["x"], "example": "e" } => "e"
      #|{ "type": "string", "examples": "x" } => "string"
      #|
    ),
  )
}

///|
test "the values of const, examples, example, default and enum are copied as data: a $ref member in them, ${ and keys that start with $ stay as written" {
  inspect(
    samples_of([
      "{ \"const\": { \"$ref\": \"#/components/schemas/Pet\" } }", "{ \"example\": { \"$each\": \"${items}\", \"text\": \"${name}\", \"$$x\": 1 } }",
      "{ \"type\": \"object\", \"properties\": { \"$ref\": { \"type\": \"string\" }, \"${a}\": { \"default\": \"${b}\" } } }",
    ]),
    content=(
      #|{ "const": { "$ref": "#/components/schemas/Pet" } } => {"$ref":"#/components/schemas/Pet"}
      #|{ "example": { "$each": "${items}", "text": "${name}", "$$x": 1 } } => {"$each":"${items}","text":"${name}","$$x":1}
      #|{ "type": "object", "properties": { "$ref": { "type": "string" }, "${a}": { "default": "${b}" } } } => {"$ref":"string","${a}":"${b}"}
      #|
    ),
  )
}

///|
test "the type is the first other than null in a type array, in every version, and null when it is the only one; nullable changes nothing" {
  inspect(
    samples_of(
      [
        "{ \"type\": [\"null\", \"string\", \"integer\"] }", "{ \"type\": [\"null\"] }",
        "{ \"type\": \"null\" }", "{ \"type\": [\"boolean\", \"null\"] }", "{ \"type\": \"string\", \"nullable\": true }",
      ],
      openapi="3.0.3",
    ),
    content=(
      #|{ "type": ["null", "string", "integer"] } => "string"
      #|{ "type": ["null"] } => null
      #|{ "type": "null" } => null
      #|{ "type": ["boolean", "null"] } => true
      #|{ "type": "string", "nullable": true } => "string"
      #|
    ),
  )
}

///|
test "without a type, the sample takes the one the keywords imply: object, array, integer, number, then string, else null; true samples as null and false gives no body" {
  inspect(
    samples_of([
      "{ \"required\": [\"a\"], \"items\": {}, \"format\": \"int32\" }", "{ \"maxProperties\": 2 }",
      "{ \"additionalProperties\": { \"type\": \"string\" } }", "{ \"uniqueItems\": true, \"format\": \"int64\" }",
      "{ \"contains\": {} }", "{ \"format\": \"int64\", \"minimum\": 1 }", "{ \"format\": \"double\", \"minLength\": 1 }",
      "{ \"exclusiveMaximum\": 5, \"pattern\": \"^a\" }", "{ \"multipleOf\": 2 }",
      "{ \"format\": \"date\" }", "{ \"format\": \"my-format\" }", "{ \"pattern\": \"^[a-z]+$\" }",
      "{ \"maxLength\": 3 }", "{ \"description\": \"a\" }", "{}", "true", "false",
    ]),
    content=(
      #|{ "required": ["a"], "items": {}, "format": "int32" } => {}
      #|{ "maxProperties": 2 } => {}
      #|{ "additionalProperties": { "type": "string" } } => {}
      #|{ "uniqueItems": true, "format": "int64" } => []
      #|{ "contains": {} } => []
      #|{ "format": "int64", "minimum": 1 } => 0
      #|{ "format": "double", "minLength": 1 } => 0
      #|{ "exclusiveMaximum": 5, "pattern": "^a" } => 0
      #|{ "multipleOf": 2 } => 0
      #|{ "format": "date" } => "2000-01-01"
      #|{ "format": "my-format" } => "string"
      #|{ "pattern": "^[a-z]+$" } => "string"
      #|{ "maxLength": 3 } => "str"
      #|{ "description": "a" } => null
      #|{} => null
      #|true => null
      #|false => no body
      #|
    ),
  )
}

///|
test "a string samples as the fixed sample of its format, whatever its length bounds; any other format, or none, gives \"string\", repeated or cut to fit minLength and maxLength" {
  let formats = [
    "date-time", "date", "time", "duration", "email", "idn-email", "hostname", "idn-hostname",
    "ipv4", "ipv6", "uri", "uri-reference", "iri", "iri-reference", "uri-template",
    "uuid", "json-pointer", "relative-json-pointer", "regex", "byte", "binary", "password",
    "Date",
  ]
  inspect(
    samples_of(
      formats.map(format => {
        "{ \"type\": \"string\", \"format\": \"\{format}\", \"maxLength\": 2 }"
      }),
    ),
    content=(
      #|{ "type": "string", "format": "date-time", "maxLength": 2 } => "2000-01-01T00:00:00Z"
      #|{ "type": "string", "format": "date", "maxLength": 2 } => "2000-01-01"
      #|{ "type": "string", "format": "time", "maxLength": 2 } => "00:00:00Z"
      #|{ "type": "string", "format": "duration", "maxLength": 2 } => "P1D"
      #|{ "type": "string", "format": "email", "maxLength": 2 } => "user@example.com"
      #|{ "type": "string", "format": "idn-email", "maxLength": 2 } => "user@example.com"
      #|{ "type": "string", "format": "hostname", "maxLength": 2 } => "example.com"
      #|{ "type": "string", "format": "idn-hostname", "maxLength": 2 } => "example.com"
      #|{ "type": "string", "format": "ipv4", "maxLength": 2 } => "192.0.2.1"
      #|{ "type": "string", "format": "ipv6", "maxLength": 2 } => "2001:db8::1"
      #|{ "type": "string", "format": "uri", "maxLength": 2 } => "https://example.com/"
      #|{ "type": "string", "format": "uri-reference", "maxLength": 2 } => "https://example.com/"
      #|{ "type": "string", "format": "iri", "maxLength": 2 } => "https://example.com/"
      #|{ "type": "string", "format": "iri-reference", "maxLength": 2 } => "https://example.com/"
      #|{ "type": "string", "format": "uri-template", "maxLength": 2 } => "https://example.com/{id}"
      #|{ "type": "string", "format": "uuid", "maxLength": 2 } => "00000000-0000-4000-8000-000000000000"
      #|{ "type": "string", "format": "json-pointer", "maxLength": 2 } => "/a"
      #|{ "type": "string", "format": "relative-json-pointer", "maxLength": 2 } => "0"
      #|{ "type": "string", "format": "regex", "maxLength": 2 } => ".*"
      #|{ "type": "string", "format": "byte", "maxLength": 2 } => "c3RyaW5n"
      #|{ "type": "string", "format": "binary", "maxLength": 2 } => "st"
      #|{ "type": "string", "format": "password", "maxLength": 2 } => "st"
      #|{ "type": "string", "format": "Date", "maxLength": 2 } => "st"
      #|
    ),
  )
  inspect(
    samples_of([
      "{ \"type\": \"string\" }", "{ \"type\": \"string\", \"minLength\": 15 }",
      "{ \"type\": \"string\", \"maxLength\": 4 }", "{ \"type\": \"string\", \"maxLength\": 0 }",
      "{ \"type\": \"string\", \"minLength\": 3, \"maxLength\": 9 }", "{ \"type\": \"string\", \"minLength\": 8, \"maxLength\": 2 }",
      "{ \"type\": \"string\", \"minLength\": 2.0 }",
    ]),
    content=(
      #|{ "type": "string" } => "string"
      #|{ "type": "string", "minLength": 15 } => "stringstringstr"
      #|{ "type": "string", "maxLength": 4 } => "stri"
      #|{ "type": "string", "maxLength": 0 } => ""
      #|{ "type": "string", "minLength": 3, "maxLength": 9 } => "string"
      #|{ "type": "string", "minLength": 8, "maxLength": 2 } => "stringst"
      #|{ "type": "string", "minLength": 2.0 } => "string"
      #|
    ),
  )
}

///|
test "booleans sample as true, and numbers as 0 until numbers are sampled within their bounds" {
  inspect(
    samples_of([
      "{ \"type\": \"boolean\" }", "{ \"type\": \"integer\" }", "{ \"type\": \"number\", \"minimum\": 5 }",
    ]),
    content=(
      #|{ "type": "boolean" } => true
      #|{ "type": "integer" } => 0
      #|{ "type": "number", "minimum": 5 } => 0
      #|
    ),
  )
}

///|
test "an array has minItems items, at least 1 and at most 100, with a warning past 100; maxItems 0 gives []; items come from prefixItems, then items, and an array with neither gives []" {
  inspect(
    samples_of([
      "{ \"type\": \"array\", \"items\": { \"type\": \"string\" } }", "{ \"type\": \"array\", \"items\": { \"type\": \"boolean\" }, \"minItems\": 3 }",
      "{ \"type\": \"array\", \"items\": { \"type\": \"string\" }, \"minItems\": 0 }",
      "{ \"type\": \"array\", \"items\": { \"type\": \"string\" }, \"minItems\": 2, \"maxItems\": 0 }",
      "{ \"type\": \"array\", \"prefixItems\": [{ \"type\": \"integer\" }, { \"format\": \"date\" }], \"items\": { \"type\": \"boolean\" }, \"minItems\": 4 }",
      "{ \"type\": \"array\", \"prefixItems\": [{ \"type\": \"integer\" }, { \"format\": \"date\" }] }",
      "{ \"type\": \"array\", \"prefixItems\": [{ \"type\": \"integer\" }], \"minItems\": 3 }",
      "{ \"type\": \"array\", \"prefixItems\": [{ \"type\": \"integer\" }], \"items\": false, \"minItems\": 3 }",
      "{ \"type\": \"array\", \"minItems\": 2 }", "{ \"type\": \"array\", \"items\": true, \"minItems\": 2 }",
      "{ \"type\": \"array\", \"items\": { \"type\": \"array\", \"items\": {} } }",
    ]),
    content=(
      #|{ "type": "array", "items": { "type": "string" } } => ["string"]
      #|{ "type": "array", "items": { "type": "boolean" }, "minItems": 3 } => [true,true,true]
      #|{ "type": "array", "items": { "type": "string" }, "minItems": 0 } => ["string"]
      #|{ "type": "array", "items": { "type": "string" }, "minItems": 2, "maxItems": 0 } => []
      #|{ "type": "array", "prefixItems": [{ "type": "integer" }, { "format": "date" }], "items": { "type": "boolean" }, "minItems": 4 } => [0,"2000-01-01",true,true]
      #|{ "type": "array", "prefixItems": [{ "type": "integer" }, { "format": "date" }] } => [0]
      #|{ "type": "array", "prefixItems": [{ "type": "integer" }], "minItems": 3 } => [0]
      #|{ "type": "array", "prefixItems": [{ "type": "integer" }], "items": false, "minItems": 3 } => [0]
      #|{ "type": "array", "minItems": 2 } => []
      #|{ "type": "array", "items": true, "minItems": 2 } => [null,null]
      #|{ "type": "array", "items": { "type": "array", "items": {} } } => [[null]]
      #|
    ),
  )
  let many = sample_of(
    "{ \"type\": \"array\", \"items\": { \"type\": \"boolean\" }, \"minItems\": 250 }",
  )
  let lines = many.split("\n").map(line => line.to_owned()).collect()
  inspect(
    lines[0],
    content="petstore.json: /schema/minItems: warning: changed: the sample has 100 items, the most a sample has, not 250",
  )
  guard @json.parse(lines[1]) is Array(items) else { fail("not an array") }
  inspect(
    "\{items.length()} items, all \{items.iter().all(item => item is True)}",
    content="100 items, all true",
  )
}

///|
test "an object has every property in properties, required or not, in the order written, except writeOnly ones and those whose schema is false; additionalProperties and patternProperties add nothing, and a name in required without a property is not added" {
  inspect(
    samples_of([
      (
        #|{
        #|  "type": "object",
        #|  "required": ["id", "missing"],
        #|  "properties": {
        #|    "name": { "type": "string" },
        #|    "id": { "type": "string", "format": "uuid", "readOnly": true },
        #|    "password": { "type": "string", "writeOnly": true },
        #|    "never": false,
        #|    "anything": true,
        #|    "address": {
        #|      "type": "object",
        #|      "properties": { "city": { "type": "string" }, "pin": { "writeOnly": true } }
        #|    }
        #|  },
        #|  "additionalProperties": { "type": "string" },
        #|  "patternProperties": { "^x-": { "type": "string" } }
        #|}
      ),
      "{ \"type\": \"object\" }",
    ]),
    content=(
      #|{
      #|  "type": "object",
      #|  "required": ["id", "missing"],
      #|  "properties": {
      #|    "name": { "type": "string" },
      #|    "id": { "type": "string", "format": "uuid", "readOnly": true },
      #|    "password": { "type": "string", "writeOnly": true },
      #|    "never": false,
      #|    "anything": true,
      #|    "address": {
      #|      "type": "object",
      #|      "properties": { "city": { "type": "string" }, "pin": { "writeOnly": true } }
      #|    }
      #|  },
      #|  "additionalProperties": { "type": "string" },
      #|  "patternProperties": { "^x-": { "type": "string" } }
      #|} => {"name":"string","id":"00000000-0000-4000-8000-000000000000","anything":null,"address":{"city":"string"}}
      #|{ "type": "object" } => {}
      #|
    ),
  )
}

///|
test "a keyword the sampler reads that has the wrong type is ignored, with a warning at its pointer" {
  inspect(
    samples_of([
      "{ \"type\": \"text\" }", "{ \"type\": [] }", "{ \"type\": [\"string\", 1], \"maxLength\": 2 }",
      "{ \"examples\": { \"a\": 1 }, \"enum\": \"b\", \"type\": \"boolean\" }", "{ \"format\": 5, \"maxLength\": 2 }",
      "{ \"type\": \"string\", \"minLength\": \"3\", \"maxLength\": -1 }", "{ \"type\": \"string\", \"maxLength\": 2.5 }",
      "{ \"type\": \"array\", \"minItems\": \"3\", \"maxItems\": true, \"items\": { \"type\": \"integer\" } }",
      "{ \"type\": \"array\", \"prefixItems\": { \"type\": \"string\" }, \"items\": [{ \"type\": \"string\" }] }",
      "{ \"type\": \"array\", \"prefixItems\": [{ \"type\": \"integer\" }, 5, { \"type\": \"string\" }], \"minItems\": 3 }",
      "{ \"type\": \"object\", \"properties\": [] }", "{ \"type\": \"object\", \"properties\": { \"a\": \"string\", \"b\": { \"type\": \"string\", \"writeOnly\": \"yes\" } } }",
    ]),
    content=(
      #|{ "type": "text" } => petstore.json: /schema/type: warning: ignored: must be a type, such as "string", or a non-empty array of types
      #|null
      #|{ "type": [] } => petstore.json: /schema/type: warning: ignored: must be a type, such as "string", or a non-empty array of types
      #|null
      #|{ "type": ["string", 1], "maxLength": 2 } => petstore.json: /schema/type: warning: ignored: must be a type, such as "string", or a non-empty array of types
      #|"st"
      #|{ "examples": { "a": 1 }, "enum": "b", "type": "boolean" } => petstore.json: /schema/examples: warning: ignored: must be an array
      #|petstore.json: /schema/enum: warning: ignored: must be an array
      #|true
      #|{ "format": 5, "maxLength": 2 } => petstore.json: /schema/format: warning: ignored: must be a string
      #|"st"
      #|{ "type": "string", "minLength": "3", "maxLength": -1 } => petstore.json: /schema/minLength: warning: ignored: must be a non-negative integer
      #|petstore.json: /schema/maxLength: warning: ignored: must be a non-negative integer
      #|"string"
      #|{ "type": "string", "maxLength": 2.5 } => petstore.json: /schema/maxLength: warning: ignored: must be a non-negative integer
      #|"string"
      #|{ "type": "array", "minItems": "3", "maxItems": true, "items": { "type": "integer" } } => petstore.json: /schema/minItems: warning: ignored: must be a non-negative integer
      #|petstore.json: /schema/maxItems: warning: ignored: must be a non-negative integer
      #|[0]
      #|{ "type": "array", "prefixItems": { "type": "string" }, "items": [{ "type": "string" }] } => petstore.json: /schema/prefixItems: warning: ignored: must be an array
      #|petstore.json: /schema/items: warning: ignored: must be a schema, an object or a boolean
      #|[]
      #|{ "type": "array", "prefixItems": [{ "type": "integer" }, 5, { "type": "string" }], "minItems": 3 } => petstore.json: /schema/prefixItems/1: warning: ignored: must be a schema, an object or a boolean
      #|[0]
      #|{ "type": "object", "properties": [] } => petstore.json: /schema/properties: warning: ignored: must be an object
      #|{}
      #|{ "type": "object", "properties": { "a": "string", "b": { "type": "string", "writeOnly": "yes" } } } => petstore.json: /schema/properties/a: warning: ignored: must be a schema, an object or a boolean
      #|petstore.json: /schema/properties/b/writeOnly: warning: ignored: must be true or false
      #|{"b":"string"}
      #|
    ),
  )
}

///|
test "pattern, multipleOf, uniqueItems, contains, property counts, propertyNames, dependent, unevaluated and content keywords are ignored without a warning, so a sample may not satisfy them" {
  inspect(
    samples_of([
      "{ \"type\": \"string\", \"pattern\": \"^[0-9]+$\", \"contentMediaType\": \"application/json\", \"contentEncoding\": \"base64\" }",
      "{ \"type\": \"integer\", \"multipleOf\": 7 }", "{ \"type\": \"array\", \"items\": { \"type\": \"string\" }, \"minItems\": 2, \"uniqueItems\": true, \"contains\": { \"type\": \"integer\" }, \"unevaluatedItems\": false }",
      "{ \"type\": \"object\", \"minProperties\": 3, \"propertyNames\": { \"pattern\": \"^x\" }, \"dependentRequired\": { \"a\": [\"b\"] }, \"dependentSchemas\": {}, \"unevaluatedProperties\": false, \"properties\": { \"a\": { \"type\": \"string\" } } }",
    ]),
    content=(
      #|{ "type": "string", "pattern": "^[0-9]+$", "contentMediaType": "application/json", "contentEncoding": "base64" } => "string"
      #|{ "type": "integer", "multipleOf": 7 } => 0
      #|{ "type": "array", "items": { "type": "string" }, "minItems": 2, "uniqueItems": true, "contains": { "type": "integer" }, "unevaluatedItems": false } => ["string","string"]
      #|{ "type": "object", "minProperties": 3, "propertyNames": { "pattern": "^x" }, "dependentRequired": { "a": ["b"] }, "dependentSchemas": {}, "unevaluatedProperties": false, "properties": { "a": { "type": "string" } } } => {"a":"string"}
      #|
    ),
  )
}

///|
test "until their tickets, allOf, oneOf and anyOf add nothing, and a schema $ref is an error at the $ref that says it is not followed yet; a $ref in example data is data" {
  inspect(
    samples_of([
      "{ \"allOf\": [{ \"type\": \"string\" }] }", "{ \"type\": \"object\", \"oneOf\": [{ \"properties\": { \"a\": { \"type\": \"string\" } } }], \"anyOf\": [{ \"type\": \"null\" }] }",
      "{ \"type\": \"object\", \"properties\": { \"pet\": { \"$ref\": \"#/components/schemas/Pet\" } } }",
      "{ \"type\": \"array\", \"items\": { \"$ref\": \"#/components/schemas/Pet\", \"type\": \"string\" } }",
      "{ \"type\": \"object\", \"properties\": { \"pet\": { \"$ref\": \"#/components/schemas/Pet\", \"writeOnly\": true } } }",
      "{ \"allOf\": [{ \"$ref\": \"#/components/schemas/Pet\" }], \"example\": { \"$ref\": \"#/x\" } }",
    ]),
    content=(
      #|{ "allOf": [{ "type": "string" }] } => null
      #|{ "type": "object", "oneOf": [{ "properties": { "a": { "type": "string" } } }], "anyOf": [{ "type": "null" }] } => {}
      #|{ "type": "object", "properties": { "pet": { "$ref": "#/components/schemas/Pet" } } } => petstore.json: /schema/properties/pet/$ref: schema references are not followed yet: write the schema it names in its place
      #|nothing written
      #|{ "type": "array", "items": { "$ref": "#/components/schemas/Pet", "type": "string" } } => petstore.json: /schema/items/$ref: schema references are not followed yet: write the schema it names in its place
      #|nothing written
      #|{ "type": "object", "properties": { "pet": { "$ref": "#/components/schemas/Pet", "writeOnly": true } } } => {}
      #|{ "allOf": [{ "$ref": "#/components/schemas/Pet" }], "example": { "$ref": "#/x" } } => {"$ref":"#/x"}
      #|
    ),
  )
  inspect(
    sample_of(
      "{ \"type\": \"object\", \"properties\": { \"pet\": { \"$ref\": \"#/components/schemas/Pet\", \"writeOnly\": true } } }",
      openapi="3.0.3",
    ),
    content=(
      #|petstore.json: /schema/properties/pet/$ref: schema references are not followed yet: write the schema it names in its place
      #|nothing written
    ),
  )
}
