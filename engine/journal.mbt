// The Journal: the bounded record of the requests the engine has handled.
// It is one ring buffer per process, bounded by entry count and by bytes:
// when an entry would take it over either bound, the oldest entries are
// evicted, and the process counts them per Session. `handle` returns an
// uncommitted entry; the server commits it just before it writes the
// response's last bytes, so that a client that has the whole response finds
// its request in the Journal.

///|
/// The bounds of the Journal and whether it is on: process settings.
pub struct JournalSettings {
  /// Whether the engine records requests at all.
  enabled : Bool
  /// The most entries the Journal holds.
  max_entries : Int
  /// The most bytes its entries take, as each entry counts them: 256 for
  /// its fixed fields, two for each UTF-16 code unit of the text it holds
  /// (the request line, the header fields, the Session, Host, Mock and
  /// Stub names, the Scenario move and the Near miss), 32 for each value
  /// its Near miss keeps from a form or an XML body, and the bytes of its
  /// truncated body.
  max_bytes : Int
  /// The most bytes of a request body an entry keeps, and of the values its
  /// Near miss keeps from a form or an XML body, in total, each value
  /// counting 32 bytes more.
  body_limit : Int
} derive(Debug)

///|
/// Journal settings: on by default, with at most 10,000 entries and
/// 64 MiB, and request bodies truncated to 4 KiB.
pub fn JournalSettings::JournalSettings(
  enabled? : Bool = true,
  max_entries? : Int = 10_000,
  max_bytes? : Int = 64 * 1024 * 1024,
  body_limit? : Int = 4 * 1024,
) -> JournalSettings {
  { enabled, max_entries, max_bytes, body_limit, }
}

///|
/// One request the engine handled, and how it answered. Its JSON form is
/// the `JournalEntry` schema of the Admin API document.
pub struct JournalEntry {
  /// Its sequence number, which the Journal gives it when it is committed:
  /// 1 for the first entry the process commits, then one more for each
  /// entry after it, whatever its Session. The Journal holds its entries in
  /// this order, so a page can resume after the last entry of the one
  /// before. 0 until the entry is committed.
  priv mut seq : Int64
  /// When the request was received, in milliseconds since the Unix epoch.
  received_at : Int64
  /// How long the response took, in milliseconds, from the request being
  /// received to its last byte being written; `None` until the server
  /// finishes the entry.
  priv mut duration_ms : Int64?
  /// The request's Session, or `None` without one.
  session : String?
  /// The request's Host, normalised, or `None` without one.
  host : String?
  /// The Mock that answered, if any.
  mock : String?
  /// Whether the Default Mock answered because no Mock lists the Host.
  via_default : Bool
  /// The digest of the definition set that answered.
  digest : String
  /// The request as it was received, except that its body is only the
  /// first bytes, as many as the Journal keeps.
  request : Request
  /// The length of the whole body, in bytes.
  body_size : Int
  /// The ID of the Stub that matched, if any.
  stub : String?
  /// Where the Stub that matched comes from, if one did.
  stub_source : StubSource?
  /// How the Stub that matched moved its Scenario, when it has a clause.
  scenario : ScenarioMove?
  /// The index of the response the pick chose among the `responses` of the
  /// Stub that matched, counted from 0. `None` for a Stub with `response`,
  /// and when no Stub matched.
  response_index : Int?
  /// The Near miss, when no Stub matched and the Mock had candidates.
  near_miss : NearMiss?
  /// The response status, or `None` when a connection Fault ended the
  /// request before a status was written.
  status : Int?
  /// The connection Fault injected instead of the response, if any.
  fault : @definitions.ConnectionKind?
  /// Why the Stub's template could not be rendered, when it could not: the
  /// client then got a 500.
  template_error : TemplateError?
  /// The bytes the entry counts against the Journal's byte bound.
  priv size : Int
} derive(Debug)

///|
/// Fills in the timing of the entry: its response's last byte was written
/// at `at`, in milliseconds since the Unix epoch.
pub fn JournalEntry::finish(self : JournalEntry, at~ : Int64) -> Unit {
  let duration = at - self.received_at
  self.duration_ms = Some(if duration < 0L { 0L } else { duration })
}

