///|
/// The engine decides the response to each request from the current
/// snapshot. It does no I/O: the caller gives it the request, the Session
/// key, the time and a random source, and carries out the plan it returns.
pub struct Engine {
  /// The snapshot served. A reload replaces it whole, between two calls.
  priv mut snapshot : @definitions.Snapshot
  /// The generators of the Stubs of the snapshot that have a seed, by Stub
  /// ID. A reload that swaps the snapshot creates them anew.
  priv mut generators : Map[String, @prng.Generator]
  /// Whether Stubs are found through the snapshot's match index, rather
  /// than by trying every Stub of the Mock in matching order.
  priv match_index : Bool
  /// The result of the last reload, if there was one.
  priv mut last_reload : ReloadResult?
  /// The Ephemeral Stubs, by Mock and Session.
  priv ephemeral : EphemeralStubs
  /// The state of each Scenario, by Mock and Session.
  priv scenarios : ScenarioStates
  /// The per-Session store: the Variables and the copies of Data buckets,
  /// by Mock and Session.
  priv store : SessionStore
  /// The bound on per-Session state: the count of what the Variables and
  /// the copies take, which `store` keeps up to date, and the writes it
  /// refused.
  priv state : StateBound
  /// The Journal: the entries committed, oldest first, within its bound.
  priv journal : Journal
  /// The environment variables templates may read, with the values read
  /// at startup: every reload and Ephemeral Stub is read with them.
  priv env : @template.Env
}

///|
/// A request as the engine sees it, whatever protocol carried it.
pub(all) struct Request {
  meth : String
  /// The request target as sent, such as `/users/1?x=y`.
  target : String
  /// The protocol version, as the Journal records it, such as `HTTP/1.1`.
  version : String
  /// The header fields in the order they were sent.
  headers : Array[(String, String)]
  body : Bytes
} derive(Debug)

///|
/// What the engine decided for one request.
pub(all) struct Outcome {
  /// Which Mock answered the request, if any.
  resolution : Resolution
  /// The response to send.
  plan : ResponsePlan
  /// The Journal entry for the request, uncommitted: the caller commits it.
  /// There is none when the Journal is off, globally or for the Mock that
  /// answered.
  journal : JournalEntry?
  /// The Near miss, when no Stub matched.
  near_miss : NearMiss?
  /// The Stub that matched, if any, and where it comes from.
  matched : MatchedStub?
  /// How the request moved a Scenario of the Mock that answered: the
  /// clause of the Stub that matched, with the state before and after.
  /// There is none when no Stub matched, or when the Stub has no clause.
  scenario : ScenarioMove?
} derive(Debug)

///|
/// The Stub that matched a request, by its ID, and where it comes from. A
/// Stub from a Definition file may have an ID that looks like one smock
/// assigns, so only this tells the two apart.
pub(all) enum MatchedStub {
  /// A Stub from a Definition file.
  FromFile(String)
  /// An Ephemeral Stub, added through the Admin API.
  Ephemeral(String)
} derive(Debug, Eq)

///|
/// Where the Stub comes from.
pub fn MatchedStub::source(self : MatchedStub) -> StubSource {
  match self {
    FromFile(_) => File
    Ephemeral(_) => Ephemeral
  }
}

///|
/// Where a Stub comes from: a Definition file, or the Admin API as an
/// Ephemeral Stub. The Journal and the Near miss record it, since a Stub
/// from a Definition file may have an ID that looks like one smock assigns.
pub(all) enum StubSource {
  File
  Ephemeral
} derive(Debug, Eq)

///|
/// The source's name, as the Admin API gives it: `file` or `ephemeral`.
pub fn StubSource::name(self : StubSource) -> String {
  match self {
    File => "file"
    Ephemeral => "ephemeral"
  }
}

///|
/// Which Mock answered a request, and how the engine chose it.
pub(all) enum Resolution {
  /// The Mock whose Hosts include the request's Host.
  ByHost(String)
  /// The Default Mock, because no Mock lists the request's Host.
  ViaDefault(String)
  /// None: no Mock lists the request's Host and there is no Default Mock.
  NoMock
} derive(Debug, Eq)

