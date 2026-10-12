///|
/// The syntax tree of a pattern.
priv enum Node {
  Empty
  Literal(Int)
  /// Consumes one code point of the set.
  Class(CharSet)
  /// Matches the empty string where the condition holds.
  Assert(Assertion)
  Concat(Array[Node])
  /// The alternatives, in order of preference.
  Alternate(Array[Node])
  /// `min` to `max` repetitions (`max` is `None` for no limit), preferring
  /// more when greedy and fewer when not. `nullable` and `product` are the
  /// node's `info`, kept so that it is computed once per node.
  Repeat(
    Node,
    min~ : Int,
    max~ : Int?,
    greedy~ : Bool,
    nullable~ : Bool,
    product~ : Int
  )
}

///|
/// Whether `node` can match the empty string (assertions aside), and the
/// largest product of the counts of nested counted repetitions in it, which
/// RE2 limits to `MAX_REPEAT`. Walks down to the nearest `Repeat`s only, so
/// building a tree bottom-up visits each node once.
fn info(node : Node) -> (Bool, Int) {
  match node {
    Empty | Assert(_) => (true, 1)
    Literal(_) | Class(_) => (false, 1)
    Concat(items) | Alternate(items) => {
      let mut all = true
      let mut any = false
      let mut product = 1
      for item in items {
        let (n, p) = info(item)
        all = all && n
        any = any || n
        product = @cmp.maximum(product, p)
      }
      (if node is Concat(_) { all } else { any }, product)
    }
    Repeat(_, nullable~, product~, ..) => (nullable, product)
  }
}

///|
/// A condition on the input around a position.
priv enum Assertion {
  BeginText
  EndText
  /// At the beginning of the input or after a `\n`.
  BeginLine
  /// At the end of the input or before a `\n`.
  EndLine
  WordBoundary
  NotWordBoundary
}

///|
/// The flags in effect, set with `(?ims)` and cleared with `(?-ims)`.
priv struct Flags {
  /// `i`: letters match either ASCII case.
  fold : Bool
  /// `m`: `^` and `$` also match at line boundaries.
  multi_line : Bool
  /// `s`: `.` also matches `\n`.
  dot_nl : Bool
}

///|
priv struct Parser {
  /// The pattern's code points. Error positions are indexes into it.
  chars : Array[Int]
  mut pos : Int
  /// The flags in effect at `pos`. They last until the end of the group that
  /// sets them.
  mut flags : Flags
  /// How many groups are open at `pos`.
  mut depth : Int
  /// Set once no `:]` is left in the rest of the pattern, so that looking for
  /// POSIX classes stays linear in the pattern length.
  mut no_posix_end : Bool
}

///|
/// How deep groups may nest. This bounds the recursion of the parser and
/// the compiler, so that they stay well within the call stack on every
/// target (wasm-gc hosts have small ones). RE2 allows deeper nesting.
const MAX_DEPTH : Int = 100

///|
fn parse(pattern : String) -> Node raise CompileError {
  let p : Parser = {
    chars: code_points(pattern),
    pos: 0,
    flags: { fold: false, multi_line: false, dot_nl: false, },
    depth: 0,
    no_posix_end: false,
  }
  let node = p.parse_alternation()
  if p.pos < p.chars.length() {
    // parse_alternation stops only at the end or at a `)`.
    fail_at(p.pos, "unexpected )")
  }
  node
}

///|
/// The code points of `s`.
fn code_points(s : String) -> Array[Int] {
  let out = []
  for c in s {
    out.push(c.to_int())
  }
  out
}

///|
/// Fails with the problem `message` at `position` in the pattern.
fn[T] fail_at(position : Int, message : String) -> T raise CompileError {
  raise CompileError(position~, message~)
}

///|
/// What `Parser::peek` returns past the end of the pattern. No code point
/// is negative.
const END : Int = -1