///|
/// The Journal of one process.
priv struct Journal {
  settings : JournalSettings
  /// The entries, oldest first.
  entries : @deque.Deque[JournalEntry]
  /// The bytes the entries take, as they count them.
  mut bytes : Int
  /// How many entries the bound has evicted, per Session (`None` for the
  /// no-Session space), since that Session's last reset.
  evicted : Map[String?, Int]
  /// How many entries the bound has evicted since the process started.
  mut evictions : Int64
  /// The sequence number of the last entry committed, 0 before the first.
  mut last_seq : Int64
}

///|
fn Journal::new(settings : JournalSettings) -> Journal {
  {
    settings,
    entries: @deque.Deque([]),
    bytes: 0,
    evicted: Map([]),
    evictions: 0L,
    last_seq: 0L,
  }
}

///|
/// Whether the requests `mock` answers are recorded; `mock` is `None` for
/// a request no Mock answers.
fn Journal::records(self : Journal, mock : @definitions.Mock?) -> Bool {
  self.settings.enabled && mock.map_or(true, mock => mock.journal)
}

///|
/// The uncommitted entry of a request the engine answered with `plan`.
fn Journal::entry(
  self : Journal,
  request : Request,
  session~ : String?,
  host~ : String?,
  resolution~ : Resolution,
  matched~ : MatchedStub?,
  scenario~ : ScenarioMove?,
  response_index~ : Int?,
  near_miss~ : NearMiss?,
  plan~ : ResponsePlan,
  template_error~ : TemplateError?,
  digest~ : String,
  now~ : Int64,
) -> JournalEntry {
  // An entry is made for every request, so it is built with plain matches,
  // which allocate no closures or tuples.
  let limit = self.settings.body_limit
  let body = truncate(request.body, limit)
  let truncated = body.length() < request.body.length()
  // The Near miss is rebuilt only when it holds something to cut.
  let near_miss = match near_miss {
    Some(near_miss) if near_miss.needs_cut(truncated~, limit~) =>
      Some(near_miss.cut(body, truncated~, limit~))
    _ => near_miss
  }
  let mock = match resolution {
    ByHost(name) | ViaDefault(name) => Some(name)
    NoMock => None
  }
  let via_default = resolution is ViaDefault(_)
  let status = match plan.fault {
    Some(Close | Reset) => None
    _ => Some(plan.status)
  }
  let mut text = request.meth.length() +
    request.target.length() +
    request.version.length()
  for header in request.headers {
    text += header.0.length() + header.1.length()
  }
  let stub = match matched {
    Some(FromFile(id)) | Some(Ephemeral(id)) => Some(id)
    None => None
  }
  let stub_source = match matched {
    Some(matched) => Some(matched.source())
    None => None
  }
  text += text_length(session) +
    text_length(host) +
    text_length(mock) +
    text_length(stub)
  if template_error is Some(error) {
    text += error.at.length() + error.message.length()
  }
  if scenario is Some(moved) {
    text += moved.name.length() + moved.from.length() + moved.to.length()
  }
  let mut values = 0
  if near_miss is Some(near_miss) {
    text += near_miss.stub.length()
    for failed in near_miss.failed {
      for value in failed.actual {
        text += value.length()
      }
      if failed.condition is (Form(_) | Xml(_)) {
        values += failed.actual.length()
      }
      // A Scenario condition also shows the Scenario and the state the
      // Stub requires; the state it is in is its actual value.
      if failed is { condition: Scenario(name), expected: Exact(state), .. } {
        text += name.length() + state.length()
      }
    }
  }
  {
    seq: 0L,
    received_at: now,
    duration_ms: None,
    session,
    host,
    mock,
    via_default,
    digest,
    // The request itself when its body is whole: nothing changes it.
    request: if truncated {
      { ..request, body, }
    } else {
      request
    },
    body_size: request.body.length(),
    stub,
    stub_source,
    scenario,
    response_index,
    near_miss,
    status,
    fault: plan.fault,
    template_error,
    size: 256 + 2 * text + body.length() + value_overhead * values,
  }
}

