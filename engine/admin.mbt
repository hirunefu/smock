// The errors of the Admin API operations the engine carries out: on
// Ephemeral Stubs, Scenarios, Variables, resets, Journal queries and
// verifications; and the warnings every Admin API response carries.

///|
/// Why the engine refused an Admin API operation.
pub suberror AdminError {
  /// No Mock has this name. Mocks come only from Definition files.
  UnknownMock(String)
  /// The calling Session has no Ephemeral Stub with this ID in the Mock.
  UnknownEphemeralStub(mock~ : String, id~ : String)
  /// No Stub of the Mock names the Scenario, in the Definition files or
  /// among the calling Session's Ephemeral Stubs, and the Session holds no
  /// state for it.
  UnknownScenario(mock~ : String, scenario~ : String)
  /// The state is not one of `known`, the known states of the Scenario of
  /// the Mock for the calling Session.
  UnknownState(
    mock~ : String,
    scenario~ : String,
    state~ : String,
    known~ : Array[String]
  )
  /// The name cannot name a Variable: it is not 1 to
  /// `@definitions.max_variable_name` ASCII letters, digits, `_` and `-`.
  InvalidVariableName(String)
  /// The calling Session has no Variable with this name in the Mock.
  UnknownVariable(mock~ : String, name~ : String)
  /// The value to set the Variable `name` to takes `bytes` bytes of compact
  /// JSON, more than `max_variable_value`, so nothing was written.
  VariableTooLarge(name~ : String, bytes~ : Int64)
  /// The write would take the count of per-Session state above its bound,
  /// for the reason given, so nothing was written.
  StateLimitReached(String)
  /// The Ephemeral Stub to add is not valid. The problems have no file;
  /// their JSON Pointers point into the Stub as it was given.
  InvalidStub(Array[@definitions.Diagnostic])
  /// The Journal is off: globally for `None`, or for the Mock with this
  /// name, which the operation's filter names.
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
/// says that each keeps its own Ephemeral Stubs, Scenario state, Variables
/// and Journal and that the response comes from `replica` alone.
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
      message: "This deployment runs \{replicas} replicas (--replicas), and each one keeps its own Ephemeral Stubs, Scenario state, Variables and Journal. This response comes from \{replica} alone.",
    },
  ]
}
