// Seam 1 property test of the match index: for generated definition sets
// and requests, the engine that finds Stubs through the index gives the
// same outcome as the one that tries every Stub in matching order.
//
// Each case is generated from its own seed, derived from its number. A
// failure names the case; `check_index_case(<case>, IndexTally())` in a test
// of its own replays it.

///|
/// One engine that finds Stubs through the match index and one that tries
/// every Stub in matching order, serving the same snapshot.
struct Twins {
  indexed : @engine.Engine
  linear : @engine.Engine
}

///|
/// Builds both engines from Definition files given as (name, JSON text)
/// pairs. Fails if the set is invalid.
fn twins(files : Array[(String, String)]) -> Twins raise {
  let set : @definitions.DefinitionSet = {
    files: files.map(file => (file.0, @utf8.encode(file.1))),
    body_files: [],
  }
  match @definitions.load(set) {
    Ok(snapshot) =>
      {
        indexed: @engine.Engine(snapshot),
        linear: @engine.Engine(snapshot, match_index=false),
      }
    Err(diagnostics) => fail(diagnostics.map(d => d.to_string()).join("\n"))
  }
}

///|
/// Sends `request`, with `session`, by default none, to both engines, each with a random
/// source seeded the same way, and returns the outcome. Fails, showing both,
/// when the outcomes differ in any part: the response plan, the Journal
/// entry or the Near miss.
fn Twins::send(
  self : Twins,
  request : @engine.Request,
  session? : String? = None,
) -> @engine.Outcome raise {
  let indexed = self.indexed.handle(
    request,
    session~,
    now=fixed_now,
    rand=@prng.Generator(1),
  )
  let linear = self.linear.handle(
    request,
    session~,
    now=fixed_now,
    rand=@prng.Generator(1),
  )
  let (with_index, in_order) = (describe(indexed), describe(linear))
  if with_index != in_order {
    fail("with the index:\n\{with_index}\n\nin matching order:\n\{in_order}")
  }
  indexed
}

///|
/// How many definition sets the property test generates.
let index_cases : Int = 300

///|
/// How many requests each generated definition set is checked with.
let index_requests_per_case : Int = 40

///|
/// What the generated requests matched, to show that the property test
/// reaches every kind of Stub and requests that match nothing.
struct IndexTally {
  /// The number of requests per kind of Stub that answered them: `exact
  /// path`, `path pattern` or `no path` for a Stub from a Definition file,
  /// `ephemeral` for an Ephemeral Stub, or `no match`.
  counts : Map[String, Int]
}

///|
fn IndexTally::IndexTally() -> IndexTally {
  {
    counts: Map::from_array([
      ("exact path", 0),
      ("path pattern", 0),
      ("no path", 0),
      ("ephemeral", 0),
      ("no match", 0),
    ]),
  }
}

///|
fn IndexTally::to_string(self : IndexTally) -> String {
  self.counts.iter().map(entry => "\{entry.0}: \{entry.1}").join("\n")
}

///|
test "the match index picks the same Stub as the matching order, for generated definition sets, Ephemeral Stubs and requests" {
  let tally = IndexTally()
  for case in 0..<index_cases {
    check_index_case(case, tally)
  }
  inspect(
    tally.to_string(),
    content=(
      #|exact path: 999
      #|path pattern: 1404
      #|no path: 2152
      #|ephemeral: 542
      #|no match: 6903
    ),
  )
}

///|
/// Generates definition set number `case` and its requests from the seed
/// of `case`, adds the same generated Ephemeral Stubs to both engines,
/// drawn from a seed of their own, and checks every request against both
/// engines, adding what it matched to `tally`.
fn check_index_case(case : Int, tally : IndexTally) -> Unit raise {
  let rand = @random.Rand::chacha8(seed=index_case_seed(case))
  let generated = gen_definition_set(rand)
  let files = generated.files
  let twins = twins(files) catch {
    Failure(message) =>
      fail(
        "case \{case}: the generated set is invalid:\n\{message}\n\{show_files(files)}",
      )
    e => raise e
  }
  let sessions = @random.Rand::chacha8(seed=ephemeral_case_seed(case))
  let ephemeral = gen_ephemeral_stubs(sessions)
  for stub in ephemeral {
    let (mock, session, json) = stub
    let _ = twins.indexed.add_ephemeral_stub(mock~, session~, json)
    let _ = twins.linear.add_ephemeral_stub(mock~, session~, json)
  }
  let shown_files = show_files(files) +
    ephemeral
    .map(stub => {
      "\nEphemeral Stub of \{stub.0} for \{@debug.to_string(stub.1)}: \{stub.2.stringify()}"
    })
    .join("")
  for _ in 0..<index_requests_per_case {
    let request = gen_request(rand)
    let session = gen_session(sessions)
    let outcome = twins.send(request, session~) catch {
      Failure(message) =>
        fail(
          (
            $|case \{case}: the engines disagree on
            $|  \{request.meth} \{request.target}
            $|  headers: \{@debug.to_string(request.headers)}
            $|  body: \{text(request.body)}
            $|  session: \{@debug.to_string(session)}
            $|Definition files:
            $|\{shown_files}
            $|
            $|\{message}
          ),
        )
      e => raise e
    }
    let kind = match outcome.journal.stub {
      Some(id) if id.has_prefix("eph-") => "ephemeral"
      Some(id) => generated.kinds.get(id).unwrap_or("unknown Stub \{id}")
      None => "no match"
    }
    tally.counts[kind] = tally.counts.get(kind).unwrap_or(0) + 1
  }
}