///|
/// What each value taken from a form or an XML body costs an entry, besides
/// its text: towards the values it keeps, and towards the Journal's byte
/// bound. So even empty values add up.
let value_overhead : Int = 32

///|
/// How many bytes an entry keeps of a value taken from a form or an XML
/// body, `length` bytes of UTF-8, after values whose cost so far is `kept`,
/// with the body limit `limit`: all of them while they fit, as many as are
/// left when they do not, or -1, to leave the value out, once the values
/// have taken the whole limit. Each value kept costs its bytes and
/// `value_overhead` more. `needs_cut` and `cut` both follow this rule.
fn value_room(length : Int, kept~ : Int, limit~ : Int) -> Int {
  if kept >= limit {
    -1
  } else if length > limit - kept {
    limit - kept
  } else {
    length
  }
}

///|
/// Whether the Near miss holds something that an entry with the body limit
/// `limit` cuts, as `cut` says. `truncated` says whether the body is cut.
fn NearMiss::needs_cut(
  self : NearMiss,
  truncated~ : Bool,
  limit~ : Int,
) -> Bool {
  let mut kept = 0
  for i in 0..<self.failed.length() {
    let failed = self.failed[i]
    match failed.condition {
      Body => if truncated { return true }
      Form(_) | Xml(_) =>
        for j in 0..<failed.actual.length() {
          let length = utf8_length(failed.actual[j])
          if value_room(length, kept~, limit~) != length {
            return true
          }
          kept += length + value_overhead
        }
      _ => ()
    }
  }
  false
}

///|
/// The Near miss as an entry with the body limit `limit` keeps it: the
/// body's value is `body`, the body cut to the limit, when `truncated`; the
/// values taken from a form or an XML body are kept in order as
/// `value_room` says, the last one kept cut to what is left, and the others
/// are left out.
fn NearMiss::cut(
  self : NearMiss,
  body : Bytes,
  truncated~ : Bool,
  limit~ : Int,
) -> NearMiss {
  let failed = []
  let mut kept = 0
  for i in 0..<self.failed.length() {
    let failed_condition = self.failed[i]
    match failed_condition.condition {
      Body if truncated =>
        failed.push({ ..failed_condition, actual: [@utf8.decode_lossy(body)], })
      Form(_) | Xml(_) => {
        let actual = []
        for j in 0..<failed_condition.actual.length() {
          let value = failed_condition.actual[j]
          let room = value_room(utf8_length(value), kept~, limit~)
          if room < 0 {
            break
          }
          let value = truncate_text(value, room)
          actual.push(value)
          kept += utf8_length(value) + value_overhead
        }
        failed.push({ ..failed_condition, actual, })
      }
      _ => failed.push(failed_condition)
    }
  }
  { ..self, failed, }
}

///|
/// The length of `text` in UTF-8, in bytes. A surrogate that is not part of
/// a pair counts as U+FFFD does.
fn utf8_length(text : String) -> Int {
  let mut length = 0
  let mut i = 0
  while i < text.length() {
    let c = text[i].to_int()
    if c < 0x80 {
      length += 1
    } else if c < 0x800 {
      length += 2
    } else if c >= 0xD800 &&
      c <= 0xDBFF &&
      i + 1 < text.length() &&
      text[i + 1].to_int() >= 0xDC00 &&
      text[i + 1].to_int() <= 0xDFFF {
      length += 4
      i += 1
    } else {
      length += 3
    }
    i += 1
  }
  length
}

///|
/// The UTF-16 code units of `name`, 0 for none.
fn text_length(name : String?) -> Int {
  match name {
    Some(name) => name.length()
    None => 0
  }
}

///|
/// `text` cut to at most `limit` bytes of UTF-8, as `truncate` cuts a body.
fn truncate_text(text : String, limit : Int) -> String {
  // A UTF-16 code unit takes at most three bytes of UTF-8.
  if text.length() <= limit / 3 {
    return text
  }
  let bytes = @utf8.encode(text)
  if bytes.length() <= limit {
    text
  } else {
    @utf8.decode_lossy(truncate(bytes, limit))
  }
}

