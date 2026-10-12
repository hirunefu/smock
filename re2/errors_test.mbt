///|
/// Compiles `pattern` and shows the error, or `compiled`.
fn error_of(pattern : String) -> String {
  try @re2.compile(pattern) catch {
    e => e.to_string()
  } noraise {
    _ => "compiled"
  }
}

///|
/// Compiles each pattern and shows `pattern => error`, one per line.
fn errors(patterns : Array[String]) -> String {
  patterns.map(pattern => "\{pattern} => \{error_of(pattern)}").join("\n")
}

///|
test "RE2 syntax left out of R1 is rejected as not supported in R1" {
  inspect(
    errors([
      "\\pL", "\\p{Greek}", "\\PN", "\\P{L}", "a[\\p{L}]", "\\n", "\\t", "\\r", "\\f",
      "\\v", "\\a", "\\x41", "\\x{263a}", "\\0", "\\12", "[\\101]", "\\Qa.b\\E",
      "\\C", "[[:alpha:]]", "[x[:^digit:]]", "(?U)a*", "(?iU)a*", "(?<name>a)", "(?P<é>x)",
    ]),
    content=(
      #|\pL => position 0: Unicode class \pL is not supported in R1
      #|\p{Greek} => position 0: Unicode class \p{Greek} is not supported in R1
      #|\PN => position 0: Unicode class \PN is not supported in R1
      #|\P{L} => position 0: Unicode class \P{L} is not supported in R1
      #|a[\p{L}] => position 2: Unicode class \p{L} is not supported in R1
      #|\n => position 0: escape \n is not supported in R1
      #|\t => position 0: escape \t is not supported in R1
      #|\r => position 0: escape \r is not supported in R1
      #|\f => position 0: escape \f is not supported in R1
      #|\v => position 0: escape \v is not supported in R1
      #|\a => position 0: escape \a is not supported in R1
      #|\x41 => position 0: hexadecimal escape \x is not supported in R1
      #|\x{263a} => position 0: hexadecimal escape \x is not supported in R1
      #|\0 => position 0: octal escape \0 is not supported in R1
      #|\12 => position 0: octal escape \12 is not supported in R1
      #|[\101] => position 1: octal escape \10 is not supported in R1
      #|\Qa.b\E => position 0: quoting with \Q...\E is not supported in R1
      #|\C => position 0: \C (any byte) is not supported in R1
      #|[[:alpha:]] => position 1: POSIX class [:alpha:] is not supported in R1
      #|[x[:^digit:]] => position 2: POSIX class [:^digit:] is not supported in R1
      #|(?U)a* => position 2: flag U is not supported in R1
      #|(?iU)a* => position 3: flag U is not supported in R1
      #|(?<name>a) => position 0: named group (?<name>...) is not supported in R1; use (?P<name>...)
      #|(?P<é>x) => position 0: non-ASCII capture group name (?P<é> is not supported in R1
    ),
  )
}

