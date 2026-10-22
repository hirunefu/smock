// The checks of the file before it is written. Converting a document
// cannot pass the bound without a document of many megabytes, and cannot
// fail the self-check unless smock has a bug, so these tests give the
// checks a file of their own.

///|
/// An OpenAPI 3.1 document with nothing in it, for the checks of the file,
/// which do not read it.
fn no_document() -> Document {
  { top: {}, openapi: "3.1.0", title: "", info_version: "", prefix: "", }
}

///|
/// The problems that checking `text` as the file gives, with the bound
/// `max_bytes`, one per line, then whether it passed.
fn checked(
  text : String,
  max_bytes? : Int = max_file_bytes,
  output? : String = "defs/m.json",
  declare_mock? : Bool = true,
) -> String {
  let conversion = in_memory(
    Options(root="api.json", mock="m", output~, declare_mock~),
    no_document(),
  )
  let passed = conversion.checked(@utf8.encode(text), max_bytes~)
  let lines = conversion.report.problems().map(problem => problem.to_string())
  lines.push("passed: \{passed}")
  lines.join("\n")
}

///|
test "a file above the bound is an error with the file that gives its size" {
  inspect(
    checked("{ \"version\": 1 }\n", max_bytes=16),
    content=(
      #|defs/m.json: the file would be 17 bytes, more than 16 bytes
      #|passed: false
    ),
  )
  inspect(checked("{ \"version\": 1 }\n", max_bytes=17), content="passed: true")
  inspect(size_text(max_file_bytes), content="64 MiB")
}

///|
test "messages write counts in groups of three digits" {
  inspect(
    [0, 7, 999, max_documents, 12345, 1234567].map(count_text).join(" "),
    content=(
      #|0 7 999 1,000 12,345 1,234,567
    ),
  )
}

///|
test "a file that would not load, or would give a warning, is an error with the file, with no pointer, that calls it a smock bug and names where the problem is" {
  inspect(
    checked(
      (
        #|{ "version": 1, "stubs": [{ "id": "a", "mock": "m", "response": { "status": 99 } }] }
      ),
    ),
    content=(
      #|defs/m.json: smock bug: the file would not load: defs/m.json: /stubs/0/response/status: must be an integer from 200 to 599
      #|defs/m.json: smock bug: the file would not load: defs/m.json: /stubs/0/mock: no file declares the Mock "m"
      #|passed: false
    ),
  )
  inspect(
    checked(
      (
        #|{ "version": 1, "mocks": [{ "name": "m" }], "stubs": [
        #|  { "id": "a", "mock": "m", "request": { "path": "/a" }, "response": { "status": 200 } },
        #|  { "id": "b", "mock": "m", "request": { "path": "/a" }, "response": { "status": 200 } } ] }
      ),
    ),
    content=(
      #|defs/m.json: smock bug: the file would give the warning: defs/m.json: /stubs/1: warning: the Stub "b" can never match: the Stub "a" at defs/m.json: /stubs/0 is tried first and matches every request this one would
      #|passed: false
    ),
  )
}

///|
test "problems with the file come before the document's" {
  let conversion = in_memory(
    Options(root="api.json", mock="m", output="defs/m.json"),
    no_document(),
  )
  let report = conversion.report
  report.warning_at(Place::root("/webhooks"), "webhooks are not imported")
  report.end_document()
  report.error_at(
    Place::root("/paths/~1a/get/operationId"),
    "must be a non-empty string",
  )
  let _ = conversion.checked(b"{ \"version\": 1 }\n", max_bytes=16)
  report.late_document_warning(
    Place::root("/paths"),
    "there is no operation to import",
  )
  inspect(
    report.problems().map(problem => problem.to_string()).join("\n"),
    content=(
      #|defs/m.json: the file would be 17 bytes, more than 16 bytes
      #|api.json: /webhooks: warning: webhooks are not imported
      #|api.json: /paths: warning: there is no operation to import
      #|api.json: /paths/~1a/get/operationId: must be a non-empty string
    ),
  )
}

///|
test "a file the YAML writer cannot write is an error with the file, with no pointer, that calls it a smock bug" {
  let conversion = in_memory(
    Options(root="api.json", mock="m", output="defs/m.yaml"),
    no_document(),
  )
  let file : Json = {
    "version": 1,
    "stubs": [{ "id": Json::number(0.0 / 0.0) }],
  }
  assert_true(conversion.yaml_file(file, []) is None)
  inspect(
    conversion.report.problems().map(problem => problem.to_string()).join("\n"),
    content=(
      #|defs/m.yaml: smock bug: the file cannot be written as YAML at /stubs/0/id: a number must be finite, or keep the text it was read from
    ),
  )
}

///|
test "a YAML file is checked as YAML, by its name" {
  inspect(
    checked(
      (
        #|# A comment.
        #|version: 1
        #|mocks:
        #|  - name: m
        #|stubs:
        #|  - id: a
        #|    mock: m
        #|    response:
        #|      status: "200"
      ),
      output="defs/m.yaml",
    ),
    content=(
      #|defs/m.yaml: smock bug: the file would not load: defs/m.yaml: /stubs/0/response/status: must be an integer from 200 to 599
      #|passed: false
    ),
  )
}

///|
test "a file that does not declare its Mock is checked with a stand-in that declares it, so its Stubs load, and a file that declares it all the same fails; a problem in the stand-in names the stand-in" {
  let stubs =
    #|"stubs": [{ "id": "a", "mock": "m", "response": { "status": 200 } }]
  inspect(
    checked("{ \"version\": 1, \{stubs} }", declare_mock=false),
    content="passed: true",
  )
  inspect(
    checked(
      "{ \"version\": 1, \"mocks\": [{ \"name\": \"m\" }], \{stubs} }",
      declare_mock=false,
    ),
    content=(
      #|defs/m.json: smock bug: the file would not load: defs/m.json.mock.json: /mocks/0/name: the Mock name "m" is already declared at defs/m.json: /mocks/0/name
      #|passed: false
    ),
  )
}
