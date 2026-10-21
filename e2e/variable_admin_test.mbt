// Seam 2 tests of the Admin API operations on Variables: listing the
// calling Session's Variables of a Mock, setting one and deleting one, over
// the authenticated Admin API, within the bound on per-Session state. Every
// Admin API response is checked against the OpenAPI document
// (contract_test.mbt).

///|
async test "over the authenticated Admin API, a test sets a Variable for its Session before it calls GET /me, lists what its requests wrote, and deletes one" {
  with_definitions([("shop.yaml", who_logged_in)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let step = (label : String, result : String) => {
        out.push("\{label}: \{result}")
      }
      let variables = "/v1/mocks/shop/variables"
      step(
        "list without a token",
        smock.admin("GET", variables, token=None).status.to_string(),
      )
      step(
        "set without a token",
        smock.admin("PUT", "\{variables}/user", token=None, body="\"ann\"").status.to_string(),
      )
      step(
        "delete without a token",
        smock.admin("DELETE", "\{variables}/user", token=None).status.to_string(),
      )
      step(
        "test-a sets user",
        smock.call("PUT", "\{variables}/user", session="test-a", body="\"ann\""),
      )
      step("test-a GET /me", smock.order("GET", "/me", session="test-a"))
      step("test-b GET /me", smock.order("GET", "/me", session="test-b"))
      smock.send(
        "POST",
        "/login",
        headers=[baggage("test-a"), ("Content-Type", "application/json")],
        body="{\"user\":\"bob\"}",
      )
      |> ignore
      step("test-a lists", smock.call("GET", variables, session="test-a"))
      step("test-b lists", smock.call("GET", variables, session="test-b"))
      step(
        "test-a deletes previous",
        smock.call("DELETE", "\{variables}/previous", session="test-a"),
      )
      step(
        "no Session sets cart",
        smock.call(
          "PUT",
          "\{variables}/cart",
          body="{\"items\": [{\"sku\": \"a1\", \"qty\": 2}], \"total\": 19.99}",
        ),
      )
      step("test-a lists", smock.call("GET", variables, session="test-a"))
      step("no Session lists", smock.call("GET", variables))
      let replicas = [
        smock.admin("GET", variables),
        smock.admin("PUT", "\{variables}/x", body="1"),
        smock.admin("DELETE", "\{variables}/x"),
        smock.admin("DELETE", "\{variables}/x"),
      ].map(response => {
        "\{response.status} \{response.header("Smock-Replica") is Some(_)}"
      })
      step("Smock-Replica", replicas.join(", "))
      inspect(
        out.join("\n"),
        content=(
          #|list without a token: 401
          #|set without a token: 401
          #|delete without a token: 401
          #|test-a sets user: 200 {"name":"user","value":"ann","warnings":[]}
          #|test-a GET /me: 200 {"user":"ann"}
          #|test-b GET /me: 200 {"user":null}
          #|test-a lists: 200 {"variables":{"previous":"ann","user":"bob"},"warnings":[]}
          #|test-b lists: 200 {"variables":{},"warnings":[]}
          #|test-a deletes previous: 200 {"name":"previous","warnings":[]}
          #|no Session sets cart: 200 {"name":"cart","value":{"items":[{"sku":"a1","qty":2}],"total":19.99},"warnings":[]}
          #|test-a lists: 200 {"variables":{"user":"bob"},"warnings":[]}
          #|no Session lists: 200 {"variables":{"cart":{"items":[{"sku":"a1","qty":2}],"total":19.99}},"warnings":[]}
          #|Smock-Replica: 200 true, 200 true, 200 true, 404 true
        ),
      )
    })
    inspect(
      log_entries(
        stopped.logs.filter(line => line.contains("\"msg\":\"Variable ")),
      ),
      content=(
        #|{"level":"info","msg":"Variable set","mock":"shop","session":"test-a","variable":"user"}
        #|{"level":"info","msg":"Variable deleted","mock":"shop","session":"test-a","variable":"previous"}
        #|{"level":"info","msg":"Variable set","mock":"shop","session":null,"variable":"cart"}
        #|{"level":"info","msg":"Variable set","mock":"shop","session":null,"variable":"x"}
        #|{"level":"info","msg":"Variable deleted","mock":"shop","session":null,"variable":"x"}
      ),
    )
  })
}

