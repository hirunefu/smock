// Seam 2 tests of the Admin API operations on Scenarios: listing the
// calling Session's Scenarios of a Mock and setting one, over the
// authenticated Admin API. Every Admin API response is checked against the
// OpenAPI document (contract_test.mbt).

///|
async test "over the authenticated Admin API, a test lists its Session's Scenarios of a Mock and sets one, and its requests follow the state it set" {
  with_definitions([("payments.json", checkout)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let step = (label : String, result : String) => {
        out.push("\{label}: \{result}")
      }
      let scenarios = "/v1/mocks/payments/scenarios"
      let paid = "{\"state\":\"Paid\"}"
      step(
        "list without a token",
        smock.admin("GET", scenarios, token=None).status.to_string(),
      )
      step(
        "set without a token",
        smock.admin("PUT", "\{scenarios}/checkout", token=None, body=paid).status.to_string(),
      )
      step("test-a lists", smock.call("GET", scenarios, session="test-a"))
      step(
        "test-a sets Paid",
        smock.call("PUT", "\{scenarios}/checkout", session="test-a", body=paid),
      )
      step("test-a GET", smock.order("GET", "/orders/42", session="test-a"))
      step("test-b GET", smock.order("GET", "/orders/42", session="test-b"))
      step("test-a lists", smock.call("GET", scenarios, session="test-a"))
      step("test-b lists", smock.call("GET", scenarios, session="test-b"))
      step("no Session lists", smock.call("GET", scenarios))
      step(
        "test-a sets Started",
        smock.call(
          "PUT",
          "\{scenarios}/checkout",
          session="test-a",
          body="{\"state\":\"Started\"}",
        ),
      )
      step("test-a GET", smock.order("GET", "/orders/42", session="test-a"))
      let replicas = [
        smock.admin("GET", scenarios),
        smock.admin("PUT", "\{scenarios}/checkout", body=paid),
        smock.admin("PUT", "\{scenarios}/checkout", body="{\"state\":\"x\"}"),
      ].map(response => {
        "\{response.status} \{response.header("Smock-Replica") is Some(_)}"
      })
      step("Smock-Replica", replicas.join(", "))
      inspect(
        out.join("\n"),
        content=(
          #|list without a token: 401
          #|set without a token: 401
          #|test-a lists: 200 {"scenarios":[{"name":"checkout","state":"Started","states":["Started","Paid"]}],"warnings":[]}
          #|test-a sets Paid: 200 {"scenario":{"name":"checkout","state":"Paid","states":["Started","Paid"]},"warnings":[]}
          #|test-a GET: 200 {"status":"paid"}
          #|test-b GET: 200 {"status":"pending"}
          #|test-a lists: 200 {"scenarios":[{"name":"checkout","state":"Paid","states":["Started","Paid"]}],"warnings":[]}
          #|test-b lists: 200 {"scenarios":[{"name":"checkout","state":"Started","states":["Started","Paid"]}],"warnings":[]}
          #|no Session lists: 200 {"scenarios":[{"name":"checkout","state":"Started","states":["Started","Paid"]}],"warnings":[]}
          #|test-a sets Started: 200 {"scenario":{"name":"checkout","state":"Started","states":["Started","Paid"]},"warnings":[]}
          #|test-a GET: 200 {"status":"pending"}
          #|Smock-Replica: 200 true, 200 true, 400 true
        ),
      )
    })
  })
}

