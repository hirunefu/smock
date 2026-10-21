// Seam 2 tests of how resets and reloads treat copies of Data buckets: a
// reset over the Admin API drops the copies in its scope and counts them in
// its reply and its log entry, and a reload by editing the files drops only
// the copies of a bucket that changed, and logs how many. Every Admin API
// response is checked against the OpenAPI document (contract_test.mbt).

///|
async test "over the Admin API, each reset scope drops the copies in it, counts them in its reply and its log entry, and gives their bytes back" {
  with_definitions(shop_orders, dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let step = (label : String, result : String) => {
        out.push("\{label}: \{result}")
      }
      let set = (session : String?, bucket : String, value : String) => {
        let set = smock.call(
          "PUT",
          "/v1/mocks/shop/data/\{bucket}",
          session?,
          body=value,
        )
        guard set.has_prefix("200 ") else { fail(set) }
      }
      let reset = (session : String?, body : String) => {
        smock.call("POST", "/v1/reset", session?, body~)
      }
      let state_bytes = () => {
        let text = smock.admin("GET", "/metrics").body
        metric_lines(text, "smock_state_bytes").join(", ")
      }
      set(Some("checkout-42"), "orders", "[{\"id\":1,\"status\":\"paid\"}]")
      step(
        "checkout-42 GET /api/v1/orders",
        smock.order("GET", "/api/v1/orders", session="checkout-42"),
      )
      step(
        "reset checkout-42",
        reset(Some("checkout-42"), "{\"scope\":\"session\"}"),
      )
      step(
        "checkout-42 GET /api/v1/orders",
        smock.order("GET", "/api/v1/orders", session="checkout-42"),
      )
      set(Some("checkout-42"), "visits", "1")
      set(Some("checkout-43"), "visits", "2")
      set(None, "orders", "[]")
      step("reset shop", reset(None, "{\"scope\":\"mock\",\"mock\":\"shop\"}"))
      step(
        "no Session GET /api/v1/orders",
        smock.order("GET", "/api/v1/orders"),
      )
      set(Some("checkout-43"), "visits", "3")
      step("reset all", reset(Some("checkout-43"), "{\"scope\":\"all\"}"))
      step("metrics", state_bytes())
      inspect(
        out.join("\n"),
        content=(
          #|checkout-42 GET /api/v1/orders: 200 [{"id":1,"status":"paid"}]
          #|reset checkout-42: 200 {"scope":"session","removed":{"ephemeralStubs":0,"journalEntries":1,"scenarioStates":0,"variables":0,"dataBuckets":1},"warnings":[]}
          #|checkout-42 GET /api/v1/orders: 200 [{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]
          #|reset shop: 200 {"scope":"mock","removed":{"ephemeralStubs":0,"journalEntries":1,"scenarioStates":0,"variables":0,"dataBuckets":3},"warnings":[]}
          #|no Session GET /api/v1/orders: 200 [{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]
          #|reset all: 200 {"scope":"all","removed":{"ephemeralStubs":0,"journalEntries":1,"scenarioStates":0,"variables":0,"dataBuckets":1},"warnings":[]}
          #|metrics: smock_state_bytes 0
        ),
      )
    })
    inspect(
      log_entries(
        stopped.logs.filter(line => line.contains("\"msg\":\"reset\"")),
      ),
      content=(
        #|{"level":"info","msg":"reset","scope":"session","session":"checkout-42","removed":{"ephemeralStubs":0,"journalEntries":1,"scenarioStates":0,"variables":0,"dataBuckets":1}}
        #|{"level":"info","msg":"reset","scope":"mock","mock":"shop","removed":{"ephemeralStubs":0,"journalEntries":1,"scenarioStates":0,"variables":0,"dataBuckets":3}}
        #|{"level":"info","msg":"reset","scope":"all","removed":{"ephemeralStubs":0,"journalEntries":1,"scenarioStates":0,"variables":0,"dataBuckets":1}}
      ),
    )
  })
}

///|
async test "a reload by editing the files keeps the copy of a bucket that did not change, drops the copy of a bucket whose file changed, and logs how many it dropped" {
  with_definitions(shop_orders, dir => {
    let mut digests = []
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let step = (label : String, result : String) => {
        out.push("\{label}: \{result}")
      }
      let set = smock.call(
        "PUT",
        "/v1/mocks/shop/data/orders",
        session="checkout-42",
        body="[{\"id\":1,\"status\":\"paid\"}]",
      )
      guard set.has_prefix("200 ") else { fail(set) }
      let orders = (session : String) => {
        smock.order("GET", "/api/v1/orders", session~)
      }
      let first = smock.status()
      // An unrelated Stub is added.
      write(
        dir,
        "shop.yaml",
        shop_orders[0].1 +
        (
          #|
          #|  - id: health
          #|    mock: shop
          #|    request: { method: GET, path: /health }
          #|    response: { status: 204 }
        ),
      )
      let second = smock.reloaded(first)
      step("reload, a Stub added", last_reload(second))
      step("checkout-42 GET /api/v1/orders", orders("checkout-42"))
      // Order 3 ships.
      write(
        dir,
        "files/orders.json",
        shop_orders[1].1.replace(
          old="{ \"id\": 3, \"status\": \"paid\" }",
          new="{ \"id\": 3, \"status\": \"shipped\" }",
        ),
      )
      let third = smock.reloaded(second)
      step("reload, orders.json edited", last_reload(third))
      step("checkout-42 GET /api/v1/orders", orders("checkout-42"))
      step(
        "checkout-42 reads orders",
        smock.call("GET", "/v1/mocks/shop/data/orders", session="checkout-42"),
      )
      digests = [
        ("<first>", first.get("digest")),
        ("<second>", second.get("digest")),
        ("<third>", third.get("digest")),
      ]
      inspect(
        out.join("\n"),
        content=(
          #|reload, a Stub added: "swapped"
          #|checkout-42 GET /api/v1/orders: 200 [{"id":1,"status":"paid"}]
          #|reload, orders.json edited: "swapped"
          #|checkout-42 GET /api/v1/orders: 200 [{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"shipped"}]
          #|checkout-42 reads orders: 200 {"bucket":{"name":"orders","key":"id","newKey":"integer","written":false,"value":[{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"shipped"}]},"warnings":[]}
        ),
      )
    })
    inspect(
      reload_entries(stopped.logs, digests),
      content=(
        #|{"level":"info","msg":"definitions reloaded","result":"swapped","oldDigest":"<first>","newDigest":"<second>","scenarioStatesReset":0,"dataBucketsReset":0}
        #|{"level":"info","msg":"definitions reloaded","result":"swapped","oldDigest":"<second>","newDigest":"<third>","scenarioStatesReset":0,"dataBucketsReset":1}
      ),
    )
  })
}
