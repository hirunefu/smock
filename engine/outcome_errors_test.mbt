// Seam 1 tests of the errors an outcome carries: the template error or the
// data error of a request whose Stub's own content failed, with the Stub's
// path as written, whether or not the Journal records the request.

///|
/// The Mock `mock`, at the Host `<mock>.test`, with the Journal on or off
/// for it as `journal` says, and a Stub for each way a request's content
/// can fail, or not: a response template that fails, at an exact path, at
/// a path pattern and with no path condition; a Variable's value that
/// fails; a data write that cannot be applied; a write that passes the
/// state bound; and a CRUD Stub, whose answers are not templates. Each
/// Stub's ID starts with the Mock's name.
fn content_failures(mock : String, journal~ : Bool) -> (String, String) {
  (
    "\{mock}.yaml",
    (
      $|mocks:
      $|  - { name: \{mock}, hosts: [\{mock}.test], journal: \{journal} }
      $|data:
      $|  - { mock: \{mock}, name: visits, json: 0 }
      $|  - { mock: \{mock}, name: items, key: id, json: [] }
      $|stubs:
      $|  - id: \{mock}-order
      $|    mock: \{mock}
      $|    request: { method: POST, path: /orders }
      $|    response: { status: 201, template: true, json: { name: "${body.customer.name}" } }
      $|  - id: \{mock}-order-page
      $|    mock: \{mock}
      $|    request: { method: GET, path: { pattern: "/orders/[0-9]+" } }
      $|    response: { status: 200, template: true, json: { page: "${query.page}" } }
      $|  - id: \{mock}-anything
      $|    mock: \{mock}
      $|    request: { method: DELETE }
      $|    response: { status: 204, template: true, headers: { X-Reason: "${query.reason}" } }
      $|  - id: \{mock}-count
      $|    mock: \{mock}
      $|    request: { method: POST, path: /count }
      $|    variables: { count: "${body.count}" }
      $|    response: { status: 204 }
      $|  - id: \{mock}-visit
      $|    mock: \{mock}
      $|    request: { method: POST, path: /visits }
      $|    dataWrites: [{ op: merge, bucket: visits, value: { last: now } }]
      $|    response: { status: 204 }
      $|  - id: \{mock}-big
      $|    mock: \{mock}
      $|    request: { method: POST, path: /big }
      $|    variables: { big: "${body}" }
      $|    response: { status: 204 }
      $|  - id: \{mock}-items
      $|    mock: \{mock}
      $|    crud: { bucket: items, path: /items }
    ),
  )
}

///|
/// An Ephemeral Stub whose response template fails for `GET /ephemeral`,
/// which these tests add for the Session `s`.
let failing_ephemeral : String =
  #|{ "request": { "method": "GET", "path": "/ephemeral" },
  #|  "response": { "status": 200, "template": true, "json": { "id": "${query.id}" } } }

///|
/// The requests of these tests, as (method, target, body).
let failing_requests : Array[(String, String, String)] = [
  ("POST", "/orders", "{\"customer\":{}}"),
  ("GET", "/orders/7", ""),
  ("DELETE", "/anything", ""),
  ("POST", "/count", "{}"),
  ("POST", "/visits", ""),
  ("GET", "/ephemeral", ""),
  ("POST", "/big", "\"\{"x".repeat(300)}\""),
  ("GET", "/items/nope", ""),
  ("POST", "/items", "[]"),
  ("GET", "/nope", ""),
]

///|
/// What each of `failing_requests` to the Mock `mock` carries in its
/// outcome, one per line: the status, the error, the Stub's path, and
/// whether the Journal entry holds the same error.
fn Harness::failures(self : Harness, mock : String) -> Array[String] raise {
  self.add(mock, Some("s"), failing_ephemeral) |> ignore
  let out = []
  for request in failing_requests {
    let (meth, target, body) = request
    let outcome = self.send(
      meth,
      target,
      headers=[("Host", "\{mock}.test")],
      body~,
      session="s",
    )
    let error = match (outcome.template_error, outcome.data_error) {
      (Some(error), None) => "template error at \{error.at}: \{error.message}"
      (None, Some(error)) => "data error at \{error.at}: \{error.message}"
      (None, None) => "no error"
      (Some(_), Some(_)) => "both errors"
    }
    let journal = match outcome.journal {
      Some(entry) =>
        if entry.template_error == outcome.template_error &&
          entry.data_error == outcome.data_error {
          "the entry's"
        } else {
          "not the entry's"
        }
      None => "no entry"
    }
    out.push(
      "\{meth} \{target}: \{outcome.plan.status}, \{error}, path \{@debug.to_string(outcome.failed_stub_path)}; \{journal}",
    )
  }
  out
}

///|
test "an outcome carries its template error or its data error, with the Stub's path as written, as the Journal entry does, also with the Journal off globally or for the Mock" {
  let files = [
    content_failures("shop", journal=true),
    content_failures("quiet", journal=false),
  ]
  let on = harness(files, state_max_bytes=256)
  let off = harness(
    files,
    journal=@engine.JournalSettings(enabled=false),
    state_max_bytes=256,
  )
  let recorded = on.failures("shop")
  let unrecorded = recorded.map(line => {
    line.replace(old="; the entry's", new="; no entry")
  })
  let quiet = on.failures("quiet")
  let global = off.failures("shop")
  inspect(
    (
      $|\{recorded.join("\n")}
      $|the same for a Mock whose journal is false, with no entry: \{quiet == unrecorded}
      $|the same with the Journal off globally, with no entry: \{global == unrecorded}
    ),
    content=(
      #|POST /orders: 500, template error at /response/json/name: body.customer.name is missing, path Some("/orders"); the entry's
      #|GET /orders/7: 500, template error at /response/json/page: query.page is missing, path Some("/orders/[0-9]+"); the entry's
      #|DELETE /anything: 500, template error at /response/headers/X-Reason: query.reason is missing, path None; the entry's
      #|POST /count: 500, template error at /variables/count: body.count is missing, path Some("/count"); the entry's
      #|POST /visits: 500, data error at /dataWrites/0: the Data bucket "visits" holds a number, and "merge" needs an object, path Some("/visits"); the entry's
      #|GET /ephemeral: 500, template error at /response/json/id: query.id is missing, path Some("/ephemeral"); the entry's
      #|POST /big: 507, no error, path None; the entry's
      #|GET /items/nope: 404, no error, path None; the entry's
      #|POST /items: 400, no error, path None; the entry's
      #|GET /nope: 404, no error, path None; the entry's
      #|the same for a Mock whose journal is false, with no entry: true
      #|the same with the Journal off globally, with no entry: true
    ),
  )
}
