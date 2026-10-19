// The conformance table: for each construct of smock's RE2 subset,
// patterns with the result RE2 gives for them. Each row is
//
//   (pattern, input, leftmost match as "start-end" byte offsets or "none",
//    whether the pattern matches the whole input)
//
// The expected results are RE2's: every row was checked against RE2
// (release 2024-07-02, through the google-re2 Python package) with
// `re2.search` and `re2.fullmatch` on the UTF-8 bytes of the pattern and the
// input.

///|
let rows : Array[(String, String, String, Bool)] = [
  // Literals and escaped metacharacters
  ("abc", "abc", "0-3", true),
  ("abc", "xabcabc", "1-4", false),
  ("abc", "ab", "none", false),
  ("", "", "0-0", true),
  ("", "abc", "0-0", false),
  ("a\\.c", "a.c", "0-3", true),
  ("a\\.c", "abc", "none", false),
  ("\\*\\+\\?\\(\\)\\[\\]\\{\\}\\|\\^\\$\\\\", "*+?()[]{}|^$\\", "0-13", true),
  ("\\-\\/\\_\\ \\#", "-/_ #", "0-5", true),
  ("é", "café", "3-5", false),
  ("😀", "a😀", "1-5", false),
  ("a{", "a{", "0-2", true),
  ("a{,3}", "a{,3}", "0-5", true),
  ("a{x}", "a{x}", "0-4", true),
  ("a{01}", "a{01}", "0-5", true),
  ("a{1, 2}", "a{1, 2}", "0-7", true),
  ("}", "}", "0-1", true),
  ("]", "]", "0-1", true),
  // . matches one code point other than \n
  (".", "a", "0-1", true),
  (".", "", "none", false),
  (".", "\n", "none", false),
  ("a.c", "a\nc", "none", false),
  ("a.c", "a\rc", "0-3", true),
  (".", "é", "0-2", true),
  ("..", "é", "none", false),
  ("a.c", "a😀c", "0-6", true),
  ("...", "a😀c", "0-6", true),
  ("\\.", "a", "none", false),
  // Bracket classes: ranges, negation, ] and - as literals
  ("[abc]", "b", "0-1", true),
  ("[abc]", "d", "none", false),
  ("[a-c][x-z]", "by", "0-2", true),
  ("[a-c][x-z]", "bw", "none", false),
  ("[a-cx-z]", "y", "0-1", true),
  ("[^a-c]", "d", "0-1", true),
  ("[^a-c]", "b", "none", false),
  ("[^a]", "\n", "0-1", true),
  ("[^a]", "é", "0-2", true),
  ("[é-ë]", "ê", "0-2", true),
  ("[é-ë]", "e", "none", false),
  ("[]a]", "]", "0-1", true),
  ("[^]a]", "b", "0-1", true),
  ("[^]a]", "]", "none", false),
  ("[a-]", "-", "0-1", true),
  ("[-a]", "-", "0-1", true),
  ("[a-b-c]", "-", "0-1", true),
  ("[a-b-c]", "c", "0-1", true),
  ("[a-a]", "a", "0-1", true),
  ("[\\]]", "]", "0-1", true),
  ("[\\-]", "-", "0-1", true),
  ("[\\\\]", "\\", "0-1", true),
  ("[\\^]", "^", "0-1", true),
  ("[.]", "a", "none", false),
  ("[.]", ".", "0-1", true),
  ("[[:alpha]", "p", "0-1", true),
  ("[[:alpha]", "b", "none", false),
  // Perl classes, ASCII only, also inside brackets
  ("\\d", "7", "0-1", true),
  ("\\d", "a", "none", false),
  ("\\d", "٣", "none", false),
  ("\\D", "a", "0-1", true),
  ("\\D", "7", "none", false),
  ("\\D", "\n", "0-1", true),
  ("\\w", "_", "0-1", true),
  ("\\w", "Z", "0-1", true),
  ("\\w", "é", "none", false),
  ("\\W", "é", "0-2", true),
  ("\\W", "-", "0-1", true),
  ("\\W", "a", "none", false),
  ("\\s", " ", "0-1", true),
  ("\\s", "\t", "0-1", true),
  ("\\s", "\n", "0-1", true),
  ("\\s", "\r", "0-1", true),
  ("\\s", "\u{0c}", "0-1", true),
  ("\\s", "\u{0b}", "none", false),
  ("\\s", "\u{a0}", "none", false),
  ("\\S", "\u{0b}", "0-1", true),
  ("\\S", " ", "none", false),
  ("[\\d]", "5", "0-1", true),
  ("[\\da-f]", "c", "0-1", true),
  ("[^\\d]", "a", "0-1", true),
  ("[^\\d]", "5", "none", false),
  ("[\\D]", "x", "0-1", true),
  ("[^\\D]", "5", "0-1", true),
  ("[^\\D]", "x", "none", false),
  ("[\\s\\d]", " ", "0-1", true),
  ("[\\d-z]", "-", "0-1", true),
  ("[\\d-z]", "y", "none", false),
  ("[\\w-]", "-", "0-1", true),
  // Anchors without (?m): ^ and $ match only at the ends of the input
  ("^abc", "abc", "0-3", true),
  ("^abc", "xabc", "none", false),
  ("^", "abc", "0-0", false),
  ("^", "", "0-0", true),
  ("a^b", "ab", "none", false),
  ("abc$", "abc", "0-3", true),
  ("abc$", "xabc", "1-4", false),
  ("abc$", "abc\n", "none", false),
  ("$", "abc", "3-3", false),
  ("x$", "x\ny", "none", false),
  ("^y", "x\ny", "none", false),
  ("^$", "", "0-0", true),
  ("^$", "\n", "none", false),
  ("\\Aabc", "abc", "0-3", true),
  ("\\Aabc", "\nabc", "none", false),
  ("abc\\z", "xabc", "1-4", false),
  ("abc\\z", "abc\n", "none", false),
  // Word boundaries, with ASCII word characters
  ("\\bfoo\\b", "a foo b", "2-5", false),
  ("\\bfoo\\b", "afoo", "none", false),
  ("\\bfoo\\b", "foo", "0-3", true),
  ("\\b_\\b", "a _ b", "2-3", false),
  ("a\\b", "a-", "0-1", false),
  ("\\Bfoo", "afoo", "1-4", false),
  ("\\Bo\\B", "foo", "1-2", false),
  ("\\b", "", "none", false),
  ("\\B", "", "0-0", true),
  ("\\b", "é", "none", false),
  ("\\B", "é", "0-0", false),
  ("\\bé", "aé", "1-3", false),
  ("é\\b", "éa", "0-2", false),
  // Groups and alternation: the leftmost match, then the first alternative
  ("a|b", "b", "0-1", true),
  ("b|a", "ab", "0-1", false),
  ("a|ab", "ab", "0-1", true),
  ("ab|a", "ab", "0-2", true),
  ("foo|foobar", "foobar", "0-3", true),
  ("foobar|foo", "foobar", "0-6", true),
  ("x(a|ab)", "xab", "0-2", true),
  ("x(?:ab|a)", "xab", "0-3", true),
  ("a(?:b|c)d", "acd", "0-3", true),
  ("a(?:b|c)d", "aed", "none", false),
  ("(a|b)(c|d)", "bd", "0-2", true),
  ("((a)|b)c", "bc", "0-2", true),
  ("(a|b|c)", "c", "0-1", true),
  ("(a)(b)", "ab", "0-2", true),
  ("(?P<word>ab)c", "abc", "0-3", true),
  ("(?P<1>a)", "a", "0-1", true),
  ("(?P<n>)", "", "0-0", true),
  ("a|", "b", "0-0", false),
  ("|a", "a", "0-0", true),
  ("a||b", "b", "0-0", true),
  ("()", "", "0-0", true),
  ("(?:)", "x", "0-0", false),
  ("^a|b$", "xb", "1-2", false),
  ("(^a|b)c", "xbc", "1-3", false),
  // Quantifiers: greedy and lazy spans
  ("a*", "aaa", "0-3", true),
  ("a*", "baaa", "0-0", false),
  ("a*?", "aaa", "0-0", true),
  ("a+", "baaa", "1-4", false),
  ("a+?", "baaa", "1-2", false),
  ("a?", "a", "0-1", true),
  ("a??", "a", "0-0", true),
  ("ba?", "ba", "0-2", true),
  ("ba??", "ba", "0-1", true),
  ("a{2}", "aaa", "0-2", false),
  ("a{2}?", "aaa", "0-2", false),
  ("a{2}", "a", "none", false),
  ("a{2,}", "aaaa", "0-4", true),
  ("a{2,}?", "aaaa", "0-2", true),
  ("a{2,3}", "aaaa", "0-3", false),
  ("a{2,3}?", "aaaa", "0-2", false),
  ("a{0}", "a", "0-0", false),
  ("a{0,0}b", "ab", "1-2", false),
  ("a{1}", "aa", "0-1", false),
  ("a{0,1}", "a", "0-1", true),
  ("a{0,2}?b", "aab", "0-3", true),
  ("[a-c]{3}", "abcd", "0-3", false),
  ("(?:a{2}){3}", "aaaaaaa", "0-6", false),
  ("é+", "ééx", "0-4", false),
  ("\\d+", "ab123c", "2-5", false),
  ("(ab)*", "ababx", "0-4", false),
  ("(ab)*?", "abab", "0-0", true),
  ("(?:ab)+?c", "ababc", "0-5", true),
  ("a.*b", "axbxb", "0-5", true),
  ("a.*?b", "axbxb", "0-3", true),
  ("<.+>", "<a><b>", "0-6", true),
  ("<.+?>", "<a><b>", "0-3", true),
  ("(a|ab)*c", "abac", "0-4", true),
  ("(a+|b+)*c", "aabbc", "0-5", true),
  ("(?:a+)+", "aaa", "0-3", true),
  ("(?:a+?)+?", "aaa", "0-1", true),
  ("x*y*", "", "0-0", true),
  ("^*a", "a", "0-1", true),
  ("\\b*a", "a", "0-1", true),
  // Repeating a subexpression that can match empty keeps RE2's preferences
  ("(|a)*", "aa", "0-0", true),
  ("(|a)+", "aa", "0-0", true),
  ("(a|)*", "aa", "0-2", true),
  ("(a*)*", "b", "0-0", false),
  ("(a*)+", "aa", "0-2", true),
  ("(a*?)*", "aa", "0-0", true),
  ("(a*)*?", "aa", "0-0", true),
  ("(a?)*?b", "aab", "0-3", true),
  ("(?:a*|b)*", "ab", "0-2", true),
  ("(?:|a)*?b", "aab", "0-3", true),
  ("(?:|a){2,}", "aa", "0-0", true),
  ("(?:|a){0,3}", "aa", "0-0", true),
  ("(?:a|){0,3}", "aaaa", "0-3", false),
  ("(?:)*", "a", "0-0", false),
  ("(|)+", "", "0-0", true),
  ("(?:$)*a", "a", "0-1", true),
  ("(?:^)+a", "ba", "none", false),
  ("(?:\\b)*a", "a", "0-1", true),
  // A class can be empty
  ("[^\\D\\d]", "a", "none", false),
  ("a[^\\D\\d]|b", "ab", "1-2", false),
  // (?i): ASCII case-insensitive
  ("(?i)abc", "ABC", "0-3", true),
  ("(?i)abc", "xaBc", "1-4", false),
  ("(?i)ABC", "abc", "0-3", true),
  ("(?i)a1_", "A1_", "0-3", true),
  ("(?i)[a-c]+", "AbC", "0-3", true),
  ("(?i)[K-M]", "l", "0-1", true),
  ("(?i)[^a]", "A", "none", false),
  ("(?i)[^a]", "b", "0-1", true),
  ("(?i)\\w", "K", "0-1", true),
  ("(?i)\\W", "k", "none", false),
  ("(?i)\\d", "D", "none", false),
  ("a(?i)b", "aB", "0-2", true),
  ("a(?i)b", "AB", "none", false),
  ("(?i:a)b", "Ab", "0-2", true),
  ("(?i:a)b", "AB", "none", false),
  ("(?i)a(?-i)b", "Ab", "0-2", true),
  ("(?i)a(?-i)b", "AB", "none", false),
  ("(?i)a(?-i:b)c", "AbC", "0-3", true),
  ("x(?i)y|z", "Z", "0-1", true),
  ("(?:a(?i)b)c", "aBC", "none", false),
  ("(?:a(?i)b)c", "aBc", "0-3", true),
  ("(?i-i)a", "A", "none", false),
  ("(?ii)a", "A", "0-1", true),
  ("(?)a", "a", "0-1", true),
  ("a(?i)*", "aaa", "0-3", true),
  // (?s): . also matches \n
  ("(?s).", "\n", "0-1", true),
  ("(?s)a.c", "a\nc", "0-3", true),
  ("(?s:.)\\.", "\n.", "0-2", true),
  ("(?s)(?-s).", "\n", "none", false),
  ("(?s)[^a]", "\n", "0-1", true),
  // (?m): ^ and $ also match at line boundaries
  ("(?m)^b", "a\nb", "2-3", false),
  ("(?m)a$", "a\nb", "0-1", false),
  ("(?m)$", "a\nb", "1-1", false),
  ("(?m)^$", "a\n\nb", "2-2", false),
  ("(?m)^", "a\n", "0-0", false),
  ("(?m)^b$", "b\n", "0-1", false),
  ("(?m).$", "ab\ncd", "1-2", false),
  ("(?m:^b)", "a\nb", "2-3", false),
  ("(?m)\\Ab", "a\nb", "none", false),
  ("(?m)a\\z", "a\nb", "none", false),
  ("(?m)^a$\n^b$", "a\nb", "0-3", true),
  ("(?m)(?-m)^b", "a\nb", "none", false),
  // Flags together
  ("(?ims)^A.B$", "x\na\nb", "2-5", false),
  ("(?im-s)^a.$", "A\nb", "none", false),
  ("(?s-i:a.)B", "a\nB", "0-3", true),
]

