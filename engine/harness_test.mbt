///|
/// The Seam 1 harness: an engine built from an in-memory definition set,
/// with a fixed clock and a seeded random source.
struct Harness {
  engine : @engine.Engine
  rand : @random.Rand
  now : Int64
}

///|
/// 2026-10-12T14:30:05.123Z, the time every request in these tests carries.
let fixed_now : Int64 = 1_791_815_405_123L

///|
/// Builds an engine from Definition files given as (name, JSON text) pairs.
/// Fails the test if the set is invalid.
fn harness(files : Array[(String, String)]) -> Harness {
  let set : @definitions.DefinitionSet = {
    files: files.map(file => (file.0, @utf8.encode(file.1))),
    body_files: [],
  }
  match @definitions.load(set) {
    Ok(snapshot) =>
      {
        engine: @engine.Engine(snapshot),
        rand: @random.Rand::chacha8(seed=b"smock-seam-1-fixed-seed-32-bytes"),
        now: fixed_now,
      }
    Err(diagnostics) => abort(diagnostics.map(d => d.to_string()).join("\n"))
  }
}

///|
/// Sends a request without a Session and returns the engine's outcome.
fn Harness::send(
  self : Harness,
  meth : String,
  target : String,
  headers? : Array[(String, String)] = [],
  body? : String = "",
) -> @engine.Outcome {
  self.engine.handle(
    { meth, target, headers, body: @utf8.encode(body), },
    session=None,
    now=self.now,
    rand=self.rand,
  )
}

///|
/// The response plan of `outcome` as status, headers and body, one per line.
fn response(outcome : @engine.Outcome) -> String {
  let plan = outcome.plan
  let out = StringBuilder()
  out.write_string("\{plan.status}\n")
  for header in plan.headers {
    out.write_string("\{header.0}: \{header.1}\n")
  }
  match plan.body {
    Bytes(body) => out.write_string(@utf8.decode_lossy(body))
    Events(events) => out.write_string("(\{events.length()} events)")
  }
  out.to_string()
}

///|
/// Every part of `outcome`: the response plan, the Journal entry and the
/// Near miss, with bodies shown as text.
fn describe(outcome : @engine.Outcome) -> String {
  let plan = outcome.plan
  let journal = outcome.journal
  let out = StringBuilder()
  out.write_string("plan:\n")
  out.write_string("  status: \{plan.status}\n")
  for header in plan.headers {
    out.write_string("  header: \{header.0}: \{header.1}\n")
  }
  match plan.body {
    Bytes(body) => out.write_string("  body: \{text(body)}\n")
    Events(events) => out.write_string("  events: \{events.length()}\n")
  }
  out.write_string("  delay_ms: \{plan.delay_ms}\n")
  out.write_string("  fault: \{@debug.to_string(plan.fault)}\n")
  out.write_string("journal:\n")
  out.write_string("  session: \{@debug.to_string(journal.session)}\n")
  out.write_string("  mock: \{@debug.to_string(journal.mock)}\n")
  out.write_string("  request: \{journal.meth} \{journal.target}\n")
  for header in journal.headers {
    out.write_string("  header: \{header.0}: \{header.1}\n")
  }
  out.write_string("  body: \{text(journal.body)}\n")
  out.write_string("  stub: \{@debug.to_string(journal.stub)}\n")
  out.write_string("  status: \{journal.status}\n")
  out.write_string("  received_at: \{journal.received_at}\n")
  out.write_string("near_miss: \{@debug.to_string(outcome.near_miss)}")
  out.to_string()
}

///|
fn text(bytes : Bytes) -> String {
  @utf8.decode_lossy(bytes).escape()
}
