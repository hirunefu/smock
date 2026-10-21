// Session copies of Data buckets: a Session reads a bucket's initial value
// until it first writes to the bucket, which makes its own copy, kept in
// the per-Session store beside its Variables. Reads never copy. The Admin
// API lists a Mock's buckets, and reads, sets and drops the calling
// Session's copy of one.

///|
/// A Data bucket of a Mock as one Session sees it, as the Admin API shows
/// it.
pub(all) struct SessionBucket {
  /// The bucket's name.
  name : String
  /// The member that holds each item's key, when the bucket is keyed.
  key : String?
  /// How the bucket makes new keys, when it is keyed.
  new_key : @definitions.NewKey?
  /// Whether the Session holds its own copy of the bucket.
  written : Bool
  /// What the Session reads: its copy, or else the initial value.
  value : Json
} derive(Debug)

///|
/// The Data buckets of the Mock `mock`, sorted by name in byte order, as
/// `session` sees them, or the no-Session space when it is `None`: whether
/// it holds its own copy of each, and what it reads. Another Session's
/// copies are never among them.
///
/// Raises `UnknownMock` when no Mock has the name `mock`.
pub fn Engine::list_data(
  self : Engine,
  mock~ : String,
  session~ : String?,
) -> Array[SessionBucket] raise AdminError {
  let declared = self.mock_named(mock)
  let copies = self.store.copy_values(mock, session)
  let buckets = declared.buckets.iter().collect()
  buckets.sort_by((a, b) => {
    @utf8.encode(a.name).lexical_compare(@utf8.encode(b.name))
  })
  buckets.map(bucket => session_bucket(bucket, copies))
}

///|
/// The Data bucket `bucket` of the Mock `mock` as `session` sees it, or the
/// no-Session space when it is `None`: its copy, or else the initial
/// value.
///
/// Raises `UnknownMock` when no Mock has the name `mock`, and
/// `UnknownBucket` when the Mock has no bucket `bucket`.
pub fn Engine::read_data(
  self : Engine,
  mock~ : String,
  session~ : String?,
  bucket~ : String,
) -> SessionBucket raise AdminError {
  let declared = self.declared_bucket(mock, bucket)
  session_bucket(declared, self.store.copy_values(mock, session))
}

///|
/// Makes `value` the copy of the Data bucket `bucket` of the Mock `mock`
/// that `session` holds, or the no-Session space when it is `None`, in
/// place of the copy it had, if any; even a value equal to the initial one
/// makes a copy. The copy counts against the bound on per-Session state as
/// a Stub's writes do, and is taken only if it fits. Returns the bucket as
/// `read_data` then gives it.
///
/// Raises `UnknownMock` when no Mock has the name `mock`, `UnknownBucket`
/// when the Mock has no bucket `bucket`, `InvalidData` when the bucket is
/// keyed and `value` breaks the rules of keyed buckets, and
/// `StateLimitReached` when the copy would take the count above the bound,
/// which counts the refusal; then nothing is written.
pub fn Engine::set_data(
  self : Engine,
  mock~ : String,
  session~ : String?,
  bucket~ : String,
  value : Json,
) -> SessionBucket raise AdminError {
  let declared = self.declared_bucket(mock, bucket)
  if declared.key is Some(key) {
    let problems = @definitions.keyed_problems(value, key~)
    if !problems.is_empty() {
      raise InvalidData(bucket~, key~, problems~)
    }
  }
  let bytes = copy_bytes(bucket, value)
  let growth = self.store.copy_growth(mock, session, bucket, bytes)
  if !self.state.fits(growth) {
    raise StateLimitReached(self.state.refuse(growth))
  }
  self.store.write_copy(mock, session, bucket, value, bytes~, growth~)
  session_bucket(declared, self.store.copy_values(mock, session))
}

///|
/// Drops the copy of the Data bucket `bucket` of the Mock `mock` that
/// `session` holds, or the no-Session space when it is `None`, so that the
/// bucket reads its initial value again, and gives back the bytes the copy
/// counted against the bound on per-Session state. Without a copy, it
/// changes nothing. Returns the bucket as `read_data` then gives it.
///
/// Raises `UnknownMock` when no Mock has the name `mock`, and
/// `UnknownBucket` when the Mock has no bucket `bucket`.
pub fn Engine::drop_data(
  self : Engine,
  mock~ : String,
  session~ : String?,
  bucket~ : String,
) -> SessionBucket raise AdminError {
  let declared = self.declared_bucket(mock, bucket)
  self.store.drop_copy(mock, session, bucket) |> ignore
  session_bucket(declared, self.store.copy_values(mock, session))
}

///|
/// The Data bucket `bucket` of the Mock named `mock` in the snapshot
/// served.
///
/// Raises `UnknownMock` when no Mock has the name `mock`, and
/// `UnknownBucket` when the Mock has no bucket `bucket`.
fn Engine::declared_bucket(
  self : Engine,
  mock : String,
  bucket : String,
) -> @definitions.DataBucket raise AdminError {
  let declared = self.mock_named(mock)
  for candidate in declared.buckets {
    if candidate.name == bucket {
      return candidate
    }
  }
  raise UnknownBucket(mock~, bucket~)
}

///|
/// `bucket` as a space that holds the copies `copies` sees it.
fn session_bucket(
  bucket : @definitions.DataBucket,
  copies : Map[String, Json]?,
) -> SessionBucket {
  let copy = match copies {
    Some(copies) => copies.get(bucket.name)
    None => None
  }
  {
    name: bucket.name,
    key: bucket.key,
    new_key: if bucket.key is Some(_) {
      Some(bucket.new_key)
    } else {
      None
    },
    written: copy is Some(_),
    value: copy.unwrap_or(bucket.initial),
  }
}
