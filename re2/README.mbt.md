# smock/re2

RE2-syntax regular expressions for MoonBit, matched in time linear in the
length of the input, so that no pattern can make matching stall. The module
does no I/O and depends only on `moonbitlang/core`. It builds for every
MoonBit target and is tested on native and `wasm-gc`.

It supports a subset of RE2 syntax, listed below, with RE2's meaning for
each construct. Everything else is a compile error
that says where in the pattern the problem is.

## Use

Compile a pattern once, then match it as often as needed. Input is UTF-8
bytes.

```mbt check
///|
test "compile once, match many times" {
  let re = @re2.compile("^/users/\\d+$")
  assert_true(re.full_match(b"/users/42"[:]))
  assert_false(re.full_match(b"/users/me"[:]))
}
```

- `@re2.compile(pattern)` returns a `Regex`, or raises a `CompileError`.
- `Regex::full_match(input)` reports whether the pattern matches the whole
  input.
- `Regex::search(input)` returns the leftmost match as a `Match`, whose
  `start` and `end` are byte offsets into the input, or `None`.

```mbt check
///|
test "search returns the leftmost match" {
  let re = @re2.compile("b+")
  debug_inspect(re.search(b"abbbc"[:]), content="Some({ start: 1, end: 4 })")
  debug_inspect(re.search(b"ac"[:]), content="None")
}
```

A `CompileError` carries the position of the problem, in characters (code
points) from 0, and a message. Shown, it reads `position <n>: <message>`.

```mbt check
///|
test "compile errors say where the problem is" {
  let error = try @re2.compile("ab(c") catch {
    e => e.to_string()
  } noraise {
    _ => "compiled"
  }
  inspect(error, content="position 2: missing closing )")
}
```

## Syntax in the subset

| Construct | Meaning |
|---|---|
| `x` | the character `x` (any character that is not a metacharacter) |
| `\.` | an escaped ASCII punctuation character stands for itself: `\\ \. \* \+ \? \( \) \[ \] \{ \} \| \^ \$ \-` and so on |
| `.` | any character but `\n`; any character with `(?s)` |
| `[abc]` `[a-z]` `[^a-z]` | a bracket class, with ranges and negation; `]` first and `-` first or last are literals |
| `\d` `\w` `\s` | ASCII digit `[0-9]`, word character `[0-9A-Za-z_]`, space `[\t\n\f\r ]`; also inside brackets |
| `\D` `\W` `\S` | their negations |
| `^` `$` | beginning and end of the input; also of each line with `(?m)` |
| `\A` `\z` | beginning and end of the input, always |
| `\b` `\B` | at an ASCII word boundary, not at one |
| `(re)` `(?P<name>re)` | a group, capturing or named; names are ASCII letters, digits and `_` |
| `(?:re)` | a non-capturing group |
| `x\|y` | `x` or `y`, preferring `x` |
| `x*` `x+` `x?` | zero or more, one or more, zero or one, preferring more |
| `x{n}` `x{n,}` `x{n,m}` | exactly `n`, at least `n`, `n` to `m`, preferring more; counts up to 1000 |
| `x*?` `x+?` `x??` `x{n,}?` `x{n,m}?` | the same, preferring fewer |
| `(?i)` `(?s)` `(?m)` | flags until the end of the group: ASCII case-insensitive, `.` matches `\n`, `^` and `$` match at lines |
| `(?is-m)` `(?i:re)` | several flags at once, `-` clears them, `:` limits them to `re` |

A `{` that does not start a valid counted repetition is a literal, as in RE2.

### Matching

- A search returns RE2's leftmost-first match: the leftmost one, and among
  those the one that the order of the alternatives and the greediness of
  the repetitions prefer, as in Perl. It is not the longest match.
- `full_match` is true when any way of matching the pattern spans the whole
  input, as RE2's `FullMatch`.
