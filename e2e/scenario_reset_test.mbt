// Seam 2 tests of resets and Scenario state: each reset scope also clears
// the Scenario state in it, and the reset says how many states it cleared,
// in its response and in its log entry.

///|
async test "over the Admin API, each reset scope also clears Scenario state, and says how many states it cleared in its response and in its log entry" {
  with_definitions([("payments.json", checkout)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let step = (label : String, result : String) => {
        out.push("\{label}: \{result}")
      }
      let pay = "/orders/42/pay"
      let reset = "/v1/reset"
      let session = "{\"scope\":\"session\"}"
      ignore(smock.order("POST", pay, session="test-a"))
      ignore(smock.order("POST", pay, session="test-b"))
      ignore(smock.order("POST", pay))
      step(
        "reset test-a",
        smock.call("POST", reset, session="test-a", body=session),
      )
      step("test-a GET", smock.order("GET", "/orders/42", session="test-a"))
      step("test-b GET", smock.order("GET", "/orders/42", session="test-b"))
      step("no Session GET", smock.order("GET", "/orders/42"))
      step(
        "reset the no-Session space",
        smock.call("POST", reset, body=session),
      )
      step("no Session GET", smock.order("GET", "/orders/42"))
      step("test-a pays", smock.order("POST", pay, session="test-a"))
      step(
        "reset payments",
        smock.call(
          "POST",
          reset,
          body="{\"scope\":\"mock\",\"mock\":\"payments\"}",
        ),
      )
      step("test-a GET", smock.order("GET", "/orders/42", session="test-a"))
      step("test-b GET", smock.order("GET", "/orders/42", session="test-b"))
      step("test-b pays", smock.order("POST", pay, session="test-b"))
      step("reset all", smock.call("POST", reset, body="{\"scope\":\"all\"}"))
      step("test-b GET", smock.order("GET", "/orders/42", session="test-b"))
      step(
        "reset an unknown Mock",
        smock.call(
          "POST",
          reset,
          body="{\"scope\":\"mock\",\"mock\":\"orders\"}",
        ),
      )
      inspect(
        out.join("\n"),
        content=(
          #|reset test-a: 200 {"scope":"session","removed":{"ephemeralStubs":0,"journalEntries":1,"scenarioStates":1,"variables":0,"dataBuckets":0},"warnings":[]}
          #|test-a GET: 200 {"status":"pending"}
          #|test-b GET: 200 {"status":"paid"}
          #|no Session GET: 200 {"status":"paid"}
          #|reset the no-Session space: 200 {"scope":"session","removed":{"ephemeralStubs":0,"journalEntries":2,"scenarioStates":1,"variables":0,"dataBuckets":0},"warnings":[]}
          #|no Session GET: 200 {"status":"pending"}
          #|test-a pays: 200, no body
          #|reset payments: 200 {"scope":"mock","removed":{"ephemeralStubs":0,"journalEntries":5,"scenarioStates":2,"variables":0,"dataBuckets":0},"warnings":[]}
          #|test-a GET: 200 {"status":"pending"}
          #|test-b GET: 200 {"status":"pending"}
          #|test-b pays: 200, no body
          #|reset all: 200 {"scope":"all","removed":{"ephemeralStubs":0,"journalEntries":3,"scenarioStates":1,"variables":0,"dataBuckets":0},"warnings":[]}
          #|test-b GET: 200 {"status":"pending"}
          #|reset an unknown Mock: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
        ),
      )
    })
    inspect(
      log_entries(
        stopped.logs.filter(line => line.contains("\"msg\":\"reset\"")),
      ),
      content=(
        #|{"level":"info","msg":"reset","scope":"session","session":"test-a","removed":{"ephemeralStubs":0,"journalEntries":1,"scenarioStates":1,"variables":0,"dataBuckets":0}}
        #|{"level":"info","msg":"reset","scope":"session","session":null,"removed":{"ephemeralStubs":0,"journalEntries":2,"scenarioStates":1,"variables":0,"dataBuckets":0}}
        #|{"level":"info","msg":"reset","scope":"mock","mock":"payments","removed":{"ephemeralStubs":0,"journalEntries":5,"scenarioStates":2,"variables":0,"dataBuckets":0}}
        #|{"level":"info","msg":"reset","scope":"all","removed":{"ephemeralStubs":0,"journalEntries":3,"scenarioStates":1,"variables":0,"dataBuckets":0}}
      ),
    )
  })
}
