// The `check` warnings: problems that do not make a definition set invalid.
// There are two: a shadowed Stub, which can never match because an earlier
// Stub of the same Mock always matches first; and a Stub that requires a
// state of a Scenario that no Stub in the files moves to. A warning is only
// reported when it can be proven, so it is never a false positive.

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
/// `<file>: <pointer>: warning: <message>`, written as
/// `Diagnostic::to_string` writes a problem: on one line, and without the
/// parts that are empty.
pub fn Warning::to_string(self : Warning) -> String {
  Diagnostic::{
    file: self.file,
    pointer: self.pointer,
    message: "warning: \{self.message}",
  }.to_string()
}

///|
/// The warnings about the definition set of the snapshot, in matching order
/// of the Stubs they are about, Mock by Mock. For each Stub:
///
/// - if an earlier Stub of its Mock shadows it, a warning at the Stub that
///   names the first one that does;
/// - if it requires a state other than `initial_state` that no Stub of its
///   Mock moves its Scenario to, a warning at its `requires`. The state is
///   not proven unreachable, since the Admin API or an Ephemeral Stub can
///   move the Scenario there, so the warning states the fact.
pub fn Snapshot::warnings(self : Snapshot) -> Array[Warning] {
  let out : Array[Warning] = []
  for mock in self.mocks {
    let moves = moves_of(mock.stubs)
    for i, stub in mock.stubs {
      let { file, pointer, } = self.stub_locations[stub.id]
      let mut shadowing = None
      for j in 0..<i {
        if shadows(mock.stubs[j], stub) {
          shadowing = Some(mock.stubs[j])
          break
        }
      }
      if shadowing is Some(earlier) {
        let earlier_at = self.stub_locations[earlier.id]
        out.push({
          file,
          pointer,
          message: "the Stub \{stub.id.escape()} can never match: the Stub \{earlier.id.escape()} at \{earlier_at} is tried first and matches every request this one would",
        })
      }
      let scenario = match stub.serves {
        Ordinary(ordinary) => ordinary.scenario
        Crud(_) => None
      }
      guard scenario is Some({ name, requires: Some(state), .. }) &&
        state != initial_state &&
        !(moves.get(name) is Some(states) && states.contains(state)) else {
        continue
      }
      out.push({
        file,
        pointer: "\{pointer}/scenario/requires",
        message: "the Stub \{stub.id.escape()} requires the state \{state.escape()} of the Scenario \{name.escape()}, but no Stub in the Definition files moves \{name.escape()} to \{state.escape()}; only the Admin API or an Ephemeral Stub can",
      })
    }
  }
  out
}

///|
/// The states that `stubs`, the Stubs of one Mock, move each Scenario to
/// with `moveTo`, by the Scenario's name.
fn moves_of(stubs : ReadOnlyArray[Stub]) -> Map[String, Set[String]] {
  let moves : Map[String, Set[String]] = Map([])
  for stub in stubs {
    let scenario = match stub.serves {
      Ordinary(ordinary) => ordinary.scenario
      Crud(_) => None
    }
    guard scenario is Some({ name, move_to: Some(state), .. }) else { continue }
    match moves.get(name) {
      Some(states) => states.add(state)
      None => moves[name] = Set([state])
    }
  }
  moves
}

///|
/// Whether the Stub `t`, tried before the Stub `s`, provably matches every
/// request that `s` matches, in every state `s` can match in: `t`'s request
/// conditions shadow `s`'s, and either `t` has no `requires`, or `s` names
/// the same Scenario with the same `requires`. `moveTo` plays no part: it
/// does not change whether a Stub matches.
///
/// No CRUD Stub shadows a Stub, or is shadowed, for now.
fn shadows(t : Stub, s : Stub) -> Bool {
  match (t.serves, s.serves) {
    (Ordinary(t), Ordinary(s)) => {
      let in_states_of_s = match t.scenario {
        None | Some({ requires: None, .. }) => true
        Some({ name, requires, .. }) =>
          s.scenario is Some(clause) &&
          clause.name == name &&
          clause.requires == requires
      }
      in_states_of_s && request_shadows(t.request, s.request)
    }
    (Crud(_), _) | (_, Crud(_)) => false
  }
}

///|
/// Whether a Stub with the request conditions `t`, tried before a Stub with
/// the request conditions `s`, provably matches every request that `s`
/// matches: `t` has a subset of the conditions of `s`.
///
/// - `t`'s method is absent or equal to `s`'s.
/// - `t`'s path is absent, equal to `s`'s exact path, or a pattern that
///   matches `s`'s exact path.
/// - Each of `t`'s query, header, cookie and body conditions also
///   appears, identically, in `s`. Header names are in lower case, so they
///   compare case-insensitively, as in matching; cookie names compare
///   exactly. A `json` condition with patterns is identical only to one
///   with the same patterns in the same places, and a value condition with
///   operators only to one with the same operators around an identical
///   condition. The fields of a `form` condition and the paths of an `xml`
///   condition are conditions of their own, as query parameters are,
///   beside the body being a form or XML, which both Stubs then need: each
///   of `t`'s fields or paths appears, written the same, with an identical
///   condition in `s`'s `form` or `xml` condition.
///
/// A subset of conjuncts is sound whatever the conditions mean, operators
/// included. Containment between two patterns is not attempted, and
/// neither is any reasoning about operators, such as a value and its
/// negation excluding each other: what cannot be proven this way is not
/// reported.
fn request_shadows(t : Conditions, s : Conditions) -> Bool {
  let meth = match t.meth {
    None => true
    Some(meth) => s.meth == Some(meth)
  }
  let path = match (t.path, s.path) {
    (None, _) => true
    (Some(Has(Exact(t_path))), Some(Has(Exact(s_path)))) => t_path == s_path
    (Some(Has(Pattern(pattern))), Some(Has(Exact(s_path)))) =>
      pattern.matches(@utf8.encode(s_path))
    (Some(_), _) => false
  }
  let body = match (t.body, s.body) {
    (None, _) => true
    (Some(Form(t_fields)), Some(Form(s_fields))) =>
      t_fields.iter().all(condition => s_fields.contains(condition))
    (Some(Xml(t_paths)), Some(Xml(s_paths))) =>
      t_paths.iter().all(condition => s_paths.contains(condition))
    (t_body, s_body) => t_body == s_body
  }
  meth &&
  path &&
  t.query.iter().all(condition => s.query.contains(condition)) &&
  t.headers.iter().all(condition => s.headers.contains(condition)) &&
  t.cookies.iter().all(condition => s.cookies.contains(condition)) &&
  body
}
