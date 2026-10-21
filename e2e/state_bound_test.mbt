// Seam 2 tests of the bound on per-Session state: what --state-max-bytes or
// SMOCK_STATE_MAX_BYTES sets, or else an eighth of the memory limit of
// smock's cgroup, logged at startup; the 507 of a request whose writes
// would pass it; and its two metrics.

///|
/// The log entry with the message `msg`, without its time.
fn startup_entry(logs : Array[String], msg : String) -> String {
  for line in logs {
    let entry = @json.parse(line) catch { _ => continue }
    guard entry is Object(fields) &&
      fields.get("msg") is Some(String(m)) &&
      m == msg else {
      continue
    }
    fields.remove("time")
    return Json::object(fields).stringify()
  }
  "no \{msg} entry in:\n\{logs.join("\n")}"
}

///|
async test "state byte bound: an eighth of the memory limit of smock's cgroup, read once with the Journal's, unless the flag or the variable sets it" {
  if scope_unavailable() is Some(reason) {
    println(
      "skipped \"state byte bound\" (e2e/state_bound_test.mbt): it runs smock in a systemd user scope with a memory limit, but \{reason}",
    )
    return
  }
  let cases : Array[(Array[String], Map[String, String])] = [
    ([], {}),
    (["--state-max-bytes", "1048576"], {}),
    ([], { "SMOCK_STATE_MAX_BYTES": "2000000" }),
  ]
  let out = []
  for case in cases {
    let (args, env) = case
    let stopped = with_smock(
      ["--port", "0", ..args],
      env=user_manager_env(env),
      under=in_scope,
      _ => (),
    )
    out.push(startup_entry(stopped.logs, "journal byte bound"))
    out.push(startup_entry(stopped.logs, "state byte bound"))
  }
  inspect(
    out.join("\n"),
    content=(
      #|{"level":"info","msg":"journal byte bound","maxBytes":13631488,"source":"memoryLimit","memoryLimit":54525952}
      #|{"level":"info","msg":"state byte bound","maxBytes":6815744,"source":"memoryLimit","memoryLimit":54525952}
      #|{"level":"info","msg":"journal byte bound","maxBytes":13631488,"source":"memoryLimit","memoryLimit":54525952}
      #|{"level":"info","msg":"state byte bound","maxBytes":1048576,"source":"flag"}
      #|{"level":"info","msg":"journal byte bound","maxBytes":13631488,"source":"memoryLimit","memoryLimit":54525952}
      #|{"level":"info","msg":"state byte bound","maxBytes":2000000,"source":"variable"}
    ),
  )
}

///|
/// Ticket #89's example: `POST /cart/items` stores the request's body in
/// `last`.
let cart_items : String =
  #|mocks:
  #|  - name: shop
  #|stubs:
  #|  - id: add-cart-item
  #|    mock: shop
  #|    request: { method: POST, path: /cart/items }
  #|    variables:
  #|      last: ${body}
  #|    response: { status: 201 }

///|
async test "--state-max-bytes: a request whose writes would pass the bound gets 507 and writes nothing, and the metrics show the bytes counted and the refusal" {
  with_definitions([("shop.yaml", cart_items)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--state-max-bytes", "200"],
      smock => {
        let headers = [baggage("run-42"), ("Content-Type", "application/json")]
        // shop and run-42 count 4 + 6 + 64; last counts 4 + 64, and
        // {"sku":"a1"}, 12 bytes and two JSON values: 186 in all.
        let fits = smock.send(
          "POST",
          "/cart/items",
          headers~,
          body="{\"sku\": \"a1\"}",
        )
        // {"sku":"a1","qty":2} counts 20 bytes and three JSON values.
        let refused = smock.send(
          "POST",
          "/cart/items",
          headers~,
          body="{\"sku\": \"a1\", \"qty\": 2}",
        )
        inspect(
          [fits, refused].join("\n---\n"),
          content=(
            #|HTTP/1.1 201 Created
            #|Smock-Mock: shop; via=default
            #|Content-Length: 0
            #|
            #|
            #|---
            #|HTTP/1.1 507 
            #|Content-Type: application/json
            #|Smock-Mock: shop; via=default
            #|Content-Length: 172
            #|
            #|{"error":"state limit reached","stub":"add-cart-item","message":"the writes would take per-Session state from 186 to 210 bytes, above its bound of 200 (--state-max-bytes)"}
          ),
        )
        let text = smock.admin("GET", "/metrics").body
        inspect(
          metric_lines(text, "smock_state_", help=true).join("\n"),
          content=(
            #|# HELP smock_state_bytes Bytes the per-Session state takes, as the bound on it counts them (--state-max-bytes).
            #|# TYPE smock_state_bytes gauge
            #|smock_state_bytes 186
            #|# HELP smock_state_writes_refused_total Requests whose writes to per-Session state were refused with 507, since they would pass its bound (--state-max-bytes).
            #|# TYPE smock_state_writes_refused_total counter
            #|smock_state_writes_refused_total 1
          ),
        )
      },
    )
    inspect(
      startup_entry(stopped.logs, "state byte bound"),
      content=(
        #|{"level":"info","msg":"state byte bound","maxBytes":200,"source":"flag"}
      ),
    )
  })
}