///|
fn show_match(m : @re2.Match?) -> String {
  match m {
    Some({ start, end, }) => "\{start}-\{end}"
    None => "none"
  }
}

///|
test "conformance: each construct of the subset has RE2's meaning" {
  let failures : Array[String] = []
  for row in rows {
    let (pattern, input, want_search, want_full) = row
    let re = @re2.compile(pattern) catch {
      e => {
        failures.push("\{pattern}: \{e}")
        continue
      }
    }
    let bytes = @utf8.encode(input)
    let got_search = show_match(re.search(bytes[:]))
    let got_full = re.full_match(bytes[:])
    if got_search != want_search || got_full != want_full {
      failures.push(
        "\{repr(pattern)} on \{repr(input)}: search \{got_search} (want \{want_search}), full_match \{got_full} (want \{want_full})",
      )
    }
  }
  inspect(failures.join("\n"), content="")
}

///|
fn repr(s : String) -> String {
  let b = StringBuilder()
  b.write_char('"')
  for c in s {
    match c {
      '\n' => b.write_string("\\n")
      '\r' => b.write_string("\\r")
      '"' => b.write_string("\\\"")
      '\\' => b.write_string("\\\\")
      _ => b.write_char(c)
    }
  }
  b.write_char('"')
  b.to_string()
}