///|
async test "Admin API errors on Scenarios: an unknown Mock, Scenario or state, malformed JSON, a body that is not {\"state\": <name>}, and a method a path does not take" {
  with_definitions([("payments.json", checkout)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      ignore(
        smock.call(
          "POST",
          "/v1/mocks/payments/stubs",
          session="test-b",
          body=(
            #|{ "request": { "method": "GET", "path": "/beta" },
            #|  "scenario": { "name": "beta", "moveTo": "On" },
            #|  "response": { "status": 200 } }
          ),
        ),
      )
      let checkout = "/v1/mocks/payments/scenarios/checkout"
      let calls : Array[(String, String, String?, String?)] = [
        ("GET", "/v1/mocks/orders/scenarios", None, None),
        (
          "PUT",
          "/v1/mocks/orders/scenarios/checkout",
          None,
          Some("{\"state\":\"Paid\"}"),
        ),
        (
          "PUT",
          "/v1/mocks/payments/scenarios/nowhere",
          None,
          Some("{\"state\":\"Started\"}"),
        ),
        (
          "PUT",
          "/v1/mocks/payments/scenarios/beta",
          Some("test-a"),
          Some("{\"state\":\"On\"}"),
        ),
        ("PUT", checkout, None, Some("{\"state\":\"paid\"}")),
        ("PUT", checkout, Some("test-a"), Some("{\"state\":\"On\"}")),
        ("PUT", checkout, None, Some("{\"state\":")),
        ("PUT", checkout, None, None),
        ("PUT", checkout, None, Some("[]")),
        ("PUT", checkout, None, Some("{}")),
        ("PUT", checkout, None, Some("{\"state\":\"Paid\",\"session\":\"x\"}")),
        ("PUT", checkout, None, Some("{\"state\":1}")),
        ("PUT", checkout, None, Some("{\"state\":\"\"}")),
        ("POST", "/v1/mocks/payments/scenarios", None, Some("{}")),
        ("GET", checkout, None, None),
      ]
      let out = []
      for call in calls {
        let (meth, path, session, body) = call
        let who = match session {
          Some(session) => " as \{session}"
          None => ""
        }
        out.push(
          "\{meth} \{path}\{who}: \{smock.call(meth, path, session?, body?)}",
        )
      }
      inspect(
        out.join("\n"),
        content=(
          #|GET /v1/mocks/orders/scenarios: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|PUT /v1/mocks/orders/scenarios/checkout: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|PUT /v1/mocks/payments/scenarios/nowhere: 404 {"error":"unknown_scenario","message":"no Stub of the Mock \"payments\" names the Scenario \"nowhere\", in the Definition files or among the Ephemeral Stubs of the no-Session space","warnings":[]}
          #|PUT /v1/mocks/payments/scenarios/beta as test-a: 404 {"error":"unknown_scenario","message":"no Stub of the Mock \"payments\" names the Scenario \"beta\", in the Definition files or among the Ephemeral Stubs of the calling Session","warnings":[]}
          #|PUT /v1/mocks/payments/scenarios/checkout: 400 {"error":"unknown_state","message":"\"paid\" is not a known state of the Scenario \"checkout\" of the Mock \"payments\" for the no-Session space, which are \"Started\", \"Paid\"","warnings":[]}
          #|PUT /v1/mocks/payments/scenarios/checkout as test-a: 400 {"error":"unknown_state","message":"\"On\" is not a known state of the Scenario \"checkout\" of the Mock \"payments\" for the calling Session, which are \"Started\", \"Paid\"","warnings":[]}
          #|PUT /v1/mocks/payments/scenarios/checkout: 400 {"error":"malformed_json","message":"the body is not valid JSON: Unexpected end of file","warnings":[]}
          #|PUT /v1/mocks/payments/scenarios/checkout: 400 {"error":"invalid_request","message":"the body must be {\"state\":<name>}, the state to set the Scenario to","warnings":[]}
          #|PUT /v1/mocks/payments/scenarios/checkout: 400 {"error":"invalid_request","message":"the body must be {\"state\":<name>}, the state to set the Scenario to","warnings":[]}
          #|PUT /v1/mocks/payments/scenarios/checkout: 400 {"error":"invalid_request","message":"the body must be {\"state\":<name>}, the state to set the Scenario to","warnings":[]}
          #|PUT /v1/mocks/payments/scenarios/checkout: 400 {"error":"invalid_request","message":"the body must be {\"state\":<name>}, the state to set the Scenario to","warnings":[]}
          #|PUT /v1/mocks/payments/scenarios/checkout: 400 {"error":"invalid_request","message":"the body must be {\"state\":<name>}, the state to set the Scenario to","warnings":[]}
          #|PUT /v1/mocks/payments/scenarios/checkout: 400 {"error":"invalid_request","message":"the body must be {\"state\":<name>}, the state to set the Scenario to","warnings":[]}
          #|POST /v1/mocks/payments/scenarios: 405 {"error":"method_not_allowed","message":"/v1/mocks/payments/scenarios takes GET, HEAD, not POST","warnings":[]}
          #|GET /v1/mocks/payments/scenarios/checkout: 405 {"error":"method_not_allowed","message":"/v1/mocks/payments/scenarios/checkout takes PUT, not GET","warnings":[]}
        ),
      )
    })
  })
}

