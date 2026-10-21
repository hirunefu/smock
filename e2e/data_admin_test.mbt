// Seam 2 tests of the Admin API operations on Data buckets: listing a
// Mock's buckets, and reading, setting and dropping the calling Session's
// copy of one, over the authenticated Admin API, within the bound on
// per-Session state. Every Admin API response is checked against the
// OpenAPI document (contract_test.mbt).

///|
/// The ticket's example: the Mock `shop` with the bucket `orders`, keyed by
/// `id`, from `files/orders.json`, which holds three orders, and `visits`,
/// without `key`; `GET /api/v1/orders` answers `orders`.
let shop_orders : Array[(String, String)] = [
  (
    "shop.yaml",
    (
      #|mocks:
      #|  - name: shop
      #|data:
      #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
      #|  - { mock: shop, name: visits, json: 0 }
      #|stubs:
      #|  - id: list-orders
      #|    mock: shop
      #|    request: { method: GET, path: /api/v1/orders }
      #|    response: { status: 200, template: true, json: "${data.orders}" }
    ),
  ),
  (
    "files/orders.json",
    (
      #|[{ "id": 1, "status": "paid" }, { "id": 2, "status": "pending" },
      #| { "id": 3, "status": "paid" }]
    ),
  ),
]

///|
async test "over the authenticated Admin API, a test sets its Session's copy of a bucket, which its requests read, lists and reads the buckets, and drops the copy" {
  with_definitions(shop_orders, dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let step = (label : String, result : String) => {
        out.push("\{label}: \{result}")
      }
      let data = "/v1/mocks/shop/data"
      let orders = "\{data}/orders"
      step(
        "list without a token",
        smock.admin("GET", data, token=None).status.to_string(),
      )
      step(
        "read without a token",
        smock.admin("GET", orders, token=None).status.to_string(),
      )
      step(
        "set without a token",
        smock.admin("PUT", orders, token=None, body="[]").status.to_string(),
      )
      step(
        "drop without a token",
        smock.admin("DELETE", orders, token=None).status.to_string(),
      )
      step(
        "checkout-42 sets orders",
        smock.call(
          "PUT",
          orders,
          session="checkout-42",
          body="[{\"id\":1,\"status\":\"paid\"}]",
        ),
      )
      step(
        "checkout-42 GET /api/v1/orders",
        smock.order("GET", "/api/v1/orders", session="checkout-42"),
      )
      step(
        "checkout-43 GET /api/v1/orders",
        smock.order("GET", "/api/v1/orders", session="checkout-43"),
      )
      step("checkout-42 lists", smock.call("GET", data, session="checkout-42"))
      step("checkout-43 lists", smock.call("GET", data, session="checkout-43"))
      step(
        "checkout-42 reads orders",
        smock.call("GET", orders, session="checkout-42"),
      )
      step(
        "no Session sets visits",
        smock.call("PUT", "\{data}/visits", body="{\"total\": 2}"),
      )
      step("no Session reads visits", smock.call("GET", "\{data}/visits"))
      step(
        "checkout-42 drops orders",
        smock.call("DELETE", orders, session="checkout-42"),
      )
      step(
        "checkout-42 GET /api/v1/orders",
        smock.order("GET", "/api/v1/orders", session="checkout-42"),
      )
      step(
        "checkout-42 drops orders again",
        smock.call("DELETE", orders, session="checkout-42"),
      )
      let replicas = [
        smock.admin("GET", data),
        smock.admin("GET", orders),
        smock.admin("PUT", orders, body="[]"),
        smock.admin("DELETE", orders),
        smock.admin("GET", "\{data}/nope"),
      ].map(response => {
        "\{response.status} \{response.header("Smock-Replica") is Some(_)}"
      })
      step("Smock-Replica", replicas.join(", "))
      inspect(
        out.join("\n"),
        content=(
          #|list without a token: 401
          #|read without a token: 401
          #|set without a token: 401
          #|drop without a token: 401
          #|checkout-42 sets orders: 200 {"bucket":{"name":"orders","key":"id","newKey":"integer","written":true,"value":[{"id":1,"status":"paid"}]},"warnings":[]}
          #|checkout-42 GET /api/v1/orders: 200 [{"id":1,"status":"paid"}]
          #|checkout-43 GET /api/v1/orders: 200 [{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]
          #|checkout-42 lists: 200 {"data":[{"name":"orders","key":"id","newKey":"integer","written":true},{"name":"visits","key":null,"newKey":null,"written":false}],"warnings":[]}
          #|checkout-43 lists: 200 {"data":[{"name":"orders","key":"id","newKey":"integer","written":false},{"name":"visits","key":null,"newKey":null,"written":false}],"warnings":[]}
          #|checkout-42 reads orders: 200 {"bucket":{"name":"orders","key":"id","newKey":"integer","written":true,"value":[{"id":1,"status":"paid"}]},"warnings":[]}
          #|no Session sets visits: 200 {"bucket":{"name":"visits","key":null,"newKey":null,"written":true,"value":{"total":2}},"warnings":[]}
          #|no Session reads visits: 200 {"bucket":{"name":"visits","key":null,"newKey":null,"written":true,"value":{"total":2}},"warnings":[]}
          #|checkout-42 drops orders: 200 {"bucket":{"name":"orders","key":"id","newKey":"integer","written":false,"value":[{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]},"warnings":[]}
          #|checkout-42 GET /api/v1/orders: 200 [{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]
          #|checkout-42 drops orders again: 200 {"bucket":{"name":"orders","key":"id","newKey":"integer","written":false,"value":[{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]},"warnings":[]}
          #|Smock-Replica: 200 true, 200 true, 200 true, 200 true, 404 true
        ),
      )
    })
    inspect(
      log_entries(
        stopped.logs.filter(line => line.contains("\"msg\":\"Data bucket")),
      ),
      content=(
        #|{"level":"info","msg":"Data bucket set","mock":"shop","session":"checkout-42","bucket":"orders"}
        #|{"level":"info","msg":"Data bucket set","mock":"shop","session":null,"bucket":"visits"}
        #|{"level":"info","msg":"Data bucket copy dropped","mock":"shop","session":"checkout-42","bucket":"orders"}
        #|{"level":"info","msg":"Data bucket set","mock":"shop","session":null,"bucket":"orders"}
        #|{"level":"info","msg":"Data bucket copy dropped","mock":"shop","session":null,"bucket":"orders"}
      ),
    )
  })
}

