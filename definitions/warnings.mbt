// The `check` warnings: problems that do not make a definition set invalid.
// In R1 the only one is a shadowed Stub: a Stub that can never match,
// because an earlier Stub of the same Mock always matches first. A warning
// is only reported when it can be proven, so it is never a false positive.

///|
/// A warning about a valid definition set: the file it is in, a JSON
/// Pointer (RFC 6901) to the value it is about within that file, and a
/// message. Warnings do not stop a definition set from loading.
pub(all) struct Warning {
  file : String
  pointer : String
  message : String
} derive(Debug, Eq)

///|
/// `<file>: <pointer>: warning: <message>`, on one line, as
/// `Diagnostic::to_string` writes a problem.
pub fn Warning::to_string(self : Warning) -> String {
  one_line("\{self.file}: \{self.pointer}: warning: \{self.message}")
}

///|
/// The warnings about the definition set of the snapshot, in matching order
/// of the Stubs they are about, Mock by Mock: each Stub that an earlier Stub
/// of its Mock shadows, naming the first one that does.
pub fn Snapshot::warnings(self : Snapshot) -> Array[Warning] {
  let out : Array[Warning] = []
  for mock in self.mocks {
    for i, stub in mock.stubs {
      let mut shadowing = None
      for j in 0..<i {
        if shadows(mock.stubs[j].request, stub.request) {
          shadowing = Some(mock.stubs[j])
          break
        }
      }
      guard shadowing is Some(earlier) else { continue }
      let { file, pointer, } = self.stub_locations[stub.id]
      let earlier_at = self.stub_locations[earlier.id]
      out.push({
        file,
        pointer,
        message: "the Stub \{stub.id.escape()} can never match: the Stub \{earlier.id.escape()} at \{earlier_at} is tried first and matches every request this one would",
      })
    }
  }
  out
}

///|
/// Whether a Stub with the conditions `t`, tried before a Stub with the
/// conditions `s`, provably matches every request that `s` matches: `t`
/// has a subset of the conditions of `s`.
///
/// - `t`'s method is absent or equal to `s`'s.
/// - `t`'s path is absent, equal to `s`'s exact path, or a pattern that
///   matches `s`'s exact path.
/// - Each of `t`'s query, header and body conditions also appears,
///   identically, in `s`. Header names are in lower case, so they compare
///   case-insensitively, as in matching.
///
/// Containment between two patterns is not attempted: what cannot be
/// proven this way is not reported.
fn shadows(t : Conditions, s : Conditions) -> Bool {
  let meth = match t.meth {
    None => true
    Some(meth) => s.meth == Some(meth)
  }
  let path = match (t.path, s.path) {
    (None, _) => true
    (Some(Exact(t_path)), Some(Exact(s_path))) => t_path == s_path
    (Some(Pattern(pattern)), Some(Exact(s_path))) =>
      pattern.matches(@utf8.encode(s_path))
    (Some(_), _) => false
  }
  meth &&
  path &&
  t.query.iter().all(condition => s.query.contains(condition)) &&
  t.headers.iter().all(condition => s.headers.contains(condition)) &&
  (t.body is None || t.body == s.body)
}