///|
/// The response to send, and how to send it.
pub(all) struct ResponsePlan {
  status : Int
  headers : Array[(String, String)]
  body : Body
  /// How long to wait, in milliseconds, before writing the status line.
  delay_ms : Int
  /// A connection Fault to inject instead of a normal response.
  fault : @definitions.ConnectionKind?
} derive(Debug)

///|
/// A response body: bytes sent at once, or a stream of Server-Sent Events,
/// each written after waiting its `delay_ms` milliseconds. The bytes may be
/// a view of a body file's bytes, such as the byte range a 206 sends.
pub(all) enum Body {
  Bytes(BytesView)
  Events(ReadOnlyArray[@definitions.SseEvent])
} derive(Debug)

///|
/// Creates an engine that serves `snapshot`. Each Stub with a seed gets its
/// own generator, created from its seed.
///
/// With `match_index=false`, the engine tries every Stub of the Mock in
/// matching order instead of finding them through the snapshot's match
/// index. The outcome is the same either way, only slower; tests use it as
/// the oracle the index is checked against.
///
/// `journal` bounds the Journal and says whether it is on.
///
/// `env` holds the environment variables templates may read, with the
/// values `snapshot` was loaded with: by default, none. Each reload and
/// each Ephemeral Stub is read with them, so they are read only once.
///
/// `state_max_bytes` bounds the per-Session state of the whole process, as
/// it counts it: by default, `default_state_max_bytes` (64 MiB).
pub fn Engine::Engine(
  snapshot : @definitions.Snapshot,
  match_index? : Bool = true,
  journal? : JournalSettings = JournalSettings(),
  env? : @template.Env = @template.no_env,
  state_max_bytes? : Int = default_state_max_bytes,
) -> Engine {
  let state = StateBound::new(state_max_bytes)
  {
    snapshot,
    generators: seeded_generators(snapshot),
    match_index,
    last_reload: None,
    ephemeral: EphemeralStubs::new(),
    scenarios: ScenarioStates::new(),
    store: SessionStore::new(state),
    state,
    journal: Journal::new(journal),
    env,
  }
}

///|
/// The engine's side of the Admin API status: what it serves.
pub(all) struct Status {
  /// The Mocks, in declaration order.
  mocks : Array[MockStatus]
  /// The definition set digest of the definition set served.
  digest : String
  /// The result of the last reload, or `None` before the first one.
  last_reload : ReloadResult?
} derive(Debug)

///|
/// A Mock as the Admin API status shows it.
pub(all) struct MockStatus {
  name : String
  /// The Hosts the Mock answers to, as declared.
  hosts : Array[String]
  /// Whether the Mock is the Default Mock.
  is_default : Bool
} derive(Debug)

///|
/// What the engine serves: the Mocks with their Hosts, and which one is the
/// Default Mock.
pub fn Engine::status(self : Engine) -> Status {
  let default_name = self.snapshot.default_mock().map(mock => mock.name)
  {
    mocks: self.snapshot.mocks
    .iter()
    .map(mock => MockStatus::{
      name: mock.name,
      hosts: mock.hosts.iter().collect(),
      is_default: default_name == Some(mock.name),
    })
    .collect(),
    digest: self.snapshot.digest,
    last_reload: self.last_reload,
  }
}

///|
/// The name of the Mock whose Hosts include `host`, compared as Host
/// resolution compares Hosts: case-insensitively, without a port and
/// without a trailing dot. `None` when no Mock lists it, even when there is
/// a Default Mock. It answers from the snapshot served, so it follows each
/// reload; the TLS port asks it which Mock an SNI name belongs to.
pub fn Engine::mock_for_host(self : Engine, host : String) -> String? {
  self.snapshot
  .mock_for_host(@definitions.normalize_host(host))
  .map(mock => mock.name)
}

