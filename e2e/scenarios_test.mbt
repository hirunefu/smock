// Seam 2 tests of Scenarios: Stubs whose scenario clause requires or moves
// the state of a Session's Scenario, driven over HTTP by real clients, one
// connection per request, with Ephemeral Stubs added over the Admin API.

///|
/// The example of spec #48: `GET /orders/42` answers pending until `POST
/// /orders/42/pay` moves the Scenario `checkout` to `Paid`, and paid after.
let checkout : String =
  #|{ "mocks": [{ "name": "payments" }],
  #|  "stubs": [
  #|    { "id": "order-pending", "mock": "payments",
  #|      "request": { "method": "GET", "path": "/orders/42" },
  #|      "scenario": { "name": "checkout", "requires": "Started" },
  #|      "response": { "status": 200, "json": { "status": "pending" } } },
  #|    { "id": "pay", "mock": "payments",
  #|      "request": { "method": "POST", "path": "/orders/42/pay" },
  #|      "scenario": { "name": "checkout", "requires": "Started", "moveTo": "Paid" },
  #|      "response": { "status": 200 } },
  #|    { "id": "order-paid", "mock": "payments",
  #|      "request": { "method": "GET", "path": "/orders/42" },
  #|      "scenario": { "name": "checkout", "requires": "Paid" },
  #|      "response": { "status": 200, "json": { "status": "paid" } } } ] }

///|
/// `meth path` with a real HTTP client on a connection of its own, with
/// the Session `session` in its baggage when given: the status and the
/// body, if any.
async fn Smock::order(
  self : Smock,
  meth : String,
  path : String,
  session? : String,
) -> String {
  let headers : @http.Headers = Map([])
  if session is Some(session) {
    let (name, value) = baggage(session)
    headers[@http.CaseInsensitiveString(name)] = value
  }
  let client = @http.Client("http://127.0.0.1:\{self.port}", headers~)
  defer client.close()
  let response = if meth == "POST" {
    client.post(path, "")
  } else {
    client.get(path)
  }
  match client.read_all().text() {
    "" => "\{response.code}, no body"
    body => "\{response.code} \{body}"
  }
}

///|
async test "over HTTP, each Session walks the checkout Scenario on its own: test-a pays and sees paid, test-b still sees pending, and its second payment matches nothing" {
  with_definitions([("payments.json", checkout)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let step = (label : String, result : String) => {
        out.push("\{label}: \{result}")
      }
      step("test-a GET", smock.order("GET", "/orders/42", session="test-a"))
      step(
        "test-a pays",
        smock.order("POST", "/orders/42/pay", session="test-a"),
      )
      step("test-a GET", smock.order("GET", "/orders/42", session="test-a"))
      step("test-b GET", smock.order("GET", "/orders/42", session="test-b"))
      step(
        "test-b pays",
        smock.order("POST", "/orders/42/pay", session="test-b"),
      )
      step(
        "test-b pays again",
        smock.order("POST", "/orders/42/pay", session="test-b"),
      )
      step("test-b GET", smock.order("GET", "/orders/42", session="test-b"))
      step("no Session GET", smock.order("GET", "/orders/42"))
      inspect(
        out.join("\n"),
        content=(
          #|test-a GET: 200 {"status":"pending"}
          #|test-a pays: 200, no body
          #|test-a GET: 200 {"status":"paid"}
          #|test-b GET: 200 {"status":"pending"}
          #|test-b pays: 200, no body
          #|test-b pays again: 404 {"error":"no Stub matched"}
          #|test-b GET: 200 {"status":"paid"}
          #|no Session GET: 200 {"status":"pending"}
        ),
      )
    })
  })
}

