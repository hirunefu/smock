// The nesting bound of example bodies. An example sits at least as deep in
// a document as its body does in the file, so no document read from bytes
// passes the bound. These tests give the converter a document built in
// memory instead, as for samples.

///|
/// Converts a document whose only operation is `GET /r`, whose `200`
/// response has the `application/json` Media Type Object `media_type`, and
/// renders the problems, one per line, then each Stub's ID and whether it
/// has a body.
fn deep_example(media_type : Json) -> String {
  let report = Report::new(Options(root="api.json", mock="m", output="m.yaml"))
  let top : Map[String, Json] = {
    "openapi": "3.2.0",
    "paths": {
      "/r": {
        "get": {
          "operationId": "r",
          "responses": {
            "200": { "content": { "application/json": media_type } },
          },
        },
      },
    },
  }
  let document = {
    top,
    openapi: "3.2.0",
    title: "",
    info_version: "",
    prefix: "",
  }
  let conversion = report.file(document, report.operations(document))
  let lines = conversion.problems().map(problem => problem.to_string())
  match conversion {
    // The converter wrote the file only after loading it.
    Converted(file~, ..) => {
      let json = @yaml.parse(@utf8.decode_lossy(file)) catch {
        _ => Json::null()
      }
      match json {
        Object({ "stubs": Array(stubs), .. }) =>
          for stub in stubs {
            guard stub
              is Object({ "id": String(id), "response": Object(response), .. }) else {
              lines.push("unexpected Stub")
              continue
            }
            let body = if response.contains("json") {
              "a body"
            } else {
              "no body"
            }
            lines.push("\{id}: \{body}")
          }
        _ => lines.push("written, but not read back")
      }
    }
    Failed(_) | Needs(_) => lines.push("nothing written")
  }
  lines.join("\n")
}

///|
test "an example value nested so deep that the file would pass the parsers' limit of 1024 levels is left out of its body, with a warning" {
  inspect(
    deep_example({
      "examples": {
        "fits": { "value": nested(max_nesting - 4) },
        "deep": { "dataValue": nested(max_nesting - 3) },
      },
    }),
    content=(
      #|api.json: /paths/~1r/get/responses/200/content/application~1json/examples/deep/dataValue: warning: left out: the value would nest deeper than 1024 levels in the file, the most the parsers read
      #|m.r.200.deep: no body
      #|m.r.200: a body
    ),
  )
  inspect(
    deep_example({ "example": nested(max_nesting - 3) }),
    content=(
      #|api.json: /paths/~1r/get/responses/200/content/application~1json/example: warning: left out: the value would nest deeper than 1024 levels in the file, the most the parsers read
      #|m.r.200: no body
    ),
  )
}