///|
/// What a reload did.
pub(all) struct ReloadResult {
  /// When the reload finished, in milliseconds since the Unix epoch.
  at : Int64
  result : ReloadOutcome
  /// The digest of the definition set served before the reload.
  old_digest : String
  /// The digest of the definition set served after it: the new set's when
  /// it was swapped in, otherwise `old_digest`.
  new_digest : String
  /// Every problem in the new set when it was invalid, as
  /// `@definitions.load` gives them; otherwise none.
  errors : Array[@definitions.Diagnostic]
  /// How many Scenario states the reload sent back to `Started`: the stored
  /// states that are no longer known states of their Mock, Session and
  /// Scenario once the new set is swapped in. The states of a Mock that is
  /// gone are dropped with it, and are not counted. It is 0 when nothing
  /// was swapped.
  scenario_states_reset : Int
  /// How many copies of Data buckets the reload dropped, so that their
  /// buckets read their initial values again: those of a Mock that is
  /// gone, and those of a bucket that the new set no longer declares, or
  /// whose initial value or `key` it changed. It is 0 when nothing was
  /// swapped.
  data_buckets_reset : Int
} derive(Debug)

///|
/// How a reload ended.
pub(all) enum ReloadOutcome {
  /// The new set was valid and is served now.
  Swapped
  /// The new set has the digest of the one served, so nothing was swapped.
  Unchanged
  /// The new set was invalid, and the one served before still is.
  Failed
} derive(Debug, Eq)

///|
/// Every way a reload can end.
pub fn ReloadOutcome::all() -> Array[ReloadOutcome] {
  [Swapped, Unchanged, Failed]
}

///|
/// The outcome's name, as the Admin API, the logs and the reload metric
/// give it: `swapped`, `unchanged` or `failed`.
pub fn ReloadOutcome::name(self : ReloadOutcome) -> String {
  match self {
    Swapped => "swapped"
    Unchanged => "unchanged"
    Failed => "failed"
  }
}

///|
/// Reloads the definitions from `set`, read with the problems
/// `read_problems`, at the time `at` (milliseconds since the Unix epoch).
/// Templates read the environment variables the engine was created with.
/// Every file is validated and a whole new snapshot is built:
///
/// - When it is valid and its digest differs from the served one, it
///   replaces the served snapshot at once, and each Stub with a seed gets a
///   new generator, created from its seed. Plans the engine returned before
///   stay as they were: they hold their own bytes. Ephemeral Stubs stay,
///   generators included, except those of a Mock the new set does not
///   declare, which are dropped. Then each Scenario state stays while its
///   name is one of the known states of its Mock, Session and Scenario;
///   any other goes back to `Started`, and the states of a Mock that is
///   gone are dropped. Variables and the copies of Data buckets stay,
///   except those of a Mock that is gone, which are dropped. So are the
///   copies of a bucket that the new set no longer declares, or whose
///   initial value or `key` it changed (`bucket_changed`).
/// - When it is valid with the digest served, nothing is swapped.
/// - When it is invalid, the served snapshot stays.
///
/// Status shows the result as the last reload.
pub fn Engine::reload(
  self : Engine,
  set : @definitions.DefinitionSet,
  read_problems? : Array[@definitions.Diagnostic] = [],
  at~ : Int64,
) -> ReloadResult {
  let old_snapshot = self.snapshot
  let old_digest = old_snapshot.digest
  let mut scenario_states_reset = 0
  let mut data_buckets_reset = 0
  let (result, errors) : (ReloadOutcome, Array[@definitions.Diagnostic]) = match
    @definitions.load(set, read_problems~, env=self.env) {
    Ok(snapshot) if snapshot.digest == old_digest => (Unchanged, [])
    Ok(snapshot) => {
      self.snapshot = snapshot
      self.generators = seeded_generators(snapshot)
      // Ephemeral Stubs stay, except those of the Mocks that are gone.
      let mocks = Map::from_iter(
        snapshot.mocks.iter().map(mock => (mock.name, mock)),
      )
      self.ephemeral.remove_where((mock, _) => !mocks.contains(mock)) |> ignore
      // Only then are Scenario states checked, since the known states
      // include those of the Ephemeral Stubs that stay.
      scenario_states_reset = self.prune_scenario_states(mocks)
      // Variables and copies stay, except those of the Mocks that are gone.
      let cleared = self.store.remove_where((mock, _) => !mocks.contains(mock))
      // Then the copies of the buckets the new set changed are dropped.
      let old_mocks = Map::from_iter(
        old_snapshot.mocks.iter().map(mock => (mock.name, mock)),
      )
      data_buckets_reset = cleared.copies +
        self.store.drop_copies_where((mock, bucket) => {
          bucket_changed(old_mocks.get(mock), mocks.get(mock), bucket)
        })
      (Swapped, [])
    }
    Err(errors) => (Failed, errors)
  }
  let reload = {
    at,
    result,
    old_digest,
    new_digest: self.snapshot.digest,
    errors,
    scenario_states_reset,
    data_buckets_reset,
  }
  self.last_reload = Some(reload)
  reload
}

