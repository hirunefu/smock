// Verification: counting the calling Session's Journal entries that pass
// the shared filter, and checking the count exactly, at least or at most N.
// A count is never trusted when the Journal bound may have lowered it: once
// a Session's entries have been evicted, "exactly" and "at most" fail,
// whatever the count, while "at least" is still decided by the count,
// because eviction can only lower it.

///|
/// What a verification checks the count against.
pub(all) enum CountCheck {
  /// The count must be exactly this.
  Exactly(Int)
  /// The count must be at least this.
  AtLeast(Int)
  /// The count must be at most this.
  AtMost(Int)
} derive(Debug, Eq)

///|
/// A verification: which entries to count, and the check of their count.
/// Its JSON form is the `VerifyRequest` schema of the Admin API document.
pub(all) struct VerifyRequest {
  filter : JournalFilter
  check : CountCheck
}

///|
/// Why a verification failed.
pub(all) enum VerifyFailure {
  /// The count is not what the check asks for.
  Count
  /// Entries of the Session were evicted, so an "exactly" or "at most"
  /// count cannot be trusted.
  Evicted
} derive(Debug, Eq)

///|
/// The verdict of a verification. Its JSON form is the `Verification`
/// schema of the Admin API document, without `warnings`.
pub struct Verification {
  /// Whether the check passed.
  ok : Bool
  /// How many of the Session's entries pass the filter.
  count : Int
  /// How many of the Session's entries the bound has evicted since its
  /// last reset.
  evicted : Int
  /// Why the check failed, or `None` when it passed.
  reason : VerifyFailure?
} derive(Debug)

///|
/// The names of the members that give the check, in the `VerifyRequest`
/// schema.
let check_members : Array[String] = ["exactly", "atLeast", "atMost"]

///|
/// Reads a verification from its JSON form, the `VerifyRequest` schema: an
/// object with an optional `filter`, as `JournalFilter::from_json` reads
/// it, and exactly one of `exactly`, `atLeast` and `atMost`, each an
/// integer of 0 or more.
///
/// Raises `InvalidQuery` with every problem, each with a JSON Pointer into
/// `json`.
pub fn VerifyRequest::from_json(
  json : Json,
) -> VerifyRequest raise InvalidQuery {
  guard json is Object(members) else {
    raise InvalidQuery([
      { file: "", pointer: "", message: "must be an object", },
    ])
  }
  let problems : Array[@definitions.Diagnostic] = []
  let given = check_members.filter(name => members.contains(name))
  if given.length() != 1 {
    problems.push({
      file: "",
      pointer: "",
      message: "must have exactly one of exactly, atLeast and atMost",
    })
  }
  let mut filter = None
  let mut check = None
  for name, value in members {
    let pointer = @definitions.child_pointer("", name)
    match name {
      "filter" => filter = Some(read_filter(value, pointer, problems))
      "exactly" | "atLeast" | "atMost" =>
        match value {
          Number(n, ..) if n == n.floor() && n >= 0.0 => {
            // No count reaches the largest Int, so a larger N checks the
            // same as it.
            let n = if n >= 2147483647.0 { 2147483647 } else { n.to_int() }
            check = Some(
              match name {
                "exactly" => Exactly(n)
                "atLeast" => AtLeast(n)
                _ => AtMost(n)
              },
            )
          }
          _ =>
            problems.push({
              file: "",
              pointer,
              message: "must be an integer of 0 or more",
            })
        }
      _ =>
        problems.push({ file: "", pointer, message: "is not a known field", })
    }
  }
  if problems.length() > 0 {
    raise InvalidQuery(problems)
  }
  guard check is Some(check) else { abort("a valid request has a check") }
  { filter: filter.unwrap_or_else(every_entry), check, }
}

///|
/// Counts the entries of `session`, or of the no-Session space for `None`,
/// that pass the request's filter, and checks the count. When the bound
/// has evicted any of that Session's entries since its last reset,
/// "exactly" and "at most" fail with `Evicted`, whatever the count; "at
/// least" is decided by the count, because eviction can only lower it.
///
/// Raises `JournalOff` while the Journal is off globally, or when the
/// filter names a Mock whose Journal is off: there is no count to trust.
pub fn Engine::verify(
  self : Engine,
  request : VerifyRequest,
  session~ : String?,
) -> Verification raise AdminError {
  self.check_journal(request.filter)
  let mut count = 0
  for entry in self.journal.entries {
    if entry.session == session && request.filter.passes(entry) {
      count += 1
    }
  }
  let evicted = self.journal.evicted.get(session).unwrap_or(0)
  let reason : VerifyFailure? = match request.check {
    Exactly(_) | AtMost(_) if evicted > 0 => Some(Evicted)
    Exactly(n) if count != n => Some(Count)
    AtLeast(n) if count < n => Some(Count)
    AtMost(n) if count > n => Some(Count)
    _ => None
  }
  { ok: reason is None, count, evicted, reason, }
}

///|
/// The `Verification` schema of the Admin API document, without
/// `warnings`.
pub impl ToJson for Verification with fn to_json(self) {
  {
    "ok": Json::boolean(self.ok),
    "count": Json::number(self.count.to_double()),
    "evicted": Json::number(self.evicted.to_double()),
    "reason": match self.reason {
      None => Json::null()
      Some(Count) => Json::string("count")
      Some(Evicted) => Json::string("evicted")
    },
  }
}