///|
async test "an Ephemeral Stub added over the Admin API takes a Scenario clause, which its listing echoes, and shares its Session's state with the file Stubs; deleting it leaves the state alone" {
  with_definitions([("payments.json", checkout)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let step = (label : String, result : String) => {
        out.push("\{label}: \{result}")
      }
      let stubs = "/v1/mocks/payments/stubs"
      step(
        "test-a adds",
        smock.call(
          "POST",
          stubs,
          session="test-a",
          body=(
            #|{ "request": { "method": "POST", "path": "/orders/42/pay" },
            #|  "scenario": { "name": "checkout", "requires": "Started", "moveTo": "Paid" },
            #|  "response": { "status": 202, "body": "accepted" } }
          ),
        ),
      )
      step(
        "test-a pays",
        smock.order("POST", "/orders/42/pay", session="test-a"),
      )
      step("test-a GET", smock.order("GET", "/orders/42", session="test-a"))
      step("test-b GET", smock.order("GET", "/orders/42", session="test-b"))
      step("test-a lists", smock.call("GET", stubs, session="test-a"))
      step(
        "test-a deletes eph-1",
        smock.call("DELETE", "\{stubs}/eph-1", session="test-a"),
      )
      step("test-a GET", smock.order("GET", "/orders/42", session="test-a"))
      step(
        "test-a adds a clause with neither requires nor moveTo",
        smock.call(
          "POST",
          stubs,
          session="test-a",
          body="{ \"scenario\": { \"name\": \"checkout\" }, \"response\": { \"status\": 200 } }",
        ),
      )
      inspect(
        out.join("\n"),
        content=(
          #|test-a adds: 201 {"stub":{"id":"eph-1","mock":"payments","session":"test-a","request":{"method":"POST","path":"/orders/42/pay"},"scenario":{"name":"checkout","requires":"Started","moveTo":"Paid"},"response":{"status":202,"body":"accepted"}},"warnings":[]}
          #|test-a pays: 202 accepted
          #|test-a GET: 200 {"status":"paid"}
          #|test-b GET: 200 {"status":"pending"}
          #|test-a lists: 200 {"stubs":[{"id":"eph-1","mock":"payments","session":"test-a","request":{"method":"POST","path":"/orders/42/pay"},"scenario":{"name":"checkout","requires":"Started","moveTo":"Paid"},"response":{"status":202,"body":"accepted"}}],"warnings":[]}
          #|test-a deletes eph-1: 200 {"id":"eph-1","warnings":[]}
          #|test-a GET: 200 {"status":"paid"}
          #|test-a adds a clause with neither requires nor moveTo: 400 {"error":"invalid_stub","message":"/scenario: must give requires, moveTo or both","warnings":[]}
        ),
      )
    })
  })
}

///|
/// A retry flow: `GET /orders/42` resets the connection twice, each time
/// moving the Scenario `retry` on, then answers 200.
let retry : String =
  #|{ "mocks": [{ "name": "orders" }],
  #|  "stubs": [
  #|    { "id": "reset-1", "mock": "orders",
  #|      "request": { "method": "GET", "path": "/orders/42" },
  #|      "scenario": { "name": "retry", "requires": "Started", "moveTo": "Reset once" },
  #|      "response": { "status": 200, "body": "never sent" },
  #|      "fault": { "connection": { "kind": "reset" } } },
  #|    { "id": "reset-2", "mock": "orders",
  #|      "request": { "method": "GET", "path": "/orders/42" },
  #|      "scenario": { "name": "retry", "requires": "Reset once", "moveTo": "Reset twice" },
  #|      "response": { "status": 200, "body": "never sent" },
  #|      "fault": { "connection": { "kind": "reset" } } },
  #|    { "id": "ok", "mock": "orders",
  #|      "request": { "method": "GET", "path": "/orders/42" },
  #|      "scenario": { "name": "retry", "requires": "Reset twice" },
  #|      "response": { "status": 200, "body": "ok" } } ] }

///|
async test "a real HTTP client that retries sees two connection resets, then 200: each reset moves the Scenario on" {
  with_definitions([("orders.json", retry)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      for attempt in 1..<=4 {
        let result = smock.order("GET", "/orders/42") catch {
          @os_error.OSError(_, ..) as err if is_reset(err) =>
            "the connection was reset"
          err => "error: \{err}"
        }
        out.push("attempt \{attempt}: \{result}")
      }
      inspect(
        out.join("\n"),
        content=(
          #|attempt 1: the connection was reset
          #|attempt 2: the connection was reset
          #|attempt 3: 200 ok
          #|attempt 4: 200 ok
        ),
      )
    })
  })
}