///|
/// The first bytes of `body`, at most `limit` of them. A cut that would
/// split a UTF-8 sequence is moved back to its start, so that a body in
/// UTF-8 stays UTF-8 when truncated.
fn truncate(body : Bytes, limit : Int) -> Bytes {
  if body.length() <= limit {
    return body
  }
  let mut end = if limit < 0 { 0 } else { limit }
  // A UTF-8 sequence takes at most four bytes.
  while end > 0 && end > limit - 3 && (body[end].to_int() & 0xC0) == 0x80 {
    end -= 1
  }
  body[:end].to_owned()
}

///|
/// What a slot of the ring buffer holds once its entry is gone. A removed
/// entry must not stay reachable from its old slot, or the Journal would
/// hold more than its bound says.
let vacated : JournalEntry = {
  seq: 0L,
  received_at: 0L,
  duration_ms: None,
  session: None,
  host: None,
  mock: None,
  via_default: false,
  digest: "",
  request: { meth: "", target: "", version: "", headers: [], body: b"", },
  body_size: 0,
  stub: None,
  stub_source: None,
  scenario: None,
  response_index: None,
  near_miss: None,
  status: None,
  fault: None,
  template_error: None,
  size: 0,
}

///|
/// Gives `entry` the next sequence number and appends it, then evicts the
/// oldest entries while the Journal is over either of its bounds, counting
/// them per Session. An entry that alone takes more bytes than the bound is
/// evicted at once instead, and the entries before it stay.
fn Journal::append(self : Journal, entry : JournalEntry) -> Unit {
  self.last_seq += 1L
  entry.seq = self.last_seq
  if entry.size > self.settings.max_bytes {
    self.count_eviction(entry)
    return
  }
  self.entries.push_back(entry)
  self.bytes += entry.size
  while self.entries.length() > self.settings.max_entries ||
        self.bytes > self.settings.max_bytes {
    guard self.entries.front() is Some(oldest) else { break }
    self.entries[0] = vacated
    self.entries.pop_front() |> ignore
    self.bytes -= oldest.size
    self.count_eviction(oldest)
  }
}

///|
/// Counts `entry` as evicted by the bound, for its Session.
fn Journal::count_eviction(self : Journal, entry : JournalEntry) -> Unit {
  self.evicted.update_or_default(entry.session, 1, count => count + 1)
  self.evictions += 1L
}

///|
/// Removes the entries for which `remove` holds, and returns how many it
/// removed.
fn Journal::remove_where(
  self : Journal,
  remove : (JournalEntry) -> Bool,
) -> Int {
  let before = self.entries.length()
  self.entries.retain(entry => {
    if remove(entry) {
      self.bytes -= entry.size
      false
    } else {
      true
    }
  })
  self.entries.release_unused(placeholder=vacated)
  before - self.entries.length()
}

///|
/// Removes the entries of `session`, or of the no-Session space for
/// `None`, and its eviction count. Returns how many entries it removed.
fn Journal::reset_session(self : Journal, session : String?) -> Int {
  self.evicted.remove(session)
  self.remove_where(entry => entry.session == session)
}

///|
/// Removes every entry and every eviction count. Returns how many entries
/// it removed.
fn Journal::reset_all(self : Journal) -> Int {
  let removed = self.entries.length()
  self.entries.clear()
  self.entries.release_unused(placeholder=vacated)
  self.bytes = 0
  self.evicted.clear()
  removed
}

///|
/// What the Journal holds, and how many entries its bound has evicted.
pub(all) struct JournalStats {
  /// The entries it holds.
  entries : Int
  /// The bytes they take, as they count them.
  bytes : Int
  /// The entries the bound has evicted since the process started, whatever
  /// resets came since.
  evictions : Int64
} derive(Debug)

///|
/// What the Journal holds now, and how many entries its bound has evicted
/// since the process started.
pub fn Engine::journal_stats(self : Engine) -> JournalStats {
  {
    entries: self.journal.entries.length(),
    bytes: self.journal.bytes,
    evictions: self.journal.evictions,
  }
}

