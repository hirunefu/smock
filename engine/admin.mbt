// The errors of the Admin API operations the engine carries out: on
// Ephemeral Stubs, resets, Journal queries and verifications.

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