///|
async test "Admin API errors on Variables: an unknown Mock, a name that is not a Variable name, a body that is not JSON or is missing, an unset Variable, and a method a path does not take" {
  with_definitions([("shop.yaml", who_logged_in)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      ignore(
        smock.call(
          "PUT",
          "/v1/mocks/shop/variables/user",
          session="test-b",
          body="\"bob\"",
        ),
      )
      let user = "/v1/mocks/shop/variables/user"
      let long = "x".repeat(129)
      let calls : Array[(String, String, String?, String?)] = [
        ("GET", "/v1/mocks/orders/variables", None, None),
        ("PUT", "/v1/mocks/orders/variables/user", None, Some("1")),
        ("DELETE", "/v1/mocks/orders/variables/user", None, None),
        ("PUT", "/v1/mocks/shop/variables/a.b", None, Some("1")),
        ("PUT", "/v1/mocks/shop/variables/a%20b", None, Some("1")),
        ("PUT", "/v1/mocks/shop/variables/\{long}", None, Some("1")),
        ("DELETE", "/v1/mocks/shop/variables/a.b", None, None),
        ("PUT", user, None, Some("{\"name\":")),
        ("PUT", user, None, Some("ann")),
        ("PUT", user, None, None),
        ("DELETE", user, Some("test-a"), None),
        ("DELETE", user, None, None),
        ("POST", user, None, Some("1")),
        ("GET", user, None, None),
        ("DELETE", "/v1/mocks/shop/variables", None, None),
      ]
      let out = []
      for call in calls {
        let (meth, path, session, body) = call
        let response = smock.admin(
          meth,
          path,
          headers=session_headers(session),
          body?,
        )
        let allow = match response.header("Allow") {
          Some(allow) => " (Allow: \{allow})"
          None => ""
        }
        let path = path.replace_all(old=long, new="x...x")
        let as_session = match session {
          Some(session) => " as \{session}"
          None => ""
        }
        out.push(
          "\{meth} \{path}\{as_session}: \{response.status}\{allow} \{response.body.replace_all(old=long, new="x...x")}",
        )
      }
      out.push(
        "test-b lists: \{smock.call("GET", "/v1/mocks/shop/variables", session="test-b")}",
      )
      inspect(
        out.join("\n"),
        content=(
          #|GET /v1/mocks/orders/variables: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|PUT /v1/mocks/orders/variables/user: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|DELETE /v1/mocks/orders/variables/user: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|PUT /v1/mocks/shop/variables/a.b: 400 {"error":"invalid_request","message":"\"a.b\" is not a Variable name: 1 to 128 ASCII letters, digits, _ and -","warnings":[]}
          #|PUT /v1/mocks/shop/variables/a%20b: 400 {"error":"invalid_request","message":"\"a b\" is not a Variable name: 1 to 128 ASCII letters, digits, _ and -","warnings":[]}
          #|PUT /v1/mocks/shop/variables/x...x: 400 {"error":"invalid_request","message":"\"x...x\" is not a Variable name: 1 to 128 ASCII letters, digits, _ and -","warnings":[]}
          #|DELETE /v1/mocks/shop/variables/a.b: 400 {"error":"invalid_request","message":"\"a.b\" is not a Variable name: 1 to 128 ASCII letters, digits, _ and -","warnings":[]}
          #|PUT /v1/mocks/shop/variables/user: 400 {"error":"malformed_json","message":"the body is not valid JSON: Unexpected end of file","warnings":[]}
          #|PUT /v1/mocks/shop/variables/user: 400 {"error":"malformed_json","message":"the body is not valid JSON: Invalid character 'a' at line 1, column 0","warnings":[]}
          #|PUT /v1/mocks/shop/variables/user: 400 {"error":"invalid_request","message":"the body must be the value to set the Variable to: any JSON value","warnings":[]}
          #|DELETE /v1/mocks/shop/variables/user as test-a: 404 {"error":"unknown_variable","message":"the calling Session has no Variable \"user\" in the Mock \"shop\"","warnings":[]}
          #|DELETE /v1/mocks/shop/variables/user: 404 {"error":"unknown_variable","message":"the no-Session space has no Variable \"user\" in the Mock \"shop\"","warnings":[]}
          #|POST /v1/mocks/shop/variables/user: 405 (Allow: PUT, DELETE) {"error":"method_not_allowed","message":"/v1/mocks/shop/variables/user takes PUT, DELETE, not POST","warnings":[]}
          #|GET /v1/mocks/shop/variables/user: 405 (Allow: PUT, DELETE) {"error":"method_not_allowed","message":"/v1/mocks/shop/variables/user takes PUT, DELETE, not GET","warnings":[]}
          #|DELETE /v1/mocks/shop/variables: 405 (Allow: GET, HEAD) {"error":"method_not_allowed","message":"/v1/mocks/shop/variables takes GET, HEAD, not DELETE","warnings":[]}
          #|test-b lists: 200 {"variables":{"user":"bob"},"warnings":[]}
        ),
      )
    })
  })
}