- Input is UTF-8 and is matched by character (code point): `.` and classes
  consume one character, whatever its length in bytes. Matches start and end
  only at character boundaries.
- A byte that is not part of well-formed UTF-8 is not a character. Nothing in
  a pattern consumes it: `.`, negated classes and `\W` do not match it, so no
  match contains it, and input that contains one never matches as a whole.
  Searching goes on around it without an error. Such a byte is not a word
  character for `\b`.

```mbt check
///|
test "invalid UTF-8 is not matched, but searched around" {
  let re = @re2.compile("(?s).+")
  debug_inspect(re.search(b"ab\xffcd"[:]), content="Some({ start: 0, end: 2 })")
  assert_false(re.full_match(b"ab\xffcd"[:]))
}
```

### Not in the subset

RE2 syntax that the subset leaves out is a compile error whose message says it
is not supported in smock's RE2 subset:

- Unicode classes `\pL`, `\p{Greek}`, `\PL`, and Unicode case folding: `(?i)`
  folds ASCII letters only;
- the escapes `\a \f \t \n \r \v`, octal `\0` and `\123`, hexadecimal `\x41`
  and `\x{263a}`;
- `\Q...\E`, `\C`, POSIX classes such as `[[:alpha:]]`, the `U` flag,
  `(?<name>re)` and non-ASCII group names.

Syntax RE2 does not have is a compile error whose message says it is not RE2
syntax: backreferences (`\1`, `\k<name>`, `(?P=name)`), lookahead and
lookbehind, atomic groups, possessive quantifiers, recursion, comments,
`\Z`, `\G` and other escapes RE2 does not define.

```mbt check
///|
test "what the subset and RE2 leave out" {
  let message = pattern => {
    try @re2.compile(pattern) catch {
      e => e.to_string()
    } noraise {
      _ => "compiled"
    }
  }
  inspect(
    message("\\p{Greek}"),
    content="position 0: Unicode class \\p{Greek} is not supported in smock's RE2 subset",
  )
  inspect(
    message("(a)\\1"),
    content="position 3: backreference \\1 is not RE2 syntax",
  )
}
```

### Limits

Compiling is bounded as well as matching:

- a repetition count is at most 1000, as in RE2;
- nested counted repetitions multiply their counts, and the product is at
  most 1000, as in RE2 (`(a{10}){100}` compiles, `(a{10}){101}` does not);
- a compiled program has at most 100 000 instructions (about one per
  character, class and assertion, after expanding counted repetitions);
- groups nest at most 100 deep.

## Linear time

Matching is a Pike VM: it follows every way through the compiled program in
lockstep, one input character at a time, and never backtracks. The work per
input character is bounded by the size of the program, so matching time
grows linearly with the length of the input for every pattern, including
patterns such as `(a+)+$` that take exponential time in backtracking
matchers.

`full_match` only needs to know whether some way spans the input, so it
runs a DFA instead: each set of places the Pike VM's threads can be at is
one state, built from the program the first time an input reaches it and
then looked up, so that most characters cost one table lookup. The states a
regex keeps are bounded (128 KiB); a pattern that would need more, such as
`(a|b)*a(a|b){14}`, drops its DFA and runs the Pike VM from then on. Either
way the time stays linear in the length of the input.

`Regex::search_steps(input)` and `Regex::full_match_steps(input)` count the
steps the Pike VM takes (one per instruction visited). The tests use them to
check linear growth on pathological patterns without timing anything.

## Differences from RE2

Besides what the subset leaves out:

- RE2 matches bytes, so an empty match can fall inside a multi-byte
  character: RE2 finds `\B` in `aé` between the two bytes of `é`. Here
  matches start and end at character boundaries only, so `\B` is found after
  `é`.
- RE2 reads some ill-formed UTF-8 as one character: overlong three- and
  four-byte encodings, surrogates and code points past U+10FFFF. Here only
  well-formed UTF-8 is a character.
- RE2 accepts groups nested deeper than 100 and larger programs.