///|
/// Decides the response to `request`.
///
/// - `session` is the request's Session key, or `None` without a Session.
/// - `now` is the time the request was received, in milliseconds since the
///   Unix epoch.
/// - `rand` is the process generator. Fault decisions for Stubs without a
///   seed draw from it.
pub fn Engine::handle(
  self : Engine,
  request : Request,
  session~ : String?,
  now~ : Int64,
  rand~ : @prng.Generator,
) -> Outcome {
  // Every request comes here, so it is written with plain matches and
  // loops, which allocate no closures, iterators or tuples.
  let host = host_of(request)
  let by_host = match host {
    Some(host) => self.snapshot.mock_for_host(host)
    None => None
  }
  let mut resolution : Resolution = NoMock
  let mut mock : @definitions.Mock? = None
  match by_host {
    Some(found) => {
      resolution = ByHost(found.name)
      mock = Some(found)
    }
    None =>
      if self.snapshot.default_mock() is Some(found) {
        resolution = ViaDefault(found.name)
        mock = Some(found)
      }
  }
  let incoming = Incoming::new(request)
  // The Ephemeral Stubs of the Mock and the Session come first, in their
  // own order, then the Stubs from Definition files. The match index only
  // narrows the search among the latter. The Near miss of a request that
  // matched nothing is chosen among every candidate, in that order.
  let ephemeral = match mock {
    Some(mock) => self.ephemeral.of(mock.name, session)
    None => None
  }
  // A Stub with a Scenario clause matches only in the state it requires,
  // checked once its request conditions hold. The Session's states for the
  // Mock are looked up at most once, and only when a Stub has a clause.
  let mut states : Map[String, String]? = None
  let mut states_known = false
  let mut matched : Match? = None
  if ephemeral is Some(list) {
    for i in 0..<list.length() {
      let e = list[i]
      match e.stub.serves {
        Ordinary(ordinary) =>
          if incoming.meets(ordinary.request) {
            if ordinary.scenario is Some(_) && !states_known {
              states = self.scenarios.of(e.mock, session)
              states_known = true
            }
            if scenario_allows(ordinary.scenario, states) {
              matched = Some({
                stub: e.stub,
                generator: e.generator,
                source: Ephemeral(e.id),
              })
              break
            }
          }
      }
    }
  }
  if matched is None && mock is Some(mock) {
    // A Mock without a Stub with a clause pays only this test.
    let gated = mock.has_scenarios()
    if gated && !states_known {
      states = self.scenarios.of(mock.name, session)
      states_known = true
    }
    let current = states
    let found = if self.match_index {
      if gated {
        mock.first_candidate(request.meth, incoming.path, stub => {
          incoming.matches(stub, current)
        })
      } else {
        mock.first_candidate(request.meth, incoming.path, stub => {
          incoming.matches_ungated(stub)
        })
      }
    } else {
      let stubs = mock.stubs
      let mut found = None
      for i in 0..<stubs.length() {
        if incoming.matches(stubs[i], current) {
          found = Some(stubs[i])
          break
        }
      }
      found
    }
    if found is Some(stub) {
      matched = Some({
        stub,
        // Only Stubs with a seed have a generator of their own.
        generator: if self.generators.is_empty() {
          None
        } else {
          self.generators.get(stub.id)
        },
        source: FromFile(stub.id),
      })
    }
  }
  let mut scenario : ScenarioMove? = None
  let mut response_index = None
  let mut variables_written = none_written
  let mut data_written = no_buckets_written
  let mut data_error = None
  let mut template_error = None
  let mut near_miss = None
  let plan : ResponsePlan = match matched {
    // The match decision: one sequence of steps, each taken in turn, which
    // depend on what the Stub serves. A step that a Stub does not use costs
    // it one test at most.
    Some({ stub, generator, .. }) =>
      match stub.serves {
        Ordinary(ordinary) => {
          // 1. The Scenario moves, before the response is built: whatever
          //    happens to the response, a delay, a connection Fault or a
          //    template error, the state has moved, and the next request
          //    sees it. It is the state of the Mock that answered.
          if ordinary.scenario is Some(clause) {
            if !states_known {
              states = self.scenarios.of(stub.mock, session)
            }
            let from = current_state(states, clause.name)
            let to = match clause.move_to {
              Some(to) => to
              None => from
            }
            if to != from {
              self.scenarios.set(stub.mock, session, clause.name, to)
            }
            scenario = Some({ name: clause.name, from, to, })
          }
          // 2. The one draw. Every matched request takes exactly one output
          //    from its Stub's source, whatever it then draws: the Fault
          //    decisions draw from a generator seeded with it, the pick from
          //    one of its own, and the helpers from the request's helper
          //    generator, made from it once something is rendered.
          let draw = generator.unwrap_or(rand).uint64()
          // Templates read the Data buckets of the Mock that answered: the
          // copy of each that the Session holds, or else its initial value.
          // The values of `variables` and `dataWrites` look the copies up,
          // and a response only when one of its templates reads `data`.
          let data = match mock {
            Some(mock) => mock.initial_data
            None => no_data
          }
          // 3. The writes: the value of each Variable is rendered, in the
          //    order written, then the value of each data write, all
          //    against the state from before the request, drawing from the
          //    helper generator first; the data writes are applied in
          //    order to working copies; and all is stored at once, if it
          //    fits within the bound on per-Session state. The response
          //    renders on from there, and sees the state after the writes.
          //    A value that fails to render, a data write that cannot be
          //    applied, or writes that do not fit, write nothing, and no
          //    response is picked: the request gets the template failure,
          //    the data write failure, or 507.
          let mut context : @template.Context? = None
          let mut failed : ResponsePlan? = None
          if ordinary.writes_variables() || ordinary.writes_data() {
            let first = first_context(
              incoming,
              now~,
              draw~,
              vars=self.store.variables_of(stub.mock, session),
              data~,
              copies=self.store.copy_values(stub.mock, session),
            )
            let buckets = match mock {
              Some(mock) => mock.buckets
              None => no_buckets
            }
            try
              self.write_state(stub.mock, buckets, ordinary, session, first)
            catch {
              ValueFailed(error) => {
                template_error = Some(error)
                failed = Some(template_failed(stub.id, error))
              }
              ApplyFailed(error) => {
                data_error = Some(error)
                failed = Some(data_write_failed(stub.id, error))
              }
              StateLimitReached(message) =>
                failed = Some(state_limit_reached(stub.id, message))
            } noraise {
              written => {
                context = Some(written.context)
                variables_written = ordinary.variables.names
                data_written = written.buckets
              }
            }
          }
          let plan = match failed {
            Some(plan) => plan
            None => {
              // 4. The pick: the response the request gets. A Stub with
              //    `response` has one, and draws nothing more.
              response_index = pick_response(ordinary, draw)
              let response = ordinary.responses[response_index.unwrap_or(0)].response
              // 5. Rendering and planning: the response as written, or
              //    rendered from its templates. One that serves byte ranges
              //    answers the request's Range field. Only a response that
              //    reads Variables, and does not continue from their values,
              //    looks them up.
              plan_response(
                response,
                incoming,
                context,
                now~,
                draw~,
                vars=if context is None && response.reads_variables {
                  self.store.variables_of(stub.mock, session)
                } else {
                  None
                },
                data~,
                copies=if context is None && response.reads_data {
                  self.store.copy_values(stub.mock, session)
                } else {
                  None
                },
              ) catch {
                RenderError(at~, message~) => {
                  let error = TemplateError::{ at, message, }
                  template_error = Some(error)
                  template_failed(stub.id, error)
                }
              }
            }
          }
          // 6. Faults: a plan comes without a delay or a Fault, and gets the
          //    Stub's.
          with_faults(plan, stub, draw)
        }
      }
    None =>
      match mock {
        None => no_mock(host, self.snapshot.hosts())
        Some(mock) => {
          // Only now, when every candidate has failed, are conditions
          // counted. A state that a Stub requires counts too. The states
          // are already known when the Mock's file Stubs have a clause, or
          // when an Ephemeral Stub with one met the request; otherwise they
          // are looked up only if an Ephemeral Stub has a clause.
          if !states_known && ephemeral is Some(list) {
            for i in 0..<list.length() {
              let has_clause = match list[i].stub.serves {
                Ordinary(ordinary) => ordinary.scenario is Some(_)
              }
              if has_clause {
                states = self.scenarios.of(mock.name, session)
                break
              }
            }
          }
          let ephemeral = match ephemeral {
            Some(list) => list.iter().map(e => (e.stub, StubSource::Ephemeral))
            None => Iter::empty()
          }
          near_miss = incoming.near_miss(
            ephemeral.concat(
              mock.stubs.iter().map(stub => (stub, StubSource::File)),
            ),
            states,
          )
          no_match(mock, near_miss)
        }
      }
  }
  // A mistyped Host must not silently succeed.
  if resolution is ViaDefault(name) {
    plan.headers.push(("Smock-Mock", "\{header_safe(name)}; via=default"))
  }
  let source = match matched {
    Some(matched) => Some(matched.source)
    None => None
  }
  let journal = if self.journal.records(mock) {
    Some(
      self.journal.entry(
        request,
        session~,
        host~,
        resolution~,
        matched=source,
        scenario~,
        response_index~,
        variables_written~,
        data_written~,
        data_error~,
        near_miss~,
        plan~,
        template_error~,
        digest=self.snapshot.digest,
        now~,
      ),
    )
  } else {
    None
  }
  { resolution, plan, journal, near_miss, matched: source, scenario, }
}

