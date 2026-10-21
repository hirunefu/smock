// The nesting bound of bodies. The parsers read at most 1024 levels, and a
// body sits deeper in a document than in the file, so no document read from
// bytes passes the bound until samples nest through references. These tests
// give the converter a document built in memory instead.

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
  let report = Report::new(Options(root="api.json", mock="m", output~))
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
  let document = { top, openapi: "3.1.0", title: "", info_version: "", }
  let conversion = report.file(document, report.operations(document))
  let lines = conversion.problems().map(problem => problem.to_string())
  match conversion {
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
    Failed(_) => lines.push("nothing written")
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