///|
async test "a Mock or Scenario name that is not a plain path segment is percent-encoded in the path" {
  let definitions =
    #|{ "mocks": [{ "name": "users api/v2" }],
    #|  "stubs": [
    #|    { "id": "done", "mock": "users api/v2",
    #|      "request": { "method": "GET", "path": "/users/1" },
    #|      "scenario": { "name": "check out/é", "requires": "Done ✓" },
    #|      "response": { "status": 200, "body": "done" } } ] }
  with_definitions([("users.json", definitions)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let scenarios = "/v1/mocks/users%20api%2Fv2/scenarios"
      let out = [
        smock.call(
          "PUT",
          "\{scenarios}/check%20out%2F%C3%A9",
          session="%C3%A9",
          body="{\"state\":\"Done ✓\"}",
        ),
        smock.call("GET", scenarios, session="%C3%A9"),
        smock.user(session="%C3%A9"),
        smock.user(),
      ]
      inspect(
        out.join("\n"),
        content=(
          #|200 {"scenario":{"name":"check out/é","state":"Done ✓","states":["Started","Done ✓"]},"warnings":[]}
          #|200 {"scenarios":[{"name":"check out/é","state":"Done ✓","states":["Started","Done ✓"]}],"warnings":[]}
          #|HTTP/1.1 200 OK done
          #|HTTP/1.1 404 Not Found [Smock-Near-Miss: done; failed=scenario:check%20out%2F%C3%A9] {"error":"no Stub matched"}
        ),
      )
    })
  })
}

///|
async test "setting a Scenario's state writes a JSON log entry; listing and refused sets write none" {
  with_definitions([("payments.json", checkout)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let scenarios = "/v1/mocks/payments/scenarios"
      ignore(smock.call("GET", scenarios, session="test-a"))
      ignore(
        smock.call(
          "PUT",
          "\{scenarios}/checkout",
          session="test-a",
          body="{\"state\":\"Paid\"}",
        ),
      )
      ignore(
        smock.call(
          "PUT",
          "\{scenarios}/checkout",
          body="{\"state\":\"Started\"}",
        ),
      )
      ignore(
        smock.call("PUT", "\{scenarios}/checkout", body="{\"state\":\"x\"}"),
      )
      ignore(
        smock.call("PUT", "\{scenarios}/nowhere", body="{\"state\":\"Paid\"}"),
      )
      ignore(smock.call("PUT", "\{scenarios}/checkout", body="{}"))
    })
    // The entries after the last `listening` one, which ends startup.
    let after = stopped.logs.length() -
      stopped.logs.rev().search_by(line => listening(line) is Some(_)).unwrap()
    inspect(
      log_entries(stopped.logs[after:].to_owned()),
      content=(
        #|{"level":"info","msg":"Scenario state set","mock":"payments","session":"test-a","scenario":"checkout","state":"Paid"}
        #|{"level":"info","msg":"Scenario state set","mock":"payments","session":null,"scenario":"checkout","state":"Started"}
        #|{"level":"info","msg":"drain started","timeoutMs":20000}
        #|{"level":"info","msg":"drain ended","connectionsCut":0}
      ),
    )
  })
}