///|
async test "Admin API errors on Data buckets: an unknown Mock, an unknown bucket, a body that is not JSON, missing or over the body limit, a value that breaks a keyed bucket, and a method a path does not take" {
  with_definitions(shop_orders, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0", "--body-limit", "64"], smock => {
      let orders = "/v1/mocks/shop/data/orders"
      let calls : Array[(String, String, String?)] = [
        ("GET", "/v1/mocks/orders/data", None),
        ("GET", "/v1/mocks/orders/data/orders", None),
        ("PUT", "/v1/mocks/orders/data/orders", Some("[]")),
        ("DELETE", "/v1/mocks/orders/data/orders", None),
        ("GET", "/v1/mocks/shop/data/order", None),
        ("PUT", "/v1/mocks/shop/data/a%20b", Some("1")),
        ("DELETE", "/v1/mocks/shop/data/vis%69ts", None),
        ("PUT", orders, Some("[{\"id\":")),
        ("PUT", orders, None),
        ("PUT", orders, Some("[{\"id\": 1}, {\"id\": \"1\"}, {\"no\": 2}]")),
        ("PUT", orders, Some("{\"id\": 1}")),
        ("PUT", orders, Some("[\{"{\"id\": 1}, ".repeat(5)}{\"id\": 9}]")),
        ("POST", orders, Some("[]")),
        ("PATCH", "/v1/mocks/shop/data", None),
      ]
      let out = []
      for call in calls {
        let (meth, path, body) = call
        let response = smock.admin(meth, path, body?)
        let allow = match response.header("Allow") {
          Some(allow) => " (Allow: \{allow})"
          None => ""
        }
        out.push("\{meth} \{path}: \{response.status}\{allow} \{response.body}")
      }
      out.push("lists: \{smock.call("GET", "/v1/mocks/shop/data")}")
      inspect(
        out.join("\n"),
        content=(
          #|GET /v1/mocks/orders/data: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|GET /v1/mocks/orders/data/orders: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|PUT /v1/mocks/orders/data/orders: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|DELETE /v1/mocks/orders/data/orders: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|GET /v1/mocks/shop/data/order: 404 {"error":"unknown_bucket","message":"the Mock \"shop\" declares no Data bucket \"order\": Data buckets come only from Definition files","warnings":[]}
          #|PUT /v1/mocks/shop/data/a%20b: 404 {"error":"unknown_bucket","message":"the Mock \"shop\" declares no Data bucket \"a b\": Data buckets come only from Definition files","warnings":[]}
          #|DELETE /v1/mocks/shop/data/vis%69ts: 200 {"bucket":{"name":"visits","key":null,"newKey":null,"written":false,"value":0},"warnings":[]}
          #|PUT /v1/mocks/shop/data/orders: 400 {"error":"malformed_json","message":"the body is not valid JSON: Unexpected end of file","warnings":[]}
          #|PUT /v1/mocks/shop/data/orders: 400 {"error":"invalid_request","message":"the body must be the value to set the bucket to: any JSON value","warnings":[]}
          #|PUT /v1/mocks/shop/data/orders: 400 {"error":"invalid_data","message":"the value breaks the rules of the Data bucket \"orders\", keyed by \"id\": /1/id has the key text \"1\", as item 0 does; /2 needs the key member \"id\"","warnings":[]}
          #|PUT /v1/mocks/shop/data/orders: 400 {"error":"invalid_data","message":"the value breaks the rules of the Data bucket \"orders\", keyed by \"id\": must be an array of objects, since the bucket has \"key\"","warnings":[]}
          #|PUT /v1/mocks/shop/data/orders: 413 {"error":"content_too_large","message":"the body is over the body limit (--body-limit)","warnings":[]}
          #|POST /v1/mocks/shop/data/orders: 405 (Allow: GET, HEAD, PUT, DELETE) {"error":"method_not_allowed","message":"/v1/mocks/shop/data/orders takes GET, HEAD, PUT, DELETE, not POST","warnings":[]}
          #|PATCH /v1/mocks/shop/data: 405 (Allow: GET, HEAD) {"error":"method_not_allowed","message":"/v1/mocks/shop/data takes GET, HEAD, not PATCH","warnings":[]}
          #|lists: 200 {"data":[{"name":"orders","key":"id","newKey":"integer","written":false},{"name":"visits","key":null,"newKey":null,"written":false}],"warnings":[]}
        ),
      )
    })
  })
}