///|
/// The code point at `pos`, or `END` past the end of the pattern.
fn Parser::peek(self : Parser, pos : Int) -> Int {
  if pos >= 0 && pos < self.chars.length() {
    self.chars[pos]
  } else {
    END
  }
}

///|
/// The pattern text from `start` up to `end`, cut at the end of the pattern.
fn Parser::text(self : Parser, start : Int, end : Int) -> String {
  let b = StringBuilder()
  for i in start..<@cmp.minimum(end, self.chars.length()) {
    b.write_char(Int::unsafe_to_char(self.chars[i]))
  }
  b.to_string()
}

///|
/// Parses alternatives separated by `|`, up to the end of the pattern or the
/// `)` that closes the current group.
fn Parser::parse_alternation(self : Parser) -> Node raise CompileError {
  let alternatives = [self.parse_concat()]
  while self.peek(self.pos) == '|' {
    self.pos += 1
    alternatives.push(self.parse_concat())
  }
  if alternatives.length() == 1 {
    alternatives[0]
  } else {
    Alternate(alternatives)
  }
}

///|
/// Parses a sequence of atoms, each with its repetition operators, up to a
/// `|`, a `)` or the end of the pattern.
fn Parser::parse_concat(self : Parser) -> Node raise CompileError {
  let items : Array[Node] = []
  // Where the repetition operator that ends `items` starts, if one does.
  let mut last_repeat : Int? = None
  for c = self.peek(self.pos)
      c != END && c != '|' && c != ')'
      c = self.peek(self.pos) {
    let op_start = self.pos
    match self.parse_repeat_op() {
      Some((min, max)) => {
        let greedy = self.peek(self.pos) != '?'
        if !greedy {
          self.pos += 1
        }
        let op = self.text(op_start, self.pos)
        if last_repeat is Some(last_repeat) {
          let ops = self.text(last_repeat, self.pos)
          if op == "+" {
            fail_at(
              last_repeat,
              "possessive quantifier \{ops} is not RE2 syntax",
            )
          }
          fail_at(last_repeat, "bad repetition operator \{ops}")
        }
        guard items.pop() is Some(sub) else {
          fail_at(op_start, "missing argument to repetition operator \{op}")
        }
        let (sub_nullable, sub_product) = info(sub)
        // As in RE2, only counted repetitions count, by their maximum, or
        // their minimum when they have none.
        let count = if self.peek(op_start) != '{' {
          1
        } else {
          max.unwrap_or(min)
        }
        let product = sub_product * @cmp.maximum(count, 1)
        if product > MAX_REPEAT {
          fail_at(
            op_start,
            "nested repetition counts multiply to more than \{MAX_REPEAT} at \{op}",
          )
        }
        items.push(
          Repeat(
            sub,
            min~,
            max~,
            greedy~,
            nullable=min == 0 || sub_nullable,
            product~,
          ),
        )
        last_repeat = Some(op_start)
      }
      None => {
        if self.parse_atom() is Some(atom) {
          items.push(atom)
        }
        last_repeat = None
      }
    }
  }
  match items.length() {
    0 => Empty
    1 => items[0]
    _ => Concat(items)
  }
}

///|
/// Parses a repetition operator (`*`, `+`, `?`, `{n}`, `{n,}` or `{n,m}`)
/// at the current position, without a lazy `?` after it, and returns its
/// minimum and maximum (`None` for no limit). Returns `None`, consuming
/// nothing, when there is none: a `{` that does not start a valid counted
/// repetition is a literal, as in RE2.
fn Parser::parse_repeat_op(self : Parser) -> (Int, Int?)? raise CompileError {
  let start = self.pos
  match self.peek(start) {
    '*' => {
      self.pos += 1
      Some((0, None))
    }
    '+' => {
      self.pos += 1
      Some((1, None))
    }
    '?' => {
      self.pos += 1
      Some((0, Some(1)))
    }
    '{' => {
      guard self.parse_count(start + 1) is Some((min, after_min)) else {
        return None
      }
      let (max, close) = match self.peek(after_min) {
        '}' => (Some(min), after_min)
        ',' =>
          if self.peek(after_min + 1) == '}' {
            (None, after_min + 1)
          } else if self.parse_count(after_min + 1) is Some((max, after_max)) &&
            self.peek(after_max) == '}' {
            (Some(max), after_max)
          } else {
            return None
          }
        _ => return None
      }
      self.pos = close + 1
      if min > MAX_REPEAT ||
        (max is Some(max) && (max > MAX_REPEAT || max < min)) {
        fail_at(start, "invalid repetition size \{self.text(start, self.pos)}")
      }
      Some((min, max))
    }
    _ => None
  }
}

