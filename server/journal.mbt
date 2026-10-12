// The Journal on the admin port: the query operation, scoped to the calling
// Session, and the metrics of the Journal's size and evictions. The metrics
// are read from the engine when /metrics is scraped, so recording a request
// costs nothing for them.

///|
/// The metrics of the Journal: its size and the entries its bound evicted.
/// They carry no label: no Session, Mock or path.
priv struct JournalMetrics {
  /// `smock_journal_entries`.
  entries : @metrics.GaugeSeries
  /// `smock_journal_bytes`.
  bytes : @metrics.GaugeSeries
  /// `smock_journal_evictions_total`.
  evictions : @metrics.CounterSeries
  /// The evictions the counter has counted so far.
  mut counted : Int64
}

///|
/// Registers the metrics of the Journal in `metrics`.
fn JournalMetrics::register(metrics : @metrics.Registry) -> JournalMetrics {
  let entries = metrics
    .gauge("smock_journal_entries", help="Entries the Journal holds.", labels=[])
    .labels([])
  let bytes = metrics
    .gauge(
      "smock_journal_bytes",
      help="Bytes the Journal's entries take, as they count them against its byte bound (--journal-max-bytes).",
      labels=[],
    )
    .labels([])
  let evictions = metrics
    .counter(
      "smock_journal_evictions_total",
      help="Journal entries evicted because the Journal was full (--journal-max-entries, --journal-max-bytes).",
      labels=[],
    )
    .labels([])
  evictions.inc(by=0)
  { entries, bytes, evictions, counted: 0L, }
}

///|
/// Brings the metrics up to date with `stats`, what the Journal holds now.
fn JournalMetrics::update(
  self : JournalMetrics,
  stats : @engine.JournalStats,
) -> Unit {
  self.entries.set(stats.entries.to_double())
  self.bytes.set(stats.bytes.to_double())
  if stats.evictions > self.counted {
    self.evictions.inc(by=(stats.evictions - self.counted).to_double())
    self.counted = stats.evictions
  }
}

///|
/// Queries the calling Session's Journal entries with the filter and the
/// limit in the body, oldest first.
fn query_journal(
  admin : Admin,
  request : @http1.Request,
  body : Json?,
) -> Reply {
  let session = admin.session(request)
  guard body is Some(body) else {
    return admin.error(
      400, "invalid_request", "the body must be a Journal query: a JSON object, such as {\"filter\":{\"path\":\"/users/1\"},\"limit\":10}",
    )
  }
  let query = @engine.JournalQuery::from_json(body) catch {
    err =>
      return admin.error(
        400,
        "invalid_request",
        "the query is not valid: \{err.message()}",
      )
  }
  let page = admin.engine.query_journal(query, session~) catch {
    error => return admin.refused(error, session)
  }
  guard ToJson::to_json(page) is Object(members) else {
    abort("a Journal page is a JSON object")
  }
  admin.json(200, members)
}
