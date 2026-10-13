// The errors of the Admin API operations the engine carries out: on
// Ephemeral Stubs, resets, Journal queries and verifications; and the
// warnings every Admin API response carries.

///|
/// Why the engine refused an Admin API operation.
pub suberror AdminError {
  /// No Mock has this name. Mocks come only from Definition files.
  UnknownMock(String)
  /// The calling Session has no Ephemeral Stub with this ID in the Mock.
  UnknownEphemeralStub(mock~ : String, id~ : String)
  /// The Ephemeral Stub to add is not valid. The problems have no file;
  /// their JSON Pointers point into the Stub as it was given.
  InvalidStub(Array[@definitions.Diagnostic])
  /// The Journal is off for what the operation touches: globally for
  /// `None`, or for the Mock with this name.
  JournalOff(String?)
} derive(Debug)

///|
/// A warning that an Admin API response carries, in its `warnings` array.
pub(all) struct AdminWarning {
  /// What it is about, such as `per_replica_state`.
  code : String
  /// The warning, for people.
  message : String
} derive(Debug, Eq, ToJson)

///|
/// The warnings every Admin API response of the replica named `replica`
/// carries, in a deployment of `replicas` replicas (`--replicas`). Replicas
/// share no state, so with more than one, a `per_replica_state` warning
/// says that each keeps its own Ephemeral Stubs and Journal and that the
/// response comes from `replica` alone.
pub fn admin_warnings(
  replicas~ : Int,
  replica~ : String,
) -> Array[AdminWarning] {
  if replicas <= 1 {
    return []
  }
  [
    {
      code: "per_replica_state",
      message: "This deployment runs \{replicas} replicas (--replicas), and each one keeps its own Ephemeral Stubs and Journal. This response comes from \{replica} alone.",
    },
  ]
}