///|
/// The values of no Data bucket. A matched Stub always has the Mock that
/// answered, so this only stands in for its buckets' values. It is never
/// changed.
let no_data : Map[String, Json] = Map([])

///|
/// The Data buckets of no Mock. A matched Stub always has the Mock that
/// answered, so this only stands in for its buckets.
let no_buckets : ReadOnlyArray[@definitions.DataBucket] = []

///|
/// The Stub that matched a request, with the generator its Fault decisions
/// draw from when it has a seed, and where it comes from.
priv struct Match {
  stub : @definitions.Stub
  /// Its own generator, when it has a seed.
  generator : @prng.Generator?
  source : MatchedStub
}

///|
/// Whether the request matches `stub` in the current states, `states`: it
/// meets the Stub's request conditions, and the Stub's Scenario clause, if
/// any, allows those states.
fn Incoming::matches(
  self : Incoming,
  stub : @definitions.Stub,
  states : Map[String, String]?,
) -> Bool {
  match stub.serves {
    Ordinary(ordinary) =>
      self.meets(ordinary.request) && scenario_allows(ordinary.scenario, states)
  }
}

///|
/// Whether the request matches `stub`, a file Stub of a Mock whose file
/// Stubs have no Scenario clause: as `matches` says, without the test of
/// a clause.
fn Incoming::matches_ungated(self : Incoming, stub : @definitions.Stub) -> Bool {
  match stub.serves {
    Ordinary(ordinary) => self.meets(ordinary.request)
  }
}