///|
/// Commits `entry`, an uncommitted entry that `handle` returned: appends it
/// to the Journal, which evicts its oldest entries if it is then over its
/// bound. It takes constant time, apart from the evictions.
pub fn Engine::commit(self : Engine, entry : JournalEntry) -> Unit {
  self.journal.append(entry)
}

///|
/// Which Journal entries a query or a verification takes. Every condition
/// given must hold; an omitted one passes every entry. Its JSON form is
/// the `JournalFilter` schema of the Admin API document.
pub struct JournalFilter {
  /// Only entries of this Mock.
  mock : String?
  /// Conditions on the method, the path and the headers, with the
  /// semantics of Stub conditions.
  priv conditions : @definitions.Conditions
  /// Only entries received at or after this time, in milliseconds since
  /// the Unix epoch.
  since : Int64?
  /// Only entries received before this time.
  until : Int64?
}

///|
/// Whether `entry` passes the filter.
fn JournalFilter::passes(self : JournalFilter, entry : JournalEntry) -> Bool {
  if self.mock is Some(mock) && entry.mock != Some(mock) {
    return false
  }
  if self.since is Some(since) && entry.received_at < since {
    return false
  }
  if self.until is Some(until) && entry.received_at >= until {
    return false
  }
  Incoming::new(entry.request).meets(self.conditions)
}

///|
/// A Journal query or filter that does not have the shape the Admin API
/// document gives it: every problem, each with a JSON Pointer into it and
/// no file.
pub suberror InvalidQuery {
  InvalidQuery(Array[@definitions.Diagnostic])
} derive(Debug)

///|
/// The problems, one per line, as `<pointer>: <message>`.
pub fn InvalidQuery::message(self : InvalidQuery) -> String {
  let InvalidQuery(problems) = self
  problems.map(problem => problem.to_string()).join("\n")
}

///|
/// Reads a filter from its JSON form, the `JournalFilter` schema: an
/// object whose members are all optional. `mock` is a Mock name; `method`,
/// `path` and `headers` are written as in a Stub's `request`; `since` and
/// `until` are RFC 3339 date-times.
///
/// Raises `InvalidQuery` with every problem, each with a JSON Pointer into
/// `json`.
pub fn JournalFilter::from_json(
  json : Json,
) -> JournalFilter raise InvalidQuery {
  let problems = []
  let filter = read_filter(json, "", problems)
  if problems.length() > 0 {
    raise InvalidQuery(problems)
  }
  filter
}

///|
/// Reads the filter `json`, found at the JSON Pointer `at`, and adds every
/// problem with it to `problems`.
fn read_filter(
  json : Json,
  at : String,
  problems : Array[@definitions.Diagnostic],
) -> JournalFilter {
  let problem = (pointer : String, message : String) => {
    problems.push({ file: "", pointer, message, })
  }
  let mut mock = None
  let mut since = None
  let mut until = None
  let conditions = Map([])
  match json {
    Object(members) =>
      for name, value in members {
        let pointer = @definitions.child_pointer(at, name)
        let time = () => {
          match value {
            String(text) if @log.parse_time(text) is Some(time) => Some(time)
            _ => {
              problem(
                pointer, "must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z",
              )
              None
            }
          }
        }
        match name {
          "mock" =>
            match value {
              String(name) if name != "" => mock = Some(name)
              _ => problem(pointer, "must be a non-empty string")
            }
          "method" | "path" | "headers" => {
            // Checked one by one, so that the problems come in order.
            let alone = Json::object(Map::from_array([(name, value)]))
            if @definitions.request_conditions(alone) is Err(found) {
              for found in found {
                problems.push({ ..found, pointer: at + found.pointer, })
              }
            }
            conditions[name] = value
          }
          "since" => since = time()
          "until" => until = time()
          _ => problem(pointer, "is not a known field")
        }
      }
    _ => problem(at, "must be an object")
  }
  // Each condition has been checked alone: together, they are valid.
  let conditions = match
    @definitions.request_conditions(Json::object(conditions)) {
    Ok(conditions) => conditions
    Err(_) => no_conditions()
  }
  { mock, conditions, since, until, }
}

