// The Journal on the admin port: the query, verify and unmatched
// operations, each scoped to the calling Session, and the metrics of the
// Journal's size and evictions. The metrics are read from the engine when
// /metrics is scraped, so recording a request costs nothing for them.

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
fn query_journal(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  guard call.body is Some(body) else {
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
  let page = admin.engine().query_journal(query, session~) catch {
      error => return admin.refused(error, session)
    }
  admin.result(page)
}

///|
/// Counts the calling Session's Journal entries that pass the filter in
/// the body, and checks the count exactly, at least or at most N. A failed
/// check is still a 200 reply, with `ok` false.
fn verify_journal(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  guard call.body is Some(body) else {
    return admin.error(
      400, "invalid_request", "the body must be a verification: a JSON object, such as {\"filter\":{\"path\":\"/users/1\"},\"exactly\":1}",
    )
  }
  let verify = @engine.VerifyRequest::from_json(body) catch {
    err =>
      return admin.error(
        400,
        "invalid_request",
        "the verification is not valid: \{err.message()}",
      )
  }
  let verification = admin.engine().verify(verify, session~) catch {
      error => return admin.refused(error, session)
    }
  admin.result(verification)
}

///|
/// Lists the calling Session's Journal entries that no Stub answered,
/// oldest first, each with its Near miss, at most as many as the `limit`
/// query parameter says.
fn list_unmatched(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  let invalid = (message : String) => {
    admin.error(400, "invalid_request", message)
  }
  let limit = match query_parameter(call.request.target, "limit") {
    Err(message) => return invalid(message)
    Ok(None) => None
    Ok(Some(text)) =>
      match parse_limit(text) {
        Some(limit) => Some(limit)
        None =>
          return invalid(
            "the limit query parameter must be an integer from 1 to 10000",
          )
      }
  }
  let page = admin.engine().unmatched(session~, limit?) catch {
      error => return admin.refused(error, session)
    }
  admin.result(page)
}

///|
/// The limit `text` gives: a decimal integer from 1 to 10,000, without a
/// sign, prefix or separator. `None` when it is not one.
fn parse_limit(text : String) -> Int? {
  if text == "" ||
    text.length() > 5 ||
    !text.iter().all(c => c >= '0' && c <= '9') {
    return None
  }
  let n = text.fold(init=0, (n, c) => n * 10 + (c.to_int() - '0'.to_int()))
  if n >= 1 && n <= 10000 {
    Some(n)
  } else {
    None
  }
}