///|
/// The plan of one of a Stub's responses, as written. Server-Sent Events
/// are always sent with `Content-Type: text/event-stream`, which replaces a
/// Content-Type the Stub gives.
fn stub_response(response : @definitions.Response) -> ResponsePlan {
  // Room for the Smock-Mock field the Default Mock adds.
  let headers = Array(capacity=response.headers.length() + 2)
  let body : Body = match response.body {
    Bytes(bytes) => {
      for i in 0..<response.headers.length() {
        headers.push(response.headers[i])
      }
      Bytes(bytes)
    }
    Events(events) => {
      headers.push(("Content-Type", "text/event-stream"))
      for i in 0..<response.headers.length() {
        let header = response.headers[i]
        if header.0.to_lower() != "content-type" {
          headers.push(header)
        }
      }
      Events(events)
    }
  }
  { status: response.status, headers, body, delay_ms: 0, fault: None, }
}

///|
/// The response of `mock` when no Stub matches: its `noMatch.headers` after
/// smock's Content-Type, and the Near miss, if any, in the
/// `Smock-Near-Miss` header.
fn no_match(mock : @definitions.Mock, near_miss : NearMiss?) -> ResponsePlan {
  let given = mock.no_match_headers
  // Room for the Near miss and the Smock-Mock field the Default Mock adds.
  let headers = Array(capacity=given.length() + 3)
  headers.push(("Content-Type", "application/json"))
  for i in 0..<given.length() {
    headers.push(given[i])
  }
  if near_miss is Some(near_miss) {
    headers.push(("Smock-Near-Miss", near_miss.header_value()))
  }
  {
    status: mock.no_match_status,
    headers,
    body: Bytes(b"{\"error\":\"no Stub matched\"}"),
    delay_ms: 0,
    fault: None,
  }
}