///|
/// The filter of no condition, which every entry passes.
fn every_entry() -> JournalFilter {
  { mock: None, conditions: no_conditions(), since: None, until: None, }
}

///|
/// Conditions that every request meets.
fn no_conditions() -> @definitions.Conditions {
  match @definitions.request_conditions(Json::object(Map([]))) {
    Ok(conditions) => conditions
    Err(_) => abort("no conditions are valid conditions")
  }
}

///|
/// A Journal query: the filter, the most entries to return, and the
/// sequence number of the entry to resume after. Its JSON form is the
/// `JournalQuery` schema of the Admin API document.
pub(all) struct JournalQuery {
  filter : JournalFilter
  /// The most entries to return.
  limit : Int
  /// Only entries after the one with this sequence number: the last entry
  /// of the page before. `None` starts from the oldest entry.
  after : Int64?
}

///|
/// The largest sequence number a query takes: the largest integer a JSON
/// number holds exactly, 2^53 - 1.
let max_seq : Int64 = 9_007_199_254_740_991L

///|
/// The default limit of a query.
let default_limit : Int = 100

///|
/// Reads a query from its JSON form, the `JournalQuery` schema: an object
/// with an optional `filter`, as `JournalFilter::from_json` reads it, an
/// optional `limit`, an integer from 1 to 10,000, by default 100, and an
/// optional `after`, a sequence number from 0 to 2^53 - 1.
///
/// Raises `InvalidQuery` with every problem, each with a JSON Pointer into
/// `json`.
pub fn JournalQuery::from_json(json : Json) -> JournalQuery raise InvalidQuery {
  let problems = []
  guard json is Object(members) else {
    raise InvalidQuery([
      { file: "", pointer: "", message: "must be an object", },
    ])
  }
  let mut filter = None
  let mut limit = default_limit
  let mut after = None
  for name, value in members {
    let pointer = @definitions.child_pointer("", name)
    match name {
      "filter" => filter = Some(read_filter(value, pointer, problems))
      "limit" =>
        match value {
          Number(n, ..) if n == n.floor() && n >= 1.0 && n <= 10000.0 =>
            limit = n.to_int()
          _ =>
            problems.push({
              file: "",
              pointer,
              message: "must be an integer from 1 to 10000",
            })
        }
      "after" =>
        match value {
          Number(n, ..) if n == n.floor() &&
            n >= 0.0 &&
            n <= max_seq.to_double() => after = Some(n.to_int64())
          _ =>
            problems.push({
              file: "",
              pointer,
              message: "must be an integer from 0 to \{max_seq}",
            })
        }
      _ =>
        problems.push({ file: "", pointer, message: "is not a known field", })
    }
  }
  if problems.length() > 0 {
    raise InvalidQuery(problems)
  }
  { filter: filter.unwrap_or_else(every_entry), limit, after, }
}

///|
/// A page of Journal entries, oldest first. Its JSON form is the
/// `JournalPage` schema of the Admin API document, without `warnings`.
pub struct JournalPage {
  entries : Array[JournalEntry]
  /// Whether more entries passed than the limit let through: the next page
  /// starts after the last entry of this one.
  more : Bool
  /// How many of the Session's entries the bound has evicted since its
  /// last reset.
  evicted : Int
} derive(Debug)

///|
/// The entries of `session`, or of the no-Session space for `None`, that
/// pass the query's filter, oldest first, after the entry whose sequence
/// number the query gives, if it gives one, at most the query's limit of
/// them, with how many of that Session's entries the bound evicted.
///
/// Raises `JournalOff` while the Journal is off globally, or when the
/// filter names a Mock whose Journal is off: there is no entry to trust.
/// A filter may name a Mock that the served definitions no longer
/// declare: the entries it recorded before a reload removed it remain.
pub fn Engine::query_journal(
  self : Engine,
  query : JournalQuery,
  session~ : String?,
) -> JournalPage raise AdminError {
  self.check_journal(query.filter)
  self.journal.page(session, query.limit, after=query.after, entry => {
    query.filter.passes(entry)
  })
}