///|
/// The largest count a counted repetition may have, as in RE2.
const MAX_REPEAT : Int = 1000

///|
/// Parses a repetition count at `pos` as RE2 does: decimal digits with no
/// leading zero, below 10^9. Returns the count and the position after it.
fn Parser::parse_count(self : Parser, pos : Int) -> (Int, Int)? {
  if !is_digit(self.peek(pos)) {
    return None
  }
  if self.peek(pos) == '0' && is_digit(self.peek(pos + 1)) {
    return None
  }
  let mut n = 0
  let mut i = pos
  while is_digit(self.peek(i)) {
    if n >= 100000000 {
      return None
    }
    n = n * 10 + (self.peek(i) - '0')
    i += 1
  }
  Some((n, i))
}

///|
fn is_digit(c : Int) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// Parses one atom. Returns `None` for a flag setting such as `(?i)`, which
/// matches nothing itself.
fn Parser::parse_atom(self : Parser) -> Node? raise CompileError {
  let c = self.chars[self.pos]
  match c {
    '(' => return self.parse_group()
    '\\' => return Some(self.parse_escape())
    '[' => return Some(self.parse_class())
    _ => ()
  }
  self.pos += 1
  let flags = self.flags
  let node : Node = match c {
    '.' if flags.dot_nl => Class(CharSet::of([(0, MAX_CHAR)]))
    '.' => Class(CharSet::of([(0, '\n' - 1), ('\n' + 1, MAX_CHAR)]))
    '^' => Assert(if flags.multi_line { BeginLine } else { BeginText })
    '$' => Assert(if flags.multi_line { EndLine } else { EndText })
    _ => self.literal(c)
  }
  Some(node)
}

///|
/// The node for the literal code point `c` under the current flags.
fn Parser::literal(self : Parser, c : Int) -> Node {
  let folded = fold_ascii([(c, c)])
  if self.flags.fold && folded.length() > 1 {
    Class(CharSet::of(folded))
  } else {
    Literal(c)
  }
}

///|
/// The ranges with every ASCII letter in them added in its other case.
/// Case folding in R1 is ASCII only.
fn fold_ascii(ranges : Array[(Int, Int)]) -> Array[(Int, Int)] {
  let out = ranges.copy()
  for r in ranges {
    let (lo, hi) = r
    let lower_lo = @cmp.maximum(lo, 'a')
    let lower_hi = @cmp.minimum(hi, 'z')
    if lower_lo <= lower_hi {
      out.push((lower_lo - 32, lower_hi - 32))
    }
    let upper_lo = @cmp.maximum(lo, 'A')
    let upper_hi = @cmp.minimum(hi, 'Z')
    if upper_lo <= upper_hi {
      out.push((upper_lo + 32, upper_hi + 32))
    }
  }
  out
}