///|
/// The response to a request whose Host, normalised as `host`, no Mock
/// lists, when there is no Default Mock: 404 with the Hosts the Mocks
/// declare, `hosts`, normalised.
fn no_mock(host : String?, hosts : Array[String]) -> ResponsePlan {
  let body : Json = {
    "error": "no Mock for this Host",
    "host": host.map_or(Json::null(), host => Json::string(host)),
    "acceptedHosts": Json::array(hosts.map(host => Json::string(host))),
  }
  {
    status: 404,
    headers: [("Content-Type", "application/json")],
    body: Bytes(@utf8.encode(body.stringify())),
    delay_ms: 0,
    fault: None,
  }
}

///|
/// `text` as it can be written in a header value, ASCII only: the
/// characters of an HTTP token stay as they are, except `%`, and every
/// other byte of its UTF-8 encoding is percent-encoded. A name, such as a
/// Mock name, can be any text, so this keeps a name such as `a\r\nb` or
/// `a; via=x` from changing the response or the header's meaning.
pub fn header_safe(text : String) -> String {
  if @http1.is_token(text) && !text.contains_char('%') {
    return text
  }
  let out = StringBuilder()
  for byte in @utf8.encode(text) {
    let c = byte.to_int().unsafe_to_char()
    if c != '%' && @http1.is_token(c.to_string()) {
      out.write_char(c)
    } else {
      out.write_string("%")
      out.write_string(
        byte.to_int().to_string(radix=16).to_upper().pad_start(2, '0'),
      )
    }
  }
  out.to_string()
}

///|
/// The request's Host, normalised: the authority of an absolute-form
/// target, or else the `Host` header field. A request has none without
/// either, or when it is empty.
fn host_of(request : Request) -> String? {
  let raw = match authority_of(request.target) {
    Some(authority) => authority
    None => {
      let headers = request.headers
      let mut host = ""
      for i in 0..<headers.length() {
        if is_name(headers[i].0, "host") {
          host = headers[i].1
          break
        }
      }
      host
    }
  }
  match @definitions.normalize_host(raw) {
    "" => None
    host => Some(host)
  }
}

///|
/// The authority of an absolute-form request target, such as
/// `users.example.com:8080` in `http://users.example.com:8080/users/1`,
/// without any user information. Other targets have none.
fn authority_of(target : String) -> String? {
  guard scheme_end(target) is Some(end) else { return None }
  let rest = target[end + 3:]
  let authority = match rest.find_by(c => c is ('/' | '?' | '#')) {
    Some(i) => rest[:i]
    None => rest
  }
  let authority = match authority.rev_find("@") {
    Some(i) => authority[i + 1:]
    None => authority
  }
  Some(authority.to_owned())
}

///|
/// Where the scheme of an absolute-form target ends: the index of its
/// `://`.
fn scheme_end(target : String) -> Int? {
  guard target.find("://") is Some(end) && end > 0 else { return None }
  for i, c in target[:end] {
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (i > 0 && ((c >= '0' && c <= '9') || c is ('+' | '-' | '.')))
    if !ok {
      return None
    }
  }
  Some(end)
}

///|
/// The path of a request target: everything before the query, after the
/// scheme and authority of an absolute-form target, where an empty path is
/// `/`.
fn path_of(target : String) -> String {
  let target = match scheme_end(target) {
    Some(end) => {
      let rest = target[end + 3:]
      match rest.find_by(c => c is ('/' | '?' | '#')) {
        Some(i) => rest[i:]
        None => ""
      }
    }
    None => target[:]
  }
  let path = match target.find("?") {
    Some(i) => target[:i]
    None => target
  }
  if path == "" {
    "/"
  } else {
    path.to_owned()
  }
}