///|
/// The 32-byte seed of case number `case`.
fn index_case_seed(case : Int) -> Bytes {
  let number = case.to_string().pad_start(5, '0')
  @utf8.encode("smock-match-index-property-\{number}")
}

///|
/// The 32-byte seed of the Ephemeral Stubs and Sessions of case number
/// `case`.
fn ephemeral_case_seed(case : Int) -> Bytes {
  let number = case.to_string().pad_start(5, '0')
  @utf8.encode("smock-match-index-sessions-\{number}")
}

///|
/// Definition files as (name, JSON text), one per line.
fn show_files(files : Array[(String, String)]) -> String {
  files.map(file => "\{file.0}: \{file.1}").join("\n")
}

///|
/// The Sessions of the generated requests and Ephemeral Stubs.
let generated_sessions : Array[String?] = [None, Some("s"), Some("t")]

///|
/// One of the Sessions, drawn from `rand`.
fn gen_session(rand : @random.Rand) -> String? {
  generated_sessions[rand.int(limit=generated_sessions.length())]
}

///|
/// Generates up to four Ephemeral Stubs, as (Mock, Session, Stub without
/// `id` and `mock`), in the order they are added.
fn gen_ephemeral_stubs(rand : @random.Rand) -> Array[(String, String?, Json)] {
  let out = []
  for i in 0..<rand.int(limit=5) {
    guard gen_stub(rand, "e\{i}").0 is Object(stub) else { continue }
    let mock = match stub.get("mock") {
      Some(String(mock)) => mock
      _ => "m"
    }
    let ephemeral = stub.copy()
    ephemeral.remove("id")
    ephemeral.remove("mock")
    out.push((mock, gen_session(rand), Json::object(ephemeral)))
  }
  out
}

///|
/// A generated definition set: its Definition files as (name, JSON text),
/// and the kind of path condition of each Stub, by Stub ID.
struct GeneratedSet {
  files : Array[(String, String)]
  kinds : Map[String, String]
}

///|
/// One of `choices`, drawn from `rand`.
fn pick(rand : @random.Rand, choices : Array[String]) -> String {
  choices[rand.int(limit=choices.length())]
}

///|
/// Whether a draw from `rand` that succeeds `percent` times in 100
/// succeeds.
fn chance(rand : @random.Rand, percent : Int) -> Bool {
  rand.int(limit=100) < percent
}

///|
/// Generates a definition set of two Mocks, `m`, the Default Mock, and
/// `o`, whose Stubs are spread over one to four files. The Stubs mix exact,
/// pattern and `json` conditions, some with a priority and some without,
/// and many share exact paths and priorities, so that ties are decided by
/// file-name order and position in the file.
fn gen_definition_set(rand : @random.Rand) -> GeneratedSet {
  let names = ["a.json", "B.json", "b.json", "aa.json", "10.json", "9.json"]
  rand.shuffle(names.length(), (i, j) => names.swap(i, j))
  let files = [
    (
      "mocks.json",
      (
        #|{ "mocks": [
        #|  { "name": "m", "hosts": ["m.test"], "default": true },
        #|  { "name": "o", "hosts": ["o.test"] } ] }
      ),
    ),
  ]
  let kinds = Map([])
  let mut next_id = 0
  for name in names[:1 + rand.int(limit=4)] {
    let stubs = []
    for _ in 0..<rand.int(limit=9) {
      let id = "s\{next_id}"
      next_id += 1
      let (stub, kind) = gen_stub(rand, id)
      stubs.push(stub)
      kinds[id] = kind
    }
    let file : Json = { "stubs": Json::array(stubs) }
    files.push((name, file.stringify()))
  }
  { files, kinds, }
}

