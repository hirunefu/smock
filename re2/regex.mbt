///|
/// A compiled pattern. Compile it once with `compile`, then match it any
/// number of times with `full_match` and `search`.
///
/// Matching never backtracks: it runs every possible way through the pattern
/// in lockstep, one input character at a time, so its time grows linearly
/// with the length of the input whatever the pattern is.
pub struct Regex {
  /// The compiled program.
  priv insts : FixedArray[Inst]
  /// The DFA that `full_match` builds from the program as inputs need it.
  priv mut dfa : DfaSlot
}

///|
/// Where a regex is with its DFA.
priv enum DfaSlot {
  /// Not built yet: no `full_match` has run.
  Unbuilt
  Built(Dfa)
  /// Dropped: the program needs more states than the budget allows, so
  /// `full_match` runs the Pike VM.
  TooLarge
}

///|
/// Where a match was found: `input[start:end]` is the matched text. Both are
/// byte offsets into the input, and both fall on character boundaries.
pub(all) struct Match {
  start : Int32
  end : Int32
} derive(Eq, Debug)

///|
/// Why a pattern does not compile. `position` is where in the pattern the
/// problem is, counted in characters (code points) from 0; `message` says
/// what the problem is.
///
/// A message that ends in "is not supported in smock's RE2 subset" names RE2
/// syntax that the subset leaves out. One that ends in "is not RE2 syntax"
/// names syntax that RE2 does not have, such as a backreference or a
/// lookahead.
pub(all) suberror CompileError {
  CompileError(position~ : Int32, message~ : String)
} derive(Eq, Debug)

///|
/// Shows the error as `position <n>: <message>`.
pub impl Show for CompileError with fn output(self, logger) {
  let CompileError(position~, message~) = self
  logger.write_string("position \{position}: \{message}")
}

///|
/// Compiles `pattern`, written in smock's RE2 subset (see the module's
/// README). Raises `CompileError` for anything outside the subset,
/// and when the pattern exceeds a limit: a repetition count above 1000,
/// nested repetition counts whose product is above 1000, a compiled program
/// of more than 100 000 instructions, or groups nested more than 100 deep.
pub fn compile(pattern : String) -> Regex raise CompileError {
  let node = parse(pattern)
  { insts: compile_node(node), dfa: Unbuilt, }
}

///|
/// Reports whether the pattern matches the whole of `input`, as RE2's
/// `FullMatch` does: true when some way of matching the pattern spans the
/// input from its first byte to its last, whatever the preferences of its
/// alternations and repetitions.
///
/// `input` is UTF-8. A byte that is not part of well-formed UTF-8 is not a
/// character: nothing in a pattern consumes it, so input that contains one
/// never matches as a whole.
pub fn Regex::full_match(self : Regex, input : BytesView) -> Bool {
  let dfa = match self.dfa {
    Built(dfa) => Some(dfa)
    Unbuilt => {
      let dfa = Dfa::new(self.insts)
      self.dfa = Built(dfa)
      Some(dfa)
    }
    TooLarge => None
  }
  if dfa is Some(dfa) {
    match dfa.full_match(input) {
      Some(matched) => return matched
      None => self.dfa = TooLarge
    }
  }
  run(self.insts, input, Full).0 is Some(_)
}

///|
/// Returns the leftmost match in `input`, or `None` when there is none.
///
/// Among the matches that start leftmost, it returns the one RE2 returns:
/// alternatives are tried left to right and greedy repetitions prefer more,
/// lazy ones fewer (leftmost-first, as in Perl), not the longest match.
///
/// `input` is UTF-8. A byte that is not part of well-formed UTF-8 is not a
/// character: nothing in a pattern consumes it, so no match contains it, but
/// a match may end just before it or start just after it.
pub fn Regex::search(self : Regex, input : BytesView) -> Match? {
  run(self.insts, input, Search).0
}

///|
/// The number of steps the Pike VM takes to decide `full_match` on `input`,
/// as `full_match` does when its DFA is over budget. A step is one visit of
/// one instruction of the compiled program, so the count grows linearly with
/// the length of the input. It is a measure of work that does not depend on
/// the machine, for tests and benchmarks.
pub fn Regex::full_match_steps(self : Regex, input : BytesView) -> Int32 {
  run(self.insts, input, Full).1
}

///|
/// The number of steps `search` takes on `input`. A step is one visit of one
/// instruction of the compiled program, so the count grows linearly with the
/// length of the input. It is a measure of work that does not depend on the
/// machine, for tests and benchmarks.
pub fn Regex::search_steps(self : Regex, input : BytesView) -> Int32 {
  run(self.insts, input, Search).1
}
