///|
/// The Seam 1 harness: an engine built from an in-memory definition set,
/// with a fixed clock and a seeded random source.
struct Harness {
  engine : @engine.Engine
  /// The process generator.
  rand : @prng.Generator
  /// The time requests are received at; a test may move it on.
  mut now : Int64
}

///|
/// 2026-10-12T14:30:05.123Z, the time every request in these tests carries.
let fixed_now : Int64 = 1_791_815_405_123L

///|
/// Builds an engine from Definition files given as (name, JSON text) pairs,
/// and body files as (name, bytes) pairs, with a process generator seeded
/// with `process_seed`, and the Journal settings `journal`. With
/// `match_index=false`, the engine tries every Stub in matching order, as
/// the oracle of the match index does. Templates may read the environment
/// variables `env`, by default none. Fails the test if the set is invalid.
fn harness(
  files : Array[(String, String)],
  body_files? : Array[(String, Bytes)] = [],
  process_seed? : UInt64 = 1,
  journal? : @engine.JournalSettings = @engine.JournalSettings(),
  match_index? : Bool = true,
  env? : @template.Env = @template.Env([]),
) -> Harness {
  let set : @definitions.DefinitionSet = {
    files: files.map(file => (file.0, @utf8.encode(file.1))),
    body_files,
  }
  match @definitions.load(set, env~) {
    Ok(snapshot) =>
      {
        engine: @engine.Engine(snapshot, journal~, match_index~, env~),
        rand: @prng.Generator(process_seed),
        now: fixed_now,
      }
    Err(diagnostics) => abort(diagnostics.map(d => d.to_string()).join("\n"))
  }
}

///|
/// The ID of the Stub that matched in `outcome`, from a Definition file or
/// an Ephemeral Stub, if any.
fn matched_id(outcome : @engine.Outcome) -> String? {
  match outcome.matched {
    Some(FromFile(id)) | Some(Ephemeral(id)) => Some(id)
    None => None
  }
}

///|
/// Sends a request, by default without a Session, and returns the
/// engine's outcome.
fn Harness::send(
  self : Harness,
  meth : String,
  target : String,
  headers? : Array[(String, String)] = [],
  body? : String = "",
  session? : String,
) -> @engine.Outcome {
  self.engine.handle(
    { meth, target, version: "HTTP/1.1", headers, body: @utf8.encode(body), },
    session~,
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
    Events(events) =>
      for event in events {
        out.write_string("\{sse_event(event)}\n")
      }
  }
  out.to_string()
}

///|
/// Every part of `outcome`: the response plan, the Journal entry and the
/// Near miss, with bodies shown as text.
fn describe(outcome : @engine.Outcome) -> String {
  let plan = outcome.plan
  let out = StringBuilder()
  out.write_string("plan:\n")
  out.write_string("  status: \{plan.status}\n")
  for header in plan.headers {
    out.write_string("  header: \{header.0}: \{header.1}\n")
  }
  match plan.body {
    Bytes(body) => out.write_string("  body: \{text(body)}\n")
    Events(events) =>
      for event in events {
        out.write_string("  event: \{sse_event(event)}\n")
      }
  }
  out.write_string("  delay_ms: \{plan.delay_ms}\n")
  out.write_string("  fault: \{@debug.to_string(plan.fault)}\n")
  match outcome.journal {
    None => out.write_string("journal: none\n")
    Some(journal) => {
      out.write_string("journal:\n")
      out.write_string("  session: \{@debug.to_string(journal.session)}\n")
      out.write_string("  host: \{@debug.to_string(journal.host)}\n")
      out.write_string("  mock: \{@debug.to_string(journal.mock)}\n")
      out.write_string("  via_default: \{journal.via_default}\n")
      out.write_string(
        "  request: \{journal.request.meth} \{journal.request.target} \{journal.request.version}\n",
      )
      for header in journal.request.headers {
        out.write_string("  header: \{header.0}: \{header.1}\n")
      }
      out.write_string("  body: \{text(journal.request.body)}\n")
      out.write_string("  stub: \{@debug.to_string(journal.stub)}\n")
      out.write_string("  status: \{@debug.to_string(journal.status)}\n")
      out.write_string("  fault: \{@debug.to_string(journal.fault)}\n")
      if journal.template_error is Some(error) {
        out.write_string(
          "  template_error: at \{error.at}: \{error.message.escape()}\n",
        )
      }
      out.write_string("  received_at: \{journal.received_at}\n")
    }
  }
  out.write_string("near_miss: \{@debug.to_string(outcome.near_miss)}")
  out.to_string()
}

///|
fn text(bytes : BytesView) -> String {
  @utf8.decode_lossy(bytes).escape()
}

///|
/// A Server-Sent Event of a response plan: its delay, then its type, ID
/// and data as given, with strings escaped.
fn sse_event(event : @definitions.SseEvent) -> String {
  let field = (value : String?) => value.map_or("-", value => value.escape())
  "after \{event.delay_ms} ms: event \{field(event.event)}, id \{field(event.id)}, data \{event.data.escape()}"
}
