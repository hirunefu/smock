// The checks of the file before it is written. Converting a document
// cannot pass the bound without a document of many megabytes, and cannot
// fail the self-check unless smock has a bug, so these tests give the
// checks a file of their own.

///|
/// The problems that checking `text` as the file gives, with the bound
/// `max_bytes`, one per line, then whether it passed.
fn checked(text : String, max_bytes? : Int = max_file_bytes) -> String {
  let report = Report::new(
    Options(root="api.json", mock="m", output="defs/m.json"),
  )
  let passed = report.checked(@utf8.encode(text), max_bytes~)
  let lines = report.problems().map(problem => problem.to_string())
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
test "a file that would not load, or would give a warning, is an error with the file that calls it a smock bug" {
  inspect(
    checked(
      (
        #|{ "version": 1, "stubs": [{ "id": "a", "mock": "m", "response": { "status": 99 } }] }
      ),
    ),
    content=(
      #|defs/m.json: /stubs/0/response/status: smock bug: the file would not load: must be an integer from 200 to 599
      #|defs/m.json: /stubs/0/mock: smock bug: the file would not load: no file declares the Mock "m"
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
      #|defs/m.json: /stubs/1: smock bug: the file would give the warning: the Stub "b" can never match: the Stub "a" at defs/m.json: /stubs/0 is tried first and matches every request this one would
      #|passed: false
    ),
  )
}

///|
test "problems with the file come before the document's" {
  let report = Report::new(
    Options(root="api.json", mock="m", output="defs/m.json"),
  )
  report.root_warning("/webhooks", "webhooks are not imported")
  report.end_document()
  report.root_error("/paths/~1a/get/operationId", "must be a non-empty string")
  let _ = report.checked(b"{ \"version\": 1 }\n", max_bytes=16)
  report.late_document_warning("/paths", "there is no operation to import")
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
