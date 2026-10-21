///|
/// Validates and compiles an Ephemeral Stub: `json`, a Stub in the shape
/// Definition files use, without `id` and `mock`, as the Admin API receives
/// it. The Stub gets the ID `id` and belongs to the Mock `mock`, which the
/// caller has checked exists. Its body must be inline. Its templates may
/// read the environment variables in `env`, as a load's may, and it may
/// read and write the Data buckets `buckets`, those the Mock declares: by
/// default, none.
///
/// Returns the Stub, or every problem found, with the messages a Stub in a
/// Definition file gets. A problem has no file (`""`), and its JSON Pointer
/// points into `json`.
pub fn ephemeral_stub(
  json : Json,
  id~ : String,
  mock~ : String,
  env? : @template.Env = @template.no_env,
  buckets? : ReadOnlyArray[DataBucket] = ReadOnlyArray::from_array([]),
) -> Result[Stub, Array[Diagnostic]] {
  let diagnostics = []
  let keyed = Map([])
  for bucket in buckets {
    keyed[bucket.name] = bucket.key is Some(_)
  }
  let file = File::{
    name: "",
    diagnostics,
    body_files: None,
    env,
    buckets: Map::from_array([(mock, MockBuckets::new(keyed))]),
  }
  guard json is Object(fields) else {
    file.error("", "must be an object")
    return Err(diagnostics)
  }
  if fields.contains("id") {
    file.error(
      "/id", "is not allowed in an Ephemeral Stub: smock assigns its ID",
    )
  }
  if fields.contains("mock") {
    file.error(
      "/mock", "is not allowed in an Ephemeral Stub: the Admin API path names its Mock",
    )
  }
  let fields = fields.copy()
  fields["id"] = Json::string(id)
  fields["mock"] = Json::string(mock)
  let stub = file.read_stub("", Json::object(fields))
  match stub {
    Some(stub) if diagnostics.is_empty() => Ok(stub)
    _ => Err(diagnostics)
  }
}