///|
/// Parses a group: `(re)`, `(?P<name>re)`, `(?:re)` or `(?flags:re)`, or the
/// flag setting `(?flags)`, which returns `None`. Capturing and
/// non-capturing groups match alike.
fn Parser::parse_group(self : Parser) -> Node? raise CompileError {
  let open = self.pos
  let outer = self.flags
  if self.peek(open + 1) != '?' {
    self.pos = open + 1
  } else {
    self.reject_group_syntax(open)
    if self.peek(open + 2) == 'P' {
      self.parse_group_name(open)
    } else {
      let (flags, starts_group) = self.parse_flags(open)
      self.flags = flags
      if !starts_group {
        return None
      }
    }
  }
  if self.depth == MAX_DEPTH {
    fail_at(open, "groups nest more than \{MAX_DEPTH} deep")
  }
  self.depth += 1
  let node = self.parse_alternation()
  if self.peek(self.pos) != ')' {
    fail_at(open, "missing closing )")
  }
  self.pos += 1
  self.depth -= 1
  self.flags = outer
  Some(node)
}

///|
/// Rejects the `(?` constructs of other regular-expression dialects, and
/// `(?<name>`, which RE2 has but R1 leaves out.
fn Parser::reject_group_syntax(
  self : Parser,
  open : Int,
) -> Unit raise CompileError {
  let c = self.peek(open + 2)
  let c2 = self.peek(open + 3)
  let what = match c {
    '=' | '!' => "lookahead (?\{self.text(open + 2, open + 3)}"
    '<' if c2 == '=' || c2 == '!' =>
      "lookbehind (?<\{self.text(open + 3, open + 4)}"
    '<' =>
      fail_at(
        open, "named group (?<name>...) is not supported in R1; use (?P<name>...)",
      )
    '>' => "atomic group (?>"
    '#' => "comment (?#"
    '|' => "branch reset (?|"
    'R' | '+' | '&' => "recursion (?\{self.text(open + 2, open + 3)}"
    '-' if is_digit(c2) => "recursion (?\{self.text(open + 2, open + 4)}"
    _ if is_digit(c) => "recursion (?\{self.text(open + 2, open + 3)}"
    'P' if c2 == '=' => "backreference (?P=name)"
    'P' if c2 == '>' => "recursion (?P>"
    '\'' => "named group (?'name'"
    'C' => "callout (?C"
    _ => return
  }
  fail_at(open, "\{what} is not RE2 syntax")
}

///|
/// Parses the `(?P<name>` that starts at `open`. A name is one or more ASCII
/// letters, digits and `_`.
fn Parser::parse_group_name(
  self : Parser,
  open : Int,
) -> Unit raise CompileError {
  if self.peek(open + 3) != '<' {
    fail_at(open, "invalid group \{self.text(open, open + 4)}")
  }
  let start = open + 4
  let mut end = start
  while self.peek(end) != END && self.peek(end) != '>' {
    end += 1
  }
  let mut valid = self.peek(end) == '>' && end > start
  let mut ascii = true
  for i in start..<@cmp.minimum(end, self.chars.length()) {
    if self.chars[i] >= 0x80 {
      ascii = false
    } else if !word_chars.contains(self.chars[i]) {
      valid = false
    }
  }
  if valid && !ascii {
    // RE2 also accepts Unicode word characters in names.
    fail_at(
      open,
      "non-ASCII capture group name \{self.text(open, end + 1)} is not supported in R1",
    )
  }
  if !valid {
    fail_at(open, "invalid named capture group \{self.text(open, end + 1)}")
  }
  self.pos = end + 1
}

///|
/// Parses the flags of the `(?flags)` or `(?flags:` that starts at `open`:
/// `i`, `m` and `s` set a flag, and after a `-` they clear it. Returns the
/// new flags and whether a group follows (`:`).
fn Parser::parse_flags(
  self : Parser,
  open : Int,
) -> (Flags, Bool) raise CompileError {
  let mut flags = self.flags
  let mut negated = false
  // Whether a flag follows the `-`, which RE2 requires.
  let mut cleared = false
  let mut i = open + 2
  for ;; {
    let c = self.peek(i)
    let on = !negated
    match c {
      'i' => flags = { ..flags, fold: on, }
      'm' => flags = { ..flags, multi_line: on, }
      's' => flags = { ..flags, dot_nl: on, }
      '-' if !negated => negated = true
      ':' | ')' if !negated || cleared => {
        self.pos = i + 1
        return (flags, c == ':')
      }
      'U' => fail_at(i, "flag U is not supported in R1")
      _ if c == END => fail_at(open, "missing closing )")
      _ if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') =>
        fail_at(i, "flag \{self.text(i, i + 1)} is not RE2 syntax")
      _ => fail_at(open, "invalid flags \{self.text(open, i + 1)}")
    }
    if negated && c != '-' {
      cleared = true
    }
    i += 1
  }
}