///|
/// The entries of `session`, or of the no-Session space for `None`, that no
/// Stub answered, oldest first, after the entry with the sequence number
/// `after`, if given, at most `limit` of them, with how many of that
/// Session's entries the bound evicted. Each carries its full Near
/// miss, when its Mock had candidate Stubs. A request for a Host that no
/// Mock lists, with no Default Mock, is among them with no Mock and no Near
/// miss.
///
/// Raises `JournalOff` while the Journal is off globally: there is no entry
/// to trust.
pub fn Engine::unmatched(
  self : Engine,
  session~ : String?,
  limit? : Int = default_limit,
  after? : Int64,
) -> JournalPage raise AdminError {
  self.check_journal(every_entry())
  self.journal.page(session, limit, after~, entry => entry.stub is None)
}

///|
/// The entries of `session` for which `takes` holds, oldest first, after
/// the entry with the sequence number `after`, if given, at most `limit` of
/// them, with how many of that Session's entries the bound evicted.
fn Journal::page(
  self : Journal,
  session : String?,
  limit : Int,
  after~ : Int64?,
  takes : (JournalEntry) -> Bool,
) -> JournalPage {
  let entries = []
  let mut more = false
  let after = after.unwrap_or(0L)
  for entry in self.entries {
    if entry.seq <= after || entry.session != session || !takes(entry) {
      continue
    }
    if entries.length() >= limit {
      more = true
      break
    }
    entries.push(entry)
  }
  { entries, more, evicted: self.evicted.get(session).unwrap_or(0), }
}

///|
/// Raises `JournalOff` while the Journal is off globally, or when `filter`
/// names a Mock of the served definitions whose Journal is off.
fn Engine::check_journal(
  self : Engine,
  filter : JournalFilter,
) -> Unit raise AdminError {
  if !self.journal.settings.enabled {
    raise JournalOff(None)
  }
  if filter.mock is Some(name) &&
    self.snapshot.mocks.iter().any(mock => mock.name == name && !mock.journal) {
    raise JournalOff(Some(name))
  }
}

///|
/// The `JournalPage` schema of the Admin API document, without `warnings`.
pub impl ToJson for JournalPage with fn to_json(self) {
  {
    "entries": Json::array(self.entries.map(entry => ToJson::to_json(entry))),
    "more": Json::boolean(self.more),
    "evicted": Json::number(self.evicted.to_double()),
  }
}

///|
/// The `JournalEntry` schema of the Admin API document.
pub impl ToJson for JournalEntry with fn to_json(self) {
  let optional = (value : String?) => {
    value.map_or(Json::null(), value => Json::string(value))
  }
  {
    "seq": Json::number(self.seq.to_double()),
    "receivedAt": Json::string(@log.format_time(self.received_at)),
    "durationMs": self.duration_ms.map_or(Json::null(), ms => {
      Json::number(ms.to_double())
    }),
    "session": optional(self.session),
    "host": optional(self.host),
    "mock": optional(self.mock),
    "viaDefault": Json::boolean(self.via_default),
    "digest": Json::string(self.digest),
    "request": {
      "method": Json::string(self.request.meth),
      "target": Json::string(self.request.target),
      "version": Json::string(self.request.version),
      "headers": Json::array(
        self.request.headers.map(header => {
          "name": Json::string(header.0),
          "value": Json::string(header.1),
        }),
      ),
      "body": body_json(self.request.body, size=self.body_size),
    },
    "stub": optional(self.stub),
    "stubSource": optional(self.stub_source.map(source => source.name())),
    "scenario": self.scenario.map_or(Json::null(), moved => {
      ToJson::to_json(moved)
    }),
    "responseIndex": self.response_index.map_or(Json::null(), index => {
      Json::number(index.to_double())
    }),
    "nearMiss": self.near_miss.map_or(Json::null(), near_miss => {
      ToJson::to_json(near_miss)
    }),
    "status": self.status.map_or(Json::null(), status => {
      Json::number(status.to_double())
    }),
    "fault": self.fault.map_or(Json::null(), kind => Json::string(kind.name())),
    "templateError": self.template_error.map_or(Json::null(), error => {
      ToJson::to_json(error)
    }),
  }
}
