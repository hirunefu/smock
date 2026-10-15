// Seam 1 tests of Fault decisions: delays drawn from distributions,
// connection Faults, their probabilities, and replay from a seed.

///|
/// A Definition file with Mock `m` and `stubs`, each a JSON object.
fn faults_file(stubs : Array[String]) -> (String, String) {
  (
    "m.json",
    "{ \"mocks\": [{ \"name\": \"m\" }], \"stubs\": [\{stubs.join(", ")}] }",
  )
}

///|
/// A Stub of Mock `m` that answers `GET path` with 200 and `body`, and
/// injects `fault`, given as a JSON object.
fn fault_stub(path : String, fault : String, body? : String = "ok") -> String {
  "{ \"id\": \"\{path[1:]}\", \"mock\": \"m\", \"request\": { \"path\": \"\{path}\" }, \"response\": { \"status\": 200, \"body\": \"\{body}\" }, \"fault\": \{fault} }"
}

///|
/// The Fault decisions of `outcome`: the delay and the connection Fault.
fn decision(outcome : @engine.Outcome) -> String {
  let delay = outcome.plan.delay_ms
  match outcome.plan.fault {
    None => "delay \{delay}"
    Some(fault) => "delay \{delay}, \{@debug.to_string(fault)}"
  }
}

///|
/// The decisions for `n` requests for `GET path`, in order.
fn decisions(h : Harness, path : String, n : Int) -> Array[String] {
  Array::makei(n, _ => decision(h.send("GET", path)))
}