///|
/// Parses an escape outside a bracket class.
fn Parser::parse_escape(self : Parser) -> Node raise CompileError {
  let c = self.peek(self.pos + 1)
  if perl_class(c) is Some(set) {
    self.pos += 2
    return Class(set)
  }
  let assertion = match c {
    'A' => Some(BeginText)
    'z' => Some(EndText)
    'b' => Some(WordBoundary)
    'B' => Some(NotWordBoundary)
    _ => None
  }
  if assertion is Some(a) {
    self.pos += 2
    return Assert(a)
  }
  self.literal(self.parse_char_escape(in_class=false))
}

///|
/// Parses an escape that stands for one code point: an escaped ASCII
/// character that is not a letter or digit, such as `\.` or `\-`. Rejects
/// every other escape that reaches it, inside a bracket class or not.
fn Parser::parse_char_escape(
  self : Parser,
  in_class~ : Bool,
) -> Int raise CompileError {
  let start = self.pos
  let c = self.peek(start + 1)
  if c == END {
    fail_at(start, "trailing backslash at end of pattern")
  }
  if (c < 0x80 && !word_chars.contains(c)) || c == '_' {
    self.pos = start + 2
    return c
  }
  let escape = self.text(start, start + 2)
  match c {
    '1'..='7' if self.peek(start + 2) >= '0' && self.peek(start + 2) <= '7' =>
      fail_at(
        start,
        "octal escape \{self.text(start, start + 3)} is not supported in R1",
      )
    '1'..='9' | 'k' | 'g' =>
      fail_at(start, "backreference \{escape} is not RE2 syntax")
    '0' => fail_at(start, "octal escape \{escape} is not supported in R1")
    'x' => fail_at(start, "hexadecimal escape \{escape} is not supported in R1")
    'a' | 'f' | 'n' | 'r' | 't' | 'v' =>
      fail_at(start, "escape \{escape} is not supported in R1")
    'p' | 'P' => {
      let end = if self.peek(start + 2) == '{' {
        let mut i = start + 3
        while self.peek(i) != END && self.peek(i) != '}' {
          i += 1
        }
        i + 1
      } else {
        start + 3
      }
      fail_at(
        start,
        "Unicode class \{self.text(start, end)} is not supported in R1",
      )
    }
    // Assertions and \Q and \C reach here only inside a class, Perl classes
    // only as the end of a range.
    'b' | 'B' | 'A' | 'z' | 'Q' | 'C' if in_class =>
      fail_at(
        start,
        "escape \{escape} inside a character class is not RE2 syntax",
      )
    'Q' => fail_at(start, "quoting with \\Q...\\E is not supported in R1")
    'C' => fail_at(start, "\\C (any byte) is not supported in R1")
    'd' | 'D' | 's' | 'S' | 'w' | 'W' =>
      fail_at(start, "\{escape} cannot end a character class range")
    _ => fail_at(start, "escape \{escape} is not RE2 syntax")
  }
}

///|
/// The set of the Perl class `\<c>`, if `c` names one.
fn perl_class(c : Int) -> CharSet? {
  match c {
    'd' => Some(digits)
    'D' => Some(digits.negate())
    's' => Some(spaces)
    'S' => Some(spaces.negate())
    'w' => Some(word_chars)
    'W' => Some(word_chars.negate())
    _ => None
  }
}