///|
test "syntax RE2 does not have is rejected as not RE2 syntax" {
  inspect(
    errors([
      "(a)\\1", "\\8", "\\k<a>", "\\g1", "(?P<a>x)(?P=a)", "(?=a)", "(?!a)", "(?<=a)",
      "(?<!a)", "(?>a)", "(?#note)", "(?|a)", "(?R)", "(?1)", "(?-1)", "(?+1)", "(?&a)",
      "(?P>a)", "(?'a'x)", "(?C1)", "(?x)a", "(?i-x)a", "a++", "a*+", "a?+", "a{2}+",
      "\\Z", "\\G", "\\K", "\\R", "\\X", "\\h", "\\N", "\\e", "\\o{101}", "\\q",
      "\\é", "\\E", "[\\b]", "[a\\A]", "[\\Qa\\E]", "[\\C]",
    ]),
    content=(
      #|(a)\1 => position 3: backreference \1 is not RE2 syntax
      #|\8 => position 0: backreference \8 is not RE2 syntax
      #|\k<a> => position 0: backreference \k is not RE2 syntax
      #|\g1 => position 0: backreference \g is not RE2 syntax
      #|(?P<a>x)(?P=a) => position 8: backreference (?P=name) is not RE2 syntax
      #|(?=a) => position 0: lookahead (?= is not RE2 syntax
      #|(?!a) => position 0: lookahead (?! is not RE2 syntax
      #|(?<=a) => position 0: lookbehind (?<= is not RE2 syntax
      #|(?<!a) => position 0: lookbehind (?<! is not RE2 syntax
      #|(?>a) => position 0: atomic group (?> is not RE2 syntax
      #|(?#note) => position 0: comment (?# is not RE2 syntax
      #|(?|a) => position 0: branch reset (?| is not RE2 syntax
      #|(?R) => position 0: recursion (?R is not RE2 syntax
      #|(?1) => position 0: recursion (?1 is not RE2 syntax
      #|(?-1) => position 0: recursion (?-1 is not RE2 syntax
      #|(?+1) => position 0: recursion (?+ is not RE2 syntax
      #|(?&a) => position 0: recursion (?& is not RE2 syntax
      #|(?P>a) => position 0: recursion (?P> is not RE2 syntax
      #|(?'a'x) => position 0: named group (?'name' is not RE2 syntax
      #|(?C1) => position 0: callout (?C is not RE2 syntax
      #|(?x)a => position 2: flag x is not RE2 syntax
      #|(?i-x)a => position 4: flag x is not RE2 syntax
      #|a++ => position 1: possessive quantifier ++ is not RE2 syntax
      #|a*+ => position 1: possessive quantifier *+ is not RE2 syntax
      #|a?+ => position 1: possessive quantifier ?+ is not RE2 syntax
      #|a{2}+ => position 1: possessive quantifier {2}+ is not RE2 syntax
      #|\Z => position 0: escape \Z is not RE2 syntax
      #|\G => position 0: escape \G is not RE2 syntax
      #|\K => position 0: escape \K is not RE2 syntax
      #|\R => position 0: escape \R is not RE2 syntax
      #|\X => position 0: escape \X is not RE2 syntax
      #|\h => position 0: escape \h is not RE2 syntax
      #|\N => position 0: escape \N is not RE2 syntax
      #|\e => position 0: escape \e is not RE2 syntax
      #|\o{101} => position 0: escape \o is not RE2 syntax
      #|\q => position 0: escape \q is not RE2 syntax
      #|\é => position 0: escape \é is not RE2 syntax
      #|\E => position 0: escape \E is not RE2 syntax
      #|[\b] => position 1: escape \b inside a character class is not RE2 syntax
      #|[a\A] => position 2: escape \A inside a character class is not RE2 syntax
      #|[\Qa\E] => position 1: escape \Q inside a character class is not RE2 syntax
      #|[\C] => position 1: escape \C inside a character class is not RE2 syntax
    ),
  )
}

///|
test "malformed patterns are rejected where the problem is" {
  inspect(
    errors([
      "a)", "a(b))", "(a", "x(?:a(b)", "(?i", "(?", "[a", "[]", "[^]", "ab[c\\]",
      "[z-a]", "[a-\\d]", "[[:foo:]]", "*", "a|*", "(*)", "(?i)*", "+a", "?", "{5}",
      "a**", "a*??", "a{2}{3}", "a{2}*", "(?P<>a)", "(?P<a", "(?P<a-b>x)", "(?P",
      "(?Px)", "(?i-)", "(?-)", "(?i$)", "ab\\",
    ]),
    content=(
      #|a) => position 1: unexpected )
      #|a(b)) => position 4: unexpected )
      #|(a => position 0: missing closing )
      #|x(?:a(b) => position 1: missing closing )
      #|(?i => position 0: missing closing )
      #|(? => position 0: missing closing )
      #|[a => position 0: missing closing ]
      #|[] => position 0: missing closing ]
      #|[^] => position 0: missing closing ]
      #|ab[c\] => position 2: missing closing ]
      #|[z-a] => position 1: invalid character class range z-a
      #|[a-\d] => position 3: \d cannot end a character class range
      #|[[:foo:]] => position 1: invalid POSIX class [:foo:]
      #|* => position 0: missing argument to repetition operator *
      #|a|* => position 2: missing argument to repetition operator *
      #|(*) => position 1: missing argument to repetition operator *
      #|(?i)* => position 4: missing argument to repetition operator *
      #|+a => position 0: missing argument to repetition operator +
      #|? => position 0: missing argument to repetition operator ?
      #|{5} => position 0: missing argument to repetition operator {5}
      #|a** => position 1: bad repetition operator **
      #|a*?? => position 1: bad repetition operator *??
      #|a{2}{3} => position 1: bad repetition operator {2}{3}
      #|a{2}* => position 1: bad repetition operator {2}*
      #|(?P<>a) => position 0: invalid named capture group (?P<>
      #|(?P<a => position 0: invalid named capture group (?P<a
      #|(?P<a-b>x) => position 0: invalid named capture group (?P<a-b>
      #|(?P => position 0: invalid group (?P
      #|(?Px) => position 0: invalid group (?Px
      #|(?i-) => position 0: invalid flags (?i-)
      #|(?-) => position 0: invalid flags (?-)
      #|(?i$) => position 0: invalid flags (?i$
      #|ab\ => position 2: trailing backslash at end of pattern
    ),
  )
}