///|
test "a fixed delay applies to every matched request, before a normal response" {
  let h = harness([
    faults_file([
      fault_stub("/slow", "{ \"delay\": { \"fixed\": 250 } }"),
      fault_stub("/fast", "{}"),
    ]),
  ])
  inspect(
    describe(h.send("GET", "/slow")),
    content=(
      #|plan:
      #|  status: 200
      #|  header: Smock-Mock: m; via=default
      #|  body: "ok"
      #|  delay_ms: 250
      #|  fault: None
      #|journal:
      #|  session: None
      #|  host: None
      #|  mock: Some("m")
      #|  via_default: true
      #|  request: GET /slow HTTP/1.1
      #|  body: ""
      #|  stub: Some("slow")
      #|  status: Some(200)
      #|  fault: None
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
  inspect(
    [
      decisions(h, "/slow", 3),
      decisions(h, "/fast", 1),
      decisions(h, "/nothing", 1),
    ]
    .flatten()
    .join("\n"),
    content=(
      #|delay 250
      #|delay 250
      #|delay 250
      #|delay 0
      #|delay 0
    ),
  )
}

///|
/// How many of `n` requests for `GET path` get a delay, and how many a
/// connection Fault.
fn shares(h : Harness, path : String, n : Int) -> (Int, Int) {
  let mut delayed = 0
  let mut failed = 0
  for _ in 0..<n {
    let plan = h.send("GET", path).plan
    if plan.delay_ms > 0 {
      delayed += 1
    }
    if plan.fault is Some(_) {
      failed += 1
    }
  }
  (delayed, failed)
}

///|
/// Whether `count` of `n` draws is a plausible outcome for probability `p`:
/// within five standard deviations of `n * p`.
fn plausible(count : Int, n : Int, p : Double) -> Bool {
  let mean = n.to_double() * p
  let sd = (mean * (1.0 - p)).sqrt()
  (count.to_double() - mean).abs() <= 5.0 * sd
}

///|
test "a delay or a connection Fault with a probability applies to that share of matched requests" {
  let h = harness([
    faults_file([
      fault_stub(
        "/quarter",
        (
          #|{ "delay": { "fixed": 10, "probability": 0.25 },
          #|  "connection": { "kind": "close", "probability": 0.1 } }
        ),
      ),
      fault_stub(
        "/never",
        (
          #|{ "delay": { "fixed": 10, "probability": 0 },
          #|  "connection": { "kind": "partial", "probability": 0 } }
        ),
      ),
      fault_stub(
        "/always",
        (
          #|{ "delay": { "fixed": 10, "probability": 1 },
          #|  "connection": { "kind": "partial", "probability": 1 } }
        ),
      ),
      fault_stub(
        "/default",
        (
          #|{ "delay": { "fixed": 10 }, "connection": { "kind": "close" } }
        ),
      ),
    ]),
  ])
  let n = 4000
  let (delayed, failed) = shares(h, "/quarter", n)
  inspect(
    [
      "quarter: delays plausible for 0.25: \{plausible(delayed, n, 0.25)}, closes plausible for 0.1: \{plausible(failed, n, 0.1)}",
      "never: \{@debug.to_string(shares(h, "/never", 1000))}",
      "always: \{@debug.to_string(shares(h, "/always", 1000))}",
      "without probability: \{@debug.to_string(shares(h, "/default", 1000))}",
    ].join("\n"),
    content=(
      #|quarter: delays plausible for 0.25: true, closes plausible for 0.1: true
      #|never: (0, 0)
      #|always: (1000, 1000)
      #|without probability: (1000, 1000)
    ),
  )
}

///|
/// The delays of `n` requests for `GET path`.
fn delays(h : Harness, path : String, n : Int) -> Array[Int] {
  Array::makei(n, _ => h.send("GET", path).plan.delay_ms)
}

///|
test "a uniform delay is a whole number of milliseconds from min to max, both included" {
  let h = harness([
    faults_file([
      fault_stub(
        "/narrow", "{ \"delay\": { \"uniform\": { \"min\": 50, \"max\": 53 } } }",
      ),
      fault_stub(
        "/wide", "{ \"delay\": { \"uniform\": { \"min\": 0, \"max\": 2147483647 } } }",
      ),
      fault_stub(
        "/one", "{ \"delay\": { \"uniform\": { \"min\": 7, \"max\": 7 } } }",
      ),
    ]),
  ])
  let narrow = delays(h, "/narrow", 400)
  let wide = delays(h, "/wide", 1000)
  let counts = [50, 51, 52, 53].map(ms => narrow.filter(d => d == ms).length())
  inspect(
    [
      "narrow: all from 50 to 53: \{narrow.iter().all(d => d >= 50 && d <= 53)}, each value drawn about a quarter of the time: \{counts.iter().all(c => plausible(c, 400, 0.25))}",
      "wide: all in range: \{wide.iter().all(d => d >= 0)}, half below the middle: \{plausible(wide.filter(d => d < 1073741824).length(), 1000, 0.5)}",
      "one: \{@debug.to_string(delays(h, "/one", 5))}",
    ].join("\n"),
    content=(
      #|narrow: all from 50 to 53: true, each value drawn about a quarter of the time: true
      #|wide: all in range: true, half below the middle: true
      #|one: [7, 7, 7, 7, 7]
    ),
  )
}

///|
test "a log-normal delay is a whole number of milliseconds around its median, with a long tail" {
  let h = harness([
    faults_file([
      fault_stub(
        "/tail", "{ \"delay\": { \"lognormal\": { \"median\": 100, \"sigma\": 1 } } }",
      ),
      fault_stub(
        "/flat", "{ \"delay\": { \"lognormal\": { \"median\": 80, \"sigma\": 0 } } }",
      ),
      fault_stub(
        "/zero", "{ \"delay\": { \"lognormal\": { \"median\": 0, \"sigma\": 1e300 } } }",
      ),
      fault_stub(
        "/huge", "{ \"delay\": { \"lognormal\": { \"median\": 1, \"sigma\": 1e300 } } }",
      ),
    ]),
  ])
  let n = 4000
  let tail = delays(h, "/tail", n)
  // For sigma 1, P(X > e * median) = P(Z > 1), about 0.1587, and
  // P(X > e^2 * median) = P(Z > 2), about 0.0228.
  inspect(
    [
      "tail: none negative: \{tail.iter().all(d => d >= 0)}",
      "half below the median: \{plausible(tail.filter(d => d < 100).length(), n, 0.5)}",
      "above e times the median as often as Z > 1: \{plausible(tail.filter(d => d > 272).length(), n, 0.1587)}",
      "above e^2 times the median as often as Z > 2: \{plausible(tail.filter(d => d > 739).length(), n, 0.0228)}",
      "sigma 0: \{@debug.to_string(delays(h, "/flat", 5))}",
      "median 0: \{@debug.to_string(delays(h, "/zero", 5))}",
      "within 0 and 2147483647: \{delays(h, "/huge", 200).iter().all(d => d == 0 || d == 2147483647)}",
    ].join("\n"),
    content=(
      #|tail: none negative: true
      #|half below the median: true
      #|above e times the median as often as Z > 1: true
      #|above e^2 times the median as often as Z > 2: true
      #|sigma 0: [80, 80, 80, 80, 80]
      #|median 0: [0, 0, 0, 0, 0]
      #|within 0 and 2147483647: true
    ),
  )
}

///|
test "a close or partial connection Fault is planned with the Stub's response and any delay" {
  let h = harness([
    faults_file([
      fault_stub(
        "/close", "{ \"connection\": { \"kind\": \"close\" }, \"delay\": { \"fixed\": 30 } }",
      ),
      fault_stub(
        "/partial",
        "{ \"connection\": { \"kind\": \"partial\" } }",
        body="0123456789",
      ),
    ]),
  ])
  inspect(
    response(h.send("GET", "/close")) +
    "\n" +
    decision(h.send("GET", "/close")) +
    "\n---\n" +
    response(h.send("GET", "/partial")) +
    "\n" +
    decision(h.send("GET", "/partial")),
    content=(
      #|200
      #|Smock-Mock: m; via=default
      #|ok
      #|delay 30, Close
      #|---
      #|200
      #|Smock-Mock: m; via=default
      #|0123456789
      #|delay 0, Partial
    ),
  )
}

///|
test "a reset connection Fault is planned instead of the response, after any delay, and its entry has no status" {
  let h = harness([
    faults_file([
      fault_stub(
        "/reset", "{ \"connection\": { \"kind\": \"reset\" }, \"delay\": { \"fixed\": 30 } }",
      ),
    ]),
  ])
  inspect(
    describe(h.send("GET", "/reset", body="ping")),
    content=(
      #|plan:
      #|  status: 200
      #|  header: Smock-Mock: m; via=default
      #|  body: "ok"
      #|  delay_ms: 30
      #|  fault: Some(Reset)
      #|journal:
      #|  session: None
      #|  host: None
      #|  mock: Some("m")
      #|  via_default: true
      #|  request: GET /reset HTTP/1.1
      #|  body: "ping"
      #|  stub: Some("reset")
      #|  status: None
      #|  fault: Some(Reset)
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
}

///|
/// What `outcome` does to its connection: `reset`, or the status of the
/// normal response, with its body.
fn reset_or_response(outcome : @engine.Outcome) -> String {
  match outcome.plan {
    { fault: Some(Reset), .. } => "reset"
    { fault: Some(fault), .. } => "unexpected \{@debug.to_string(fault)}"
    { fault: None, status, body: Bytes(body), .. } =>
      "\{status} \{@utf8.decode_lossy(body)}"
    { fault: None, status, .. } => "\{status} with events"
  }
}

///|
test "a seeded reset Fault with a probability resets the same requests in every run, and the others get the normal response" {
  let file = faults_file([
    fault_stub(
      "/flaky", "{ \"connection\": { \"kind\": \"reset\", \"probability\": 0.5 }, \"seed\": 2026 }",
    ),
    coin_flips("/other"),
  ])
  // Each harness is a run: a new engine, and a process generator seeded
  // differently. The second run's requests to another Stub do not change
  // which requests the seeded Stub resets.
  let first = harness([file], process_seed=1)
  let second = harness([file], process_seed=2)
  let run = (h : Harness, other : Int) => {
    Array::makei(12, i => {
      let _ = decisions(h, "/other", other * (i % 3))
      reset_or_response(h.send("GET", "/flaky"))
    })
  }
  let resets = run(first, 0)
  inspect(resets == run(second, 1), content="true")
  // The sequence of seed 2026 is pinned, on every target.
  inspect(
    resets.join("\n"),
    content=(
      #|200 ok
      #|reset
      #|reset
      #|200 ok
      #|reset
      #|reset
      #|200 ok
      #|200 ok
      #|reset
      #|reset
      #|reset
      #|reset
    ),
  )
}

///|
test "an events Stub with Faults plans its events with the delay and the connection Fault" {
  let h = harness([
    faults_file([
      (
        #|{ "id": "ticks", "mock": "m", "request": { "path": "/ticks" },
        #|  "response": { "status": 200,
        #|    "events": [{ "data": "one" }, { "delay": 10, "data": "two" }] },
        #|  "fault": { "delay": { "fixed": 30 },
        #|    "connection": { "kind": "partial" } } }
      ),
    ]),
  ])
  inspect(
    describe(h.send("GET", "/ticks")),
    content=(
      #|plan:
      #|  status: 200
      #|  header: Content-Type: text/event-stream
      #|  header: Smock-Mock: m; via=default
      #|  event: after 0 ms: event -, id -, data "one"
      #|  event: after 10 ms: event -, id -, data "two"
      #|  delay_ms: 30
      #|  fault: Some(Partial)
      #|journal:
      #|  session: None
      #|  host: None
      #|  mock: Some("m")
      #|  via_default: true
      #|  request: GET /ticks HTTP/1.1
      #|  body: ""
      #|  stub: Some("ticks")
      #|  status: Some(200)
      #|  fault: Some(Partial)
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
}

///|
/// A Stub at `path` whose every Fault decision is random: a uniform delay
/// with probability 0.5, and a close with probability 0.5.
fn coin_flips(path : String, seed? : Int) -> String {
  let seed = match seed {
    Some(seed) => ", \"seed\": \{seed}"
    None => ""
  }
  fault_stub(
    path,
    (
      #|{ "delay": { "uniform": { "min": 1, "max": 1000 }, "probability": 0.5 },
      #|  "connection": { "kind": "close", "probability": 0.5 }
    ) +
    seed +
    " }",
  )
}

///|
test "a seeded Stub replays the same Fault decisions in every run, whatever other Stubs do" {
  let file = faults_file([
    coin_flips("/seeded", seed=42),
    coin_flips("/other", seed=7),
    coin_flips("/unseeded"),
  ])
  // Each harness is a run: a new engine, and a process generator seeded
  // differently.
  let alone = harness([file], process_seed=1)
  let first = decisions(alone, "/seeded", 8)
  let mixed = harness([file], process_seed=2)
  let second = []
  for i in 0..<8 {
    let _ = decisions(mixed, "/other", i % 3)
    let _ = decisions(mixed, "/unseeded", 2)
    let _ = mixed.send("GET", "/nothing")
    second.append(decisions(mixed, "/seeded", 1))
  }
  inspect(first == second, content="true")
  // The decisions of seed 42 are pinned, on every target. Each request
  // splits a generator off the Stub's, then draws in turn: whether the
  // delay applies, its length (1 + the next output modulo 1000), and
  // whether the connection closes.
  inspect(
    first.join("\n"),
    content=(
      #|delay 0, Close
      #|delay 0
      #|delay 395
      #|delay 572
      #|delay 818
      #|delay 0, Close
      #|delay 594, Close
      #|delay 0
    ),
  )
}

///|
test "Stubs with different seeds draw different decisions" {
  let h = harness([
    faults_file([coin_flips("/a", seed=1), coin_flips("/b", seed=2)]),
  ])
  inspect(decisions(h, "/a", 16) == decisions(h, "/b", 16), content="false")
}

///|
test "without a seed, Fault decisions come from the process generator, so its seed replays them" {
  let file = faults_file([coin_flips("/a"), coin_flips("/b")])
  let run = (process_seed : UInt64) => {
    let h = harness([file], process_seed~)
    let out = []
    for _ in 0..<8 {
      out.append(decisions(h, "/a", 1))
      out.append(decisions(h, "/b", 1))
    }
    out
  }
  inspect(
    "same seed, same decisions: \{run(5) == run(5)}\nanother seed, other decisions: \{run(5) != run(6)}",
    content=(
      #|same seed, same decisions: true
      #|another seed, other decisions: true
    ),
  )
}

///|
/// `a` times `a`, minus `c`, as the log-normal sampler multiplies and adds.
fn product_minus(a : Double, c : Double) -> Double {
  a * a - c
}

///|
test "Fault arithmetic is never fused into multiply-adds, so a seeded delay is the same on every target" {
  // Read at run time, so that the compiler cannot fold them: 1 + 2^-30 and
  // 1 + 2^-29. Rounded to a Double, a * a is c, so a * a - c is 0; a fused
  // multiply-add would keep the 2^-60 the rounding drops, as an aarch64
  // release build does unless it is compiled with -ffp-contract=off.
  guard @json.parse(
      "[1.000000000931322574615478515625, 1.00000000186264514923095703125]",
    )
    is Array([Number(a, ..), Number(c, ..)]) else {
    fail("not two numbers")
  }
  inspect(product_minus(a, c), content="0")
}