///|
/// Generates the Stub `id` and the kind of its path condition: `exact
/// path`, `path pattern` or `no path`.
fn gen_stub(rand : @random.Rand, id : String) -> (Json, String) {
  let stub : Map[String, Json] = {
    "id": Json::string(id),
    "mock": Json::string(if chance(rand, 85) { "m" } else { "o" }),
    "response": { "status": 200, "body": Json::string(id) },
  }
  if chance(rand, 60) {
    stub["priority"] = Json::number(
      [-1, 0, 0, 1, 2][rand.int(limit=5)].to_double(),
    )
  }
  let request : Map[String, Json] = Map([])
  if chance(rand, 70) {
    request["method"] = Json::string(pick(rand, ["GET", "GET", "POST", "get"]))
  }
  let kind = match rand.int(limit=100) {
    n if n < 60 => {
      request["path"] = Json::string(
        pick(rand, ["/", "/a", "/a/b", "/A", "/a b", "/é", "/a/"]),
      )
      "exact path"
    }
    n if n < 85 => {
      request["path"] = gen_pattern(rand, [
        "/a.*", "/[aA]", ".*", "/a/[^/]+", "/(é|a b)",
      ])
      "path pattern"
    }
    _ => "no path"
  }
  if chance(rand, 25) {
    request["query"] = gen_value_conditions(
      rand,
      ["q", "tag"],
      ["1", "2", "a b"],
      ["[0-9]+", "a.*"],
    )
  }
  if chance(rand, 25) {
    request["headers"] = gen_value_conditions(
      rand,
      ["X-Id", "x-id", "Accept"],
      ["1", "2", "json"],
      ["[0-9]", "j.*"],
    )
  }
  if chance(rand, 25) {
    request["body"] = match rand.int(limit=3) {
      0 => Json::string(pick(rand, ["hi", "{\"k\":1}"]))
      1 => gen_pattern(rand, ["h.*", "\\{.*"])
      _ => {
        let values : Array[Json] = [
          { "k": 1 },
          { "k": [1, 2] },
          Json::empty_object(),
        ]
        { "json": values[rand.int(limit=values.length())] }
      }
    }
  }
  if request.length() > 0 {
    stub["request"] = Json::object(request)
  }
  (Json::object(stub), kind)
}

///|
/// A pattern condition with one of `patterns`.
fn gen_pattern(rand : @random.Rand, patterns : Array[String]) -> Json {
  { "pattern": Json::string(pick(rand, patterns)) }
}

///|
/// One or two query or header conditions, named from `names`, each exactly
/// one of `exact` or one of `patterns`.
fn gen_value_conditions(
  rand : @random.Rand,
  names : Array[String],
  exact : Array[String],
  patterns : Array[String],
) -> Json {
  let conditions : Map[String, Json] = Map([])
  for _ in 0..<(1 + rand.int(limit=2)) {
    conditions[pick(rand, names)] = if chance(rand, 70) {
      Json::string(pick(rand, exact))
    } else {
      gen_pattern(rand, patterns)
    }
  }
  Json::object(conditions)
}

///|
/// Generates a request to one of the Mocks, or to an unknown Host that the
/// Default Mock answers. Paths are written as clients send them, sometimes
/// percent-encoded, and some query parameters and headers are repeated.
fn gen_request(rand : @random.Rand) -> @engine.Request {
  let path = pick(rand, [
    "/", "/a", "/a", "/a/b", "/a/b", "/A", "/a%20b", "/%C3%A9", "/a/", "/a/c", "/b",
    "/a%2Fb", "", "http://o.test/a",
  ])
  let query = pick(rand, [
    "", "", "?q=1", "?tag=1&tag=2", "?tag=2&tag=1", "?q=a+b", "?q=a%20b&tag=1", "?q=12",
    "?q", "?tag=3&q=2",
  ])
  let headers = [
    ("Host", pick(rand, ["m.test", "o.test", "x.test", "M.TEST:8080"])),
  ]
  for _ in 0..<rand.int(limit=4) {
    headers.push(
      (
        pick(rand, ["X-Id", "x-id", "X-ID", "accept", "Accept"]),
        pick(rand, ["1", "2", "json", "x"]),
      ),
    )
  }
  let body = pick(rand, [
    "", "hi", "{\"k\":1}", "{\"k\":[1,2]}", "{\"k\": 1, \"z\": 0}", "[1]", "hello",
  ])
  {
    meth: pick(rand, ["GET", "GET", "GET", "POST", "PUT", "get"]),
    target: path + query,
    headers,
    body: @utf8.encode(body),
  }
}