///|
async test "--state-max-bytes: a set that would pass the bound gets 507 and writes nothing, the refused-writes metric counts it, and a delete gives the bytes back for a later set" {
  with_definitions([("shop.yaml", who_logged_in)], dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--state-max-bytes", "200"],
      smock => {
        let out = []
        let step = (label : String, result : String) => {
          out.push("\{label}: \{result}")
        }
        let metrics = () => {
          let text = smock.admin("GET", "/metrics").body
          metric_lines(text, "smock_state_").join(", ")
        }
        let cart = "/v1/mocks/shop/variables/cart"
        // shop and run-42 count 4 + 6 + 64; cart counts 4 + 64, and
        // {"sku":"a1"}, 12 bytes and two JSON values: 186 in all.
        step(
          "set cart",
          smock.call("PUT", cart, session="run-42", body="{\"sku\": \"a1\"}"),
        )
        // {"sku":"a1","qty":2} counts 20 bytes and three JSON values.
        step(
          "set a larger cart",
          smock.call(
            "PUT",
            cart,
            session="run-42",
            body="{\"sku\": \"a1\", \"qty\": 2}",
          ),
        )
        step("metrics", metrics())
        step(
          "run-42 lists",
          smock.call("GET", "/v1/mocks/shop/variables", session="run-42"),
        )
        step("delete cart", smock.call("DELETE", cart, session="run-42"))
        step("metrics", metrics())
        // The space counts 74 again, and qty: 2 counts 3 + 64 + 1 + 16.
        step(
          "set qty",
          smock.call(
            "PUT",
            "/v1/mocks/shop/variables/qty",
            session="run-42",
            body="2",
          ),
        )
        step("metrics", metrics())
        inspect(
          out.join("\n"),
          content=(
            #|set cart: 200 {"name":"cart","value":{"sku":"a1"},"warnings":[]}
            #|set a larger cart: 507 {"error":"state_limit_reached","message":"the writes would take per-Session state from 186 to 210 bytes, above its bound of 200 (--state-max-bytes)","warnings":[]}
            #|metrics: smock_state_bytes 186, smock_state_writes_refused_total 1
            #|run-42 lists: 200 {"variables":{"cart":{"sku":"a1"}},"warnings":[]}
            #|delete cart: 200 {"name":"cart","warnings":[]}
            #|metrics: smock_state_bytes 0, smock_state_writes_refused_total 1
            #|set qty: 200 {"name":"qty","value":2,"warnings":[]}
            #|metrics: smock_state_bytes 158, smock_state_writes_refused_total 1
          ),
        )
      },
    )
  })
}

///|
async test "with more than one replica, every reply of the Variable operations, errors included, warns that state is per replica" {
  with_definitions([("shop.yaml", who_logged_in)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0", "--replicas", "2"], smock => {
      let variables = "/v1/mocks/shop/variables"
      let responses = [
        smock.admin("PUT", "\{variables}/user", body="\"ann\""),
        smock.admin("GET", variables),
        smock.admin("DELETE", "\{variables}/user"),
        smock.admin("DELETE", "\{variables}/user"),
        smock.admin("PUT", "\{variables}/a.b", body="1"),
      ]
      let out = []
      for response in responses {
        guard response.json() is Object(body) &&
          body.get("warnings") is Some(Array([Object(warning)])) &&
          warning.get("code") is Some(String(code)) else {
          fail("not one warning in \{response.body}")
        }
        out.push("\{response.status} \{code}")
      }
      inspect(
        out.join("\n"),
        content=(
          #|200 per_replica_state
          #|200 per_replica_state
          #|200 per_replica_state
          #|404 per_replica_state
          #|400 per_replica_state
        ),
      )
    })
  })
}