///|
/// `\d`: ASCII digits.
let digits : CharSet = CharSet::of([('0', '9')])

///|
/// `\s`: RE2's ASCII white space, `[\t\n\f\r ]`.
let spaces : CharSet = CharSet::of([('\t', '\n'), ('\u{0c}', '\r'), (' ', ' ')])

///|
/// `\w`: ASCII letters, digits and `_`.
let word_chars : CharSet = CharSet::of([
  ('0', '9'),
  ('A', 'Z'),
  ('_', '_'),
  ('a', 'z'),
])

///|
/// The names of the POSIX classes RE2 has, such as `[:alpha:]`.
let posix_classes : Array[String] = [
  "alnum", "alpha", "ascii", "blank", "cntrl", "digit", "graph", "lower", "print",
  "punct", "space", "upper", "word", "xdigit",
]

///|
/// Parses a bracket class such as `[^a-z\d]`.
fn Parser::parse_class(self : Parser) -> Node raise CompileError {
  let open = self.pos
  self.pos += 1
  let negated = self.peek(self.pos) == '^'
  if negated {
    self.pos += 1
  }
  let ranges : Array[(Int, Int)] = []
  // `]` right after `[` or `[^` is a literal.
  let mut first = true
  while first || self.peek(self.pos) != ']' {
    first = false
    self.reject_posix_class()
    if self.peek(self.pos) == '\\' &&
      perl_class(self.peek(self.pos + 1)) is Some(set) {
      self.pos += 2
      let r = set.ranges
      for i = 0; i < r.length(); i = i + 2 {
        ranges.push((r[i], r[i + 1]))
      }
      continue
    }
    let lo_pos = self.pos
    let lo = self.parse_class_char(open)
    let mut hi = lo
    // `-` before the closing `]` is a literal.
    if self.peek(self.pos) == '-' && self.peek(self.pos + 1) != ']' {
      self.pos += 1
      hi = self.parse_class_char(open)
      if hi < lo {
        fail_at(
          lo_pos,
          "invalid character class range \{self.text(lo_pos, self.pos)}",
        )
      }
    }
    ranges.push((lo, hi))
  }
  self.pos += 1
  // Case folding comes before negation, so (?i)[^a] excludes A too.
  let set = CharSet::of(
    if self.flags.fold {
      fold_ascii(ranges)
    } else {
      ranges
    },
  )
  Class(if negated { set.negate() } else { set })
}

///|
/// Rejects a POSIX class such as `[:alpha:]` at the current position inside
/// a bracket class. A `[` that does not start one is a literal, as in RE2.
fn Parser::reject_posix_class(self : Parser) -> Unit raise CompileError {
  let start = self.pos
  if self.peek(start) != '[' || self.peek(start + 1) != ':' || self.no_posix_end {
    return
  }
  // As in RE2, the class name runs to the next `:]`, wherever it is.
  let mut end = start + 2
  while self.peek(end) != END &&
        !(self.peek(end) == ':' && self.peek(end + 1) == ']') {
    end += 1
  }
  if self.peek(end) == END {
    self.no_posix_end = true
    return
  }
  let name_start = if self.peek(start + 2) == '^' {
    start + 3
  } else {
    start + 2
  }
  let class = self.text(start, end + 2)
  if posix_classes.contains(self.text(name_start, end)) {
    fail_at(start, "POSIX class \{class} is not supported in R1")
  }
  fail_at(start, "invalid POSIX class \{class}")
}

///|
/// Parses one code point of a bracket class that opened at `open`.
fn Parser::parse_class_char(
  self : Parser,
  open : Int,
) -> Int raise CompileError {
  let c = self.peek(self.pos)
  if c == END {
    fail_at(open, "missing closing ]")
  }
  if c == '\\' {
    if self.peek(self.pos + 1) == END {
      fail_at(open, "missing closing ]")
    }
    return self.parse_char_escape(in_class=true)
  }
  self.pos += 1
  c
}
