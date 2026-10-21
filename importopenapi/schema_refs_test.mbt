// Schema references, identifiers and recursion: a `$ref` in a schema is
// followed, by the rules of other references, and a schema reached again
// through the `$ref` it is generated from ends the sample there.

///|
/// The body that a `200` response of the media type `application/json`
/// gets, in a document of the OpenAPI version `openapi`, when its schema is
/// `schema` and the document's `components.schemas` are `schemas`, both
/// given as JSON text, as `body_of` renders it.
fn referenced_sample(
  schema : String,
  schemas : String,
  openapi? : String = "3.1.0",
) -> String raise {
  body_of(
    "{ \"openapi\": \"\{openapi}\", \"paths\": { \"/r\": { \"get\": { \"responses\": { \"200\": { \"content\": { \"application/json\": { \"schema\": \{schema} } } } } } } }, \"components\": { \"schemas\": \{schemas} } }",
  )
}

///|
/// The body of the one Stub that converting `document`, whose only
/// operation is `GET /r` with a `200` response of the media type
/// `application/json`, gives: the problems, each on a line, then its
/// `json` as compact JSON, or `no body`, or `nothing written`. Pointers
/// into the media type are written from `/schema`.
fn body_of(document : String) -> String raise {
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
test "a schema $ref is followed within the document, as if the schema it names were written in place, in a property, in items and in a branch too" {
  let schemas =
    #|{
    #|  "Pet": { "type": "object", "properties": { "name": { "type": "string" }, "tag": { "$ref": "#/components/schemas/Tag" } } },
    #|  "Tag": { "type": "string", "format": "uuid" },
    #|  "Named": { "$ref": "#/components/schemas/Pet" }
    #|}
  inspect(
    referenced_sample("{ \"$ref\": \"#/components/schemas/Pet\" }", schemas),
    content=(
      #|{"name":"string","tag":"00000000-0000-4000-8000-000000000000"}
    ),
  )
  inspect(
    referenced_sample(
      "{ \"type\": \"array\", \"items\": { \"$ref\": \"#/components/schemas/Named\" } }",
      schemas,
    ),
    content=(
      #|[{"name":"string","tag":"00000000-0000-4000-8000-000000000000"}]
    ),
  )
  inspect(
    referenced_sample(
      "{ \"allOf\": [{ \"$ref\": \"#/components/schemas/Pet\" }, { \"properties\": { \"id\": { \"type\": \"integer\" } } }] }",
      schemas,
      openapi="3.0.3",
    ),
    content=(
      #|{"name":"string","tag":"00000000-0000-4000-8000-000000000000","id":0}
    ),
  )
}

///|
test "in 3.1 and 3.2, a $ref with keywords beside it is merged with them, as allOf would be, and they come first; in 3.0, the keywords beside a $ref are ignored" {
  let schemas =
    #|{
    #|  "Name": { "type": "string", "maxLength": 3, "example": "Rex" },
    #|  "Pet": { "type": "object", "required": ["name"], "properties": { "name": { "type": "string" } }, "example": { "name": "Tom" } },
    #|  "Animal": { "type": "object", "required": ["name"], "properties": { "name": { "type": "string" } } }
    #|}
  let with_siblings = [
    "{ \"$ref\": \"#/components/schemas/Name\", \"example\": \"Max\" }", "{ \"$ref\": \"#/components/schemas/Name\", \"minLength\": 5 }",
    "{ \"$ref\": \"#/components/schemas/Pet\", \"description\": \"A pet\" }", "{ \"$ref\": \"#/components/schemas/Pet\", \"example\": { \"name\": \"Kit\" } }",
    "{ \"$ref\": \"#/components/schemas/Animal\", \"properties\": { \"age\": { \"type\": \"integer\" } } }",
    "{ \"$ref\": \"#/components/schemas/Animal\", \"allOf\": [{ \"properties\": { \"id\": { \"format\": \"uuid\" } } }] }",
    "{ \"allOf\": [{ \"$ref\": \"#/components/schemas/Pet\" }, { \"properties\": { \"age\": { \"type\": \"integer\" } } }] }",
  ]
  let out = StringBuilder()
  for openapi in ["3.1.0", "3.2.0", "3.0.3"] {
    out.write_string("\{openapi}:\n")
    for schema in with_siblings {
      out.write_string(
        "\{schema} => \{referenced_sample(schema, schemas, openapi~)}\n",
      )
    }
  }
  inspect(
    out.to_string(),
    content=(
      #|3.1.0:
      #|{ "$ref": "#/components/schemas/Name", "example": "Max" } => "Max"
      #|{ "$ref": "#/components/schemas/Name", "minLength": 5 } => "Rex"
      #|{ "$ref": "#/components/schemas/Pet", "description": "A pet" } => {"name":"Tom"}
      #|{ "$ref": "#/components/schemas/Pet", "example": { "name": "Kit" } } => {"name":"Kit"}
      #|{ "$ref": "#/components/schemas/Animal", "properties": { "age": { "type": "integer" } } } => {"age":0,"name":"string"}
      #|{ "$ref": "#/components/schemas/Animal", "allOf": [{ "properties": { "id": { "format": "uuid" } } }] } => {"name":"string","id":"00000000-0000-4000-8000-000000000000"}
      #|{ "allOf": [{ "$ref": "#/components/schemas/Pet" }, { "properties": { "age": { "type": "integer" } } }] } => {"name":"string","age":0}
      #|3.2.0:
      #|{ "$ref": "#/components/schemas/Name", "example": "Max" } => "Max"
      #|{ "$ref": "#/components/schemas/Name", "minLength": 5 } => "Rex"
      #|{ "$ref": "#/components/schemas/Pet", "description": "A pet" } => {"name":"Tom"}
      #|{ "$ref": "#/components/schemas/Pet", "example": { "name": "Kit" } } => {"name":"Kit"}
      #|{ "$ref": "#/components/schemas/Animal", "properties": { "age": { "type": "integer" } } } => {"age":0,"name":"string"}
      #|{ "$ref": "#/components/schemas/Animal", "allOf": [{ "properties": { "id": { "format": "uuid" } } }] } => {"name":"string","id":"00000000-0000-4000-8000-000000000000"}
      #|{ "allOf": [{ "$ref": "#/components/schemas/Pet" }, { "properties": { "age": { "type": "integer" } } }] } => {"name":"string","age":0}
      #|3.0.3:
      #|{ "$ref": "#/components/schemas/Name", "example": "Max" } => "Rex"
      #|{ "$ref": "#/components/schemas/Name", "minLength": 5 } => "Rex"
      #|{ "$ref": "#/components/schemas/Pet", "description": "A pet" } => {"name":"Tom"}
      #|{ "$ref": "#/components/schemas/Pet", "example": { "name": "Kit" } } => {"name":"Tom"}
      #|{ "$ref": "#/components/schemas/Animal", "properties": { "age": { "type": "integer" } } } => {"name":"string"}
      #|{ "$ref": "#/components/schemas/Animal", "allOf": [{ "properties": { "id": { "format": "uuid" } } }] } => {"name":"string"}
      #|{ "allOf": [{ "$ref": "#/components/schemas/Pet" }, { "properties": { "age": { "type": "integer" } } }] } => {"name":"string","age":0}
      #|
    ),
  )
}

///|
/// What `referenced_sample` gives for each of `schemas`, each after the
/// schema, in a document whose `components.schemas` are `components`.
fn referenced_samples(
  schemas : Array[String],
  components : String,
  openapi? : String = "3.1.0",
) -> String raise {
  let out = StringBuilder()
  for schema in schemas {
    out.write_string(
      "\{schema} => \{referenced_sample(schema, components, openapi~)}\n",
    )
  }
  out.to_string()
}

///|
test "a schema $ref that cannot be followed is an error at the $ref, as for other references: one that is not a string, that names nothing, whose fragment is not a JSON Pointer, that is a URL or an absolute path, or that names another file" {
  inspect(
    referenced_samples(
      [
        "{ \"$ref\": 7 }", "{ \"type\": \"object\", \"properties\": { \"a\": { \"$ref\": \"#/components/schemas/Missing\" } } }",
        "{ \"items\": { \"$ref\": \"#Pet\" } }", "{ \"allOf\": [{ \"$ref\": \"https://example.com/pet.json\" }] }",
        "{ \"$ref\": \"/schemas/pet.json\" }", "{ \"$ref\": \"pet.json#/Pet\" }",
      ],
      "{}",
    ),
    content=(
      #|{ "$ref": 7 } => petstore.json: /schema/$ref: must be a string
      #|nothing written
      #|{ "type": "object", "properties": { "a": { "$ref": "#/components/schemas/Missing" } } } => petstore.json: /schema/properties/a/$ref: the document has nothing at /components/schemas/Missing
      #|nothing written
      #|{ "items": { "$ref": "#Pet" } } => petstore.json: /schema/items/$ref: the fragment must be a JSON Pointer, such as #/components/responses/Ok: smock does not look up $anchor names
      #|nothing written
      #|{ "allOf": [{ "$ref": "https://example.com/pet.json" }] } => petstore.json: /schema/allOf/0/$ref: smock reads no URLs and no absolute paths: bundle the document into one file first, with another tool
      #|nothing written
      #|{ "$ref": "/schemas/pet.json" } => petstore.json: /schema/$ref: smock reads no URLs and no absolute paths: bundle the document into one file first, with another tool
      #|nothing written
      #|{ "$ref": "pet.json#/Pet" } => petstore.json: /schema/$ref: references to other files are not followed yet: bundle the document into one file first, with another tool
      #|nothing written
      #|
    ),
  )
}

///|
test "a schema reached again through a $ref it is already being generated from is left out as an optional property, gives [] as array items, and null otherwise" {
  let node =
    #|{
    #|  "Node": {
    #|    "type": "object",
    #|    "required": ["name"],
    #|    "properties": {
    #|      "name": { "type": "string" },
    #|      "parent": { "$ref": "#/components/schemas/Node" },
    #|      "children": { "type": "array", "items": { "$ref": "#/components/schemas/Node" } }
    #|    }
    #|  }
    #|}
  for openapi in ["3.0.3", "3.1.0"] {
    inspect(
      referenced_sample(
        "{ \"$ref\": \"#/components/schemas/Node\" }",
        node,
        openapi~,
      ),
      content=(
        #|{"name":"string","children":[]}
      ),
    )
  }
  let schemas =
    #|{
    #|  "Person": {
    #|    "type": "object",
    #|    "required": ["manager", "pair"],
    #|    "properties": {
    #|      "name": { "type": "string" },
    #|      "manager": { "$ref": "#/components/schemas/Boss" },
    #|      "pair": { "type": "array", "prefixItems": [{ "type": "integer" }, { "$ref": "#/components/schemas/Person" }, { "type": "integer" }] },
    #|      "next": { "oneOf": [{ "type": "null" }, { "$ref": "#/components/schemas/Person" }] },
    #|      "pets": { "type": "array", "items": { "$ref": "#/components/schemas/Pet" } }
    #|    }
    #|  },
    #|  "Boss": { "$ref": "#/components/schemas/Person", "description": "Another person" },
    #|  "Pet": {
    #|    "type": "object",
    #|    "required": ["owner"],
    #|    "properties": { "owner": { "allOf": [{ "$ref": "#/components/schemas/Person" }] }, "vet": { "$ref": "#/components/schemas/Vet" } }
    #|  },
    #|  "Vet": { "type": "object", "properties": { "name": { "type": "string" } } }
    #|}
  inspect(
    referenced_sample("{ \"$ref\": \"#/components/schemas/Person\" }", schemas),
    content=(
      #|{"name":"string","manager":null,"pair":[0],"pets":[{"owner":null,"vet":{"name":"string"}}]}
    ),
  )
  // A schema written in place is being generated too.
  inspect(
    referenced_sample(
      "{ \"type\": \"object\", \"properties\": { \"name\": { \"type\": \"string\" }, \"self\": { \"$ref\": \"#/paths/~1r/get/responses/200/content/application~1json/schema\" } } }",
      "{}",
    ),
    content=(
      #|{"name":"string"}
    ),
  )
  // The same schema in two places that do not hold each other is sampled
  // in both.
  inspect(
    referenced_sample(
      "{ \"type\": \"object\", \"properties\": { \"a\": { \"$ref\": \"#/components/schemas/Vet\" }, \"b\": { \"$ref\": \"#/components/schemas/Vet\" } } }",
      schemas,
    ),
    content=(
      #|{"a":{"name":"string"},"b":{"name":"string"}}
    ),
  )
}

///|
test "in 3.1 and 3.2, a writeOnly property beside a $ref is left out without following it; in 3.0, writeOnly beside a $ref is ignored, and the schema it names decides; a $ref in example data is data" {
  let schemas =
    #|{
    #|  "Secret": { "type": "string", "writeOnly": true },
    #|  "Plain": { "type": "string" }
    #|}
  let schemas_of = [
    "{ \"type\": \"object\", \"properties\": { \"pin\": { \"$ref\": \"#/components/schemas/Missing\", \"writeOnly\": true }, \"a\": { \"$ref\": \"#/components/schemas/Secret\" } } }",
    "{ \"type\": \"object\", \"properties\": { \"pin\": { \"$ref\": \"#/components/schemas/Plain\", \"writeOnly\": true } } }",
    "{ \"allOf\": [{ \"$ref\": \"#/components/schemas/Plain\" }], \"example\": { \"$ref\": \"#/x\" } }",
  ]
  inspect(
    referenced_samples(schemas_of, schemas),
    content=(
      #|{ "type": "object", "properties": { "pin": { "$ref": "#/components/schemas/Missing", "writeOnly": true }, "a": { "$ref": "#/components/schemas/Secret" } } } => {}
      #|{ "type": "object", "properties": { "pin": { "$ref": "#/components/schemas/Plain", "writeOnly": true } } } => {}
      #|{ "allOf": [{ "$ref": "#/components/schemas/Plain" }], "example": { "$ref": "#/x" } } => {"$ref":"#/x"}
      #|
    ),
  )
  inspect(
    referenced_samples(schemas_of, schemas, openapi="3.0.3"),
    content=(
      #|{ "type": "object", "properties": { "pin": { "$ref": "#/components/schemas/Missing", "writeOnly": true }, "a": { "$ref": "#/components/schemas/Secret" } } } => petstore.json: /schema/properties/pin/$ref: the document has nothing at /components/schemas/Missing
      #|nothing written
      #|{ "type": "object", "properties": { "pin": { "$ref": "#/components/schemas/Plain", "writeOnly": true } } } => {"pin":"string"}
      #|{ "allOf": [{ "$ref": "#/components/schemas/Plain" }], "example": { "$ref": "#/x" } } => {"$ref":"#/x"}
      #|
    ),
  )
}

///|
test "a $ref met again while merging allOf is skipped, so a cycle of schemas is allowed, unlike a cycle of other Reference Objects" {
  let schemas =
    #|{
    #|  "A": { "allOf": [{ "$ref": "#/components/schemas/B" }, { "properties": { "a": { "type": "string" } } }] },
    #|  "B": { "allOf": [{ "$ref": "#/components/schemas/A" }, { "properties": { "b": { "type": "integer" } } }] },
    #|  "X": { "$ref": "#/components/schemas/Y" },
    #|  "Y": { "$ref": "#/components/schemas/X" },
    #|  "Z": { "$ref": "#/components/schemas/Z", "type": "boolean" },
    #|  "D": { "allOf": [{ "$ref": "#/components/schemas/E" }, { "$ref": "#/components/schemas/E" }] },
    #|  "E": { "type": "object", "properties": { "e": { "format": "date" } } }
    #|}
  let schemas_of = [
    "{ \"$ref\": \"#/components/schemas/A\" }", "{ \"$ref\": \"#/components/schemas/X\" }",
    "{ \"$ref\": \"#/components/schemas/Z\" }", "{ \"$ref\": \"#/components/schemas/D\" }",
  ]
  inspect(
    referenced_samples(schemas_of, schemas),
    content=(
      #|{ "$ref": "#/components/schemas/A" } => {"b":0,"a":"string"}
      #|{ "$ref": "#/components/schemas/X" } => null
      #|{ "$ref": "#/components/schemas/Z" } => true
      #|{ "$ref": "#/components/schemas/D" } => {"e":"2000-01-01"}
      #|
    ),
  )
  inspect(
    referenced_samples(schemas_of, schemas, openapi="3.0.3"),
    content=(
      #|{ "$ref": "#/components/schemas/A" } => {"b":0,"a":"string"}
      #|{ "$ref": "#/components/schemas/X" } => null
      #|{ "$ref": "#/components/schemas/Z" } => null
      #|{ "$ref": "#/components/schemas/D" } => {"e":"2000-01-01"}
      #|
    ),
  )
}

///|
/// How many collections `json` nests, at most, and the first value that
/// sits that deep, as compact JSON: `[[1]]` nests 2, and holds `1` there.
fn deepest(json : Json) -> (Int, String) {
  let mut best = (0, json.stringify())
  match json {
    Array(items) =>
      for item in items {
        let (levels, value) = deepest(item)
        if levels + 1 > best.0 {
          best = (levels + 1, value)
        }
      }
    Object(members) =>
      for _, value in members {
        let (levels, inner) = deepest(value)
        if levels + 1 > best.0 {
          best = (levels + 1, inner)
        }
      }
    _ => ()
  }
  if best.0 == 0 {
    (0, json.stringify())
  } else {
    best
  }
}

///|
test "a sample nests at most 32 levels: an object or an array inside 32 others is null; values copied as data are not cut" {
  // Arrays inside arrays, 40 levels, written in place.
  let mut arrays = "{ \"type\": \"boolean\" }"
  for _ in 0..<40 {
    arrays = "{ \"type\": \"array\", \"items\": \{arrays} }"
  }
  // Objects inside objects, 40 levels, through references.
  let levels = []
  for i in 0..<40 {
    levels.push(
      "\"L\{i}\": { \"type\": \"object\", \"properties\": { \"n\": { \"type\": \"integer\" }, \"next\": { \"$ref\": \"#/components/schemas/L\{i + 1}\" } } }",
    )
  }
  levels.push("\"L40\": { \"type\": \"boolean\" }")
  let schemas = "{ \{levels.join(", ")} }"
  // 31 levels of arrays, then a value of 5 levels.
  let mut data = "{ \"const\": [[[[[1]]]]] }"
  for _ in 0..<31 {
    data = "{ \"type\": \"array\", \"items\": \{data} }"
  }
  let out = []
  for schema in [arrays, "{ \"$ref\": \"#/components/schemas/L0\" }", data] {
    let sample = referenced_sample(schema, schemas)
    let json = @json.parse(sample) catch { _ => fail(sample) }
    let (levels, value) = deepest(json)
    out.push("\{levels} levels, with \{value} there")
  }
  inspect(
    out.join("\n"),
    content=(
      #|32 levels, with null there
      #|32 levels, with 0 there
      #|36 levels, with 1 there
    ),
  )
}

///|
test "$id inside the document is an error when a $ref lies under it, since it would change what that $ref names; without one, it is ignored" {
  let schemas =
    #|{
    #|  "Tag": { "type": "string" },
    #|  "Pet": { "$id": "https://example.com/pet", "type": "object", "properties": { "tag": { "$ref": "#/components/schemas/Tag" } } },
    #|  "Plain": { "$id": "plain.json", "type": "object", "properties": { "name": { "type": "string" } }, "example": { "$ref": "#/x" } }
    #|}
  let schemas_of = [
    "{ \"$ref\": \"#/components/schemas/Pet\" }", "{ \"$id\": \"https://example.com/r\", \"type\": \"array\", \"items\": { \"$ref\": \"#/components/schemas/Tag\" } }",
    "{ \"$id\": \"r\", \"$ref\": \"#/components/schemas/Tag\" }", "{ \"$id\": \"r\", \"type\": \"object\", \"properties\": { \"a\": { \"$id\": \"a\", \"items\": { \"$ref\": \"#/components/schemas/Tag\" } } } }",
    "{ \"$ref\": \"#/components/schemas/Plain\" }", "{ \"type\": \"object\", \"properties\": { \"$id\": { \"$ref\": \"#/components/schemas/Tag\" }, \"tag\": { \"$ref\": \"#/components/schemas/Tag\" } } }",
  ]
  inspect(
    referenced_samples(schemas_of, schemas),
    content=(
      #|{ "$ref": "#/components/schemas/Pet" } => petstore.json: /components/schemas/Pet/$id: a $ref lies under this $id, which would change what the $ref names: smock does not resolve $id
      #|nothing written
      #|{ "$id": "https://example.com/r", "type": "array", "items": { "$ref": "#/components/schemas/Tag" } } => petstore.json: /schema/$id: a $ref lies under this $id, which would change what the $ref names: smock does not resolve $id
      #|nothing written
      #|{ "$id": "r", "$ref": "#/components/schemas/Tag" } => petstore.json: /schema/$id: a $ref lies under this $id, which would change what the $ref names: smock does not resolve $id
      #|nothing written
      #|{ "$id": "r", "type": "object", "properties": { "a": { "$id": "a", "items": { "$ref": "#/components/schemas/Tag" } } } } => petstore.json: /schema/$id: a $ref lies under this $id, which would change what the $ref names: smock does not resolve $id
      #|petstore.json: /schema/properties/a/$id: a $ref lies under this $id, which would change what the $ref names: smock does not resolve $id
      #|nothing written
      #|{ "$ref": "#/components/schemas/Plain" } => {"$ref":"#/x"}
      #|{ "type": "object", "properties": { "$id": { "$ref": "#/components/schemas/Tag" }, "tag": { "$ref": "#/components/schemas/Tag" } } } => {"$id":"string","tag":"string"}
      #|
    ),
  )
  // In 3.0, the fields beside a $ref are ignored, $id among them.
  inspect(
    referenced_samples(
      ["{ \"$id\": \"r\", \"$ref\": \"#/components/schemas/Tag\" }"],
      schemas,
      openapi="3.0.3",
    ),
    content=(
      #|{ "$id": "r", "$ref": "#/components/schemas/Tag" } => "string"
      #|
    ),
  )
}

///|
test "$dynamicRef is an error; $id at the root of the document, $schema and jsonSchemaDialect are ignored" {
  inspect(
    referenced_samples(
      [
        "{ \"type\": \"object\", \"properties\": { \"a\": { \"$dynamicRef\": \"#node\" } } }",
        "{ \"$dynamicRef\": \"#node\", \"$ref\": \"#/components/schemas/Tag\" }",
      ],
      "{ \"Tag\": { \"type\": \"string\" } }",
    ),
    content=(
      #|{ "type": "object", "properties": { "a": { "$dynamicRef": "#node" } } } => petstore.json: /schema/properties/a/$dynamicRef: smock does not follow $dynamicRef: write a $ref with a JSON Pointer, such as #/components/schemas/Pet
      #|nothing written
      #|{ "$dynamicRef": "#node", "$ref": "#/components/schemas/Tag" } => petstore.json: /schema/$dynamicRef: smock does not follow $dynamicRef: write a $ref with a JSON Pointer, such as #/components/schemas/Pet
      #|nothing written
      #|
    ),
  )
  inspect(
    referenced_samples(
      ["{ \"$dynamicRef\": \"#node\", \"$ref\": \"#/components/schemas/Tag\" }"],
      "{ \"Tag\": { \"type\": \"string\" } }",
      openapi="3.0.3",
    ),
    content=(
      #|{ "$dynamicRef": "#node", "$ref": "#/components/schemas/Tag" } => "string"
      #|
    ),
  )
  inspect(
    body_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "$id": "https://example.com/openapi.json",
        #|  "jsonSchemaDialect": "https://spec.openapis.org/oas/3.1/dialect/base",
        #|  "paths": { "/r": { "get": { "responses": { "200": { "content": { "application/json": {
        #|    "schema": { "$schema": "https://json-schema.org/draft/2020-12/schema", "$ref": "#/components/schemas/Pet" }
        #|  } } } } } } },
        #|  "components": {
        #|    "schemas": { "Pet": { "$schema": 7, "type": "object", "properties": { "tag": { "$ref": "#/components/schemas/Tag" } } }, "Tag": { "type": "string" } }
        #|  }
        #|}
      ),
    ),
    content=(
      #|{"tag":"string"}
    ),
  )
}