///|
async test "--state-max-bytes: a set of a copy that would pass the bound gets 507 and writes nothing, the metrics count the copies and the refusal, and a drop gives the bytes back" {
  with_definitions(shop_orders, dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--state-max-bytes", "250"],
      smock => {
        let out = []
        let step = (label : String, result : String) => {
          out.push("\{label}: \{result}")
        }
        let metrics = () => {
          let text = smock.admin("GET", "/metrics").body
          metric_lines(text, "smock_state_").join(", ")
        }
        let data = "/v1/mocks/shop/data"
        // shop and run-42 count 4 + 6 + 64; visits counts 6 + 64, and 7,
        // 1 byte and one JSON value: 161 in all.
        step(
          "set visits",
          smock.call("PUT", "\{data}/visits", session="run-42", body="7"),
        )
        step("metrics", metrics())
        // orders: 6 + 64, and [{"id":1}], 10 bytes and three JSON values:
        // 128 more.
        step(
          "set orders",
          smock.call(
            "PUT",
            "\{data}/orders",
            session="run-42",
            body="[{\"id\": 1}]",
          ),
        )
        step("metrics", metrics())
        step(
          "run-42 GET /api/v1/orders",
          smock.order("GET", "/api/v1/orders", session="run-42"),
        )
        step("run-42 lists", smock.call("GET", data, session="run-42"))
        step(
          "drop visits",
          smock.call("DELETE", "\{data}/visits", session="run-42"),
        )
        step("metrics", metrics())
        step(
          "set orders",
          smock.call(
            "PUT",
            "\{data}/orders",
            session="run-42",
            body="[{\"id\": 1}]",
          ),
        )
        step("metrics", metrics())
        inspect(
          out.join("\n"),
          content=(
            #|set visits: 200 {"bucket":{"name":"visits","key":null,"newKey":null,"written":true,"value":7},"warnings":[]}
            #|metrics: smock_state_bytes 161, smock_state_writes_refused_total 0
            #|set orders: 507 {"error":"state_limit_reached","message":"the writes would take per-Session state from 161 to 289 bytes, above its bound of 250 (--state-max-bytes)","warnings":[]}
            #|metrics: smock_state_bytes 161, smock_state_writes_refused_total 1
            #|run-42 GET /api/v1/orders: 200 [{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]
            #|run-42 lists: 200 {"data":[{"name":"orders","key":"id","newKey":"integer","written":false},{"name":"visits","key":null,"newKey":null,"written":true}],"warnings":[]}
            #|drop visits: 200 {"bucket":{"name":"visits","key":null,"newKey":null,"written":false,"value":0},"warnings":[]}
            #|metrics: smock_state_bytes 0, smock_state_writes_refused_total 1
            #|set orders: 200 {"bucket":{"name":"orders","key":"id","newKey":"integer","written":true,"value":[{"id":1}]},"warnings":[]}
            #|metrics: smock_state_bytes 202, smock_state_writes_refused_total 1
          ),
        )
      },
    )
  })
}

///|
async test "with more than one replica, every reply of the Data bucket operations, errors included, warns that state is per replica" {
  with_definitions(shop_orders, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0", "--replicas", "2"], smock => {
      let data = "/v1/mocks/shop/data"
      let responses = [
        smock.admin("GET", data),
        smock.admin("PUT", "\{data}/visits", body="1"),
        smock.admin("GET", "\{data}/visits"),
        smock.admin("DELETE", "\{data}/visits"),
        smock.admin("GET", "\{data}/nope"),
        smock.admin("PUT", "\{data}/orders", body="{}"),
      ]
      let out = []
      for response in responses {
        guard response.json() is Object(body) &&
          body.get("warnings") is Some(Array([Object(warning)])) &&
          warning.get("code") is Some(String(code)) &&
          warning.get("message") is Some(String(message)) else {
          fail("not one warning in \{response.body}")
        }
        out.push(
          "\{response.status} \{code}: \{message.contains("copies of Data buckets")}",
        )
      }
      inspect(
        out.join("\n"),
        content=(
          #|200 per_replica_state: true
          #|200 per_replica_state: true
          #|200 per_replica_state: true
          #|200 per_replica_state: true
          #|404 per_replica_state: true
          #|400 per_replica_state: true
        ),
      )
    })
  })
}
