// What `@xml.parse` refuses, and at which byte, through the module's
// public interface. The conditions it refuses come from XML 1.0,
// Namespaces in XML 1.0, RFC 3629 and the README's Documents.
//
// The README words two of the messages: "a DOCTYPE is not allowed" and
// "end tag </a> does not match start tag <b>". No document words the
// others. Their words are the code's, and the maintainer, who confirmed
// on 2026-11-21 that they stay as the code has them (#325), is their
// source: five first ("expected version in the XML declaration", "XML
// version <v> is not supported", "U+0000 is not a character XML allows",
// "the input is not UTF-8" and "attribute <name> is repeated"), then, in
// a second round, every other text of the parser but three, with
// "U+<hex> is not a character XML allows" for every code point and
// "&#<n>; is not a character XML allows" for a character reference. The
// three, which no source words yet, are "encoding <e> is not supported;
// the input must be UTF-8", "processing instruction target <t> is
// reserved" and "only comments, processing instructions and whitespace
// may follow the root element". What a cut-off `<?xml` gets is a defect
// that #430 records. The condition each message reports keeps the source
// its test cites.
//
// The positions the tests pin follow the README's rule for where a
// ParseError is and which one is reported (in its Use, after what the
// errors carry): a byte that cannot be where it is, at that byte; a
// construct refused as a whole, at its first byte; and when the input
// breaks more than one rule, the error found first reading from the left.

///|
/// Parses `input` and shows the error, or `parsed`.
fn error_of(input : Bytes) -> String {
  try @xml.parse(input) catch {
    error => error.to_string()
  } noraise {
    _ => "parsed"
  }
}

///|
/// Parses each text, encoded as UTF-8, and shows `text => error`, one per
/// line.
fn errors(texts : Array[String]) -> String {
  texts.map(text => "\{text} => \{error_of(@utf8.encode(text))}").join("\n")
}

///|
test "any DOCTYPE is rejected, so no entity is declared or expanded" {
  inspect(
    errors([
      "<!DOCTYPE a><a/>", "<?xml version=\"1.0\"?> <!DOCTYPE a SYSTEM \"file:///etc/passwd\"><a/>",
      "<!DOCTYPE a [<!ENTITY x \"y\">]><a>&x;</a>", "<!-- c --><!DOCTYPE a><a/>",
      "<a><!DOCTYPE a></a>",
    ]),
    content=(
      #|<!DOCTYPE a><a/> => position 0: a DOCTYPE is not allowed
      #|<?xml version="1.0"?> <!DOCTYPE a SYSTEM "file:///etc/passwd"><a/> => position 22: a DOCTYPE is not allowed
      #|<!DOCTYPE a [<!ENTITY x "y">]><a>&x;</a> => position 0: a DOCTYPE is not allowed
      #|<!-- c --><!DOCTYPE a><a/> => position 10: a DOCTYPE is not allowed
      #|<a><!DOCTYPE a></a> => position 3: a DOCTYPE is not allowed
    ),
  )
}

///|
test "an XML declaration that names an encoding other than UTF-8 is rejected" {
  inspect(
    errors([
      "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a/>", "<?xml version=\"1.0\" encoding='UTF-16'?><a/>",
      "<?xml version=\"1.0\" encoding=\"US-ASCII\"?><a/>", "<?xml version=\"1.0\" encoding=\"UTF8\"?><a/>",
    ]),
    content=(
      #|<?xml version="1.0" encoding="ISO-8859-1"?><a/> => position 30: encoding ISO-8859-1 is not supported; the input must be UTF-8
      #|<?xml version="1.0" encoding='UTF-16'?><a/> => position 30: encoding UTF-16 is not supported; the input must be UTF-8
      #|<?xml version="1.0" encoding="US-ASCII"?><a/> => position 30: encoding US-ASCII is not supported; the input must be UTF-8
      #|<?xml version="1.0" encoding="UTF8"?><a/> => position 30: encoding UTF8 is not supported; the input must be UTF-8
    ),
  )
}

///|
test "input that is not well-formed UTF-8 is rejected where the bad byte is" {
  inspect(
    error_of(b"<a>caf\xE9</a>"),
    content="position 6: the input is not UTF-8",
  )
  inspect(
    error_of(b"\xFF\xFE<\x00a\x00/\x00>\x00"),
    content="position 0: the input is not UTF-8",
  )
  inspect(
    error_of(b"\xFE\xFF\x00<\x00a\x00/\x00>"),
    content="position 0: the input is not UTF-8",
  )
  inspect(
    error_of(b"<a v='\xE3\x81'/>"),
    content="position 6: the input is not UTF-8",
  )
  // An overlong encoding of <, and an encoded surrogate.
  inspect(
    error_of(b"<a>\xC0\xBC</a>"),
    content="position 3: the input is not UTF-8",
  )
  inspect(
    error_of(b"<a>\xED\xA0\x80</a>"),
    content="position 3: the input is not UTF-8",
  )
  inspect(
    error_of(b"<a\xC3\xA9 b\xE9='1'/>"),
    content="position 6: the input is not UTF-8",
  )
  // After the root element too, where only comments, processing
  // instructions and whitespace may follow it (XML 1.0 §2.8 [27]).
  inspect(error_of(b"<a/>\xE9"), content="position 4: the input is not UTF-8")
}

///|
/// `depth` elements `a`, each inside the one before.
fn nested(depth : Int32) -> String {
  "<a>".repeat(depth) + "</a>".repeat(depth)
}

///|
test "elements nested deeper than 256 are rejected" {
  inspect(error_of(@utf8.encode(nested(256))), content="parsed")
  // The 257th start tag begins after 256 start tags of 3 bytes.
  inspect(
    error_of(@utf8.encode(nested(257))),
    content="position 768: elements nest deeper than 256",
  )
  inspect(
    error_of(@utf8.encode("<a>".repeat(256) + "<a/>")),
    content="position 768: elements nest deeper than 256",
  )
  inspect(
    error_of(@utf8.encode(nested(100_000))),
    content="position 768: elements nest deeper than 256",
  )
}

///|
test "an entity other than the five predefined ones is rejected, as are malformed references" {
  inspect(
    errors([
      "<a>&nbsp;</a>", "<a v='&x;'/>", "<a>&lt</a>", "<a>a & b</a>", "<a v='&'/>",
      "<a>&#;</a>", "<a>&#x;</a>", "<a>&#X41;</a>", "<a>&#x4G;</a>", "<a>&#65</a>",
    ]),
    content=(
      #|<a>&nbsp;</a> => position 3: entity &nbsp; is not declared
      #|<a v='&x;'/> => position 6: entity &x; is not declared
      #|<a>&lt</a> => position 6: expected ; to end the reference
      #|<a>a & b</a> => position 5: & starts a reference; write &amp; for &
      #|<a v='&'/> => position 6: & starts a reference; write &amp; for &
      #|<a>&#;</a> => position 5: expected a decimal digit
      #|<a>&#x;</a> => position 6: expected a hexadecimal digit
      #|<a>&#X41;</a> => position 5: expected a decimal digit
      #|<a>&#x4G;</a> => position 7: expected ; to end the reference
      #|<a>&#65</a> => position 7: expected ; to end the reference
    ),
  )
  // A `&` that ends the input, in text or in an attribute value, starts no
  // reference either: a name or `#` must follow it (XML 1.0 §4.1 [67],
  // [68]), and a `&` may not stand for itself (§2.4). The error is at it,
  // as for `a & b` and `v='&'` above: parsing ends with an error for every
  // input (the README's Documents). Python's expat 2.10.0 refuses both.
  inspect(
    errors(["<a>&", "<a v='&"]),
    content=(
      #|<a>& => position 3: & starts a reference; write &amp; for &
      #|<a v='& => position 6: & starts a reference; write &amp; for &
    ),
  )
}

///|
test "a character reference to a character XML does not allow is rejected" {
  inspect(
    errors([
      "<a>&#0;</a>", "<a>&#x8;</a>", "<a>&#xD800;</a>", "<a>&#xDFFF;</a>", "<a>&#xFFFE;</a>",
      "<a>&#xFFFF;</a>", "<a>&#x110000;</a>", "<a>&#99999999999999999999;</a>", "<a v='&#x1F;'/>",
    ]),
    content=(
      #|<a>&#0;</a> => position 3: &#0; is not a character XML allows
      #|<a>&#x8;</a> => position 3: &#x8; is not a character XML allows
      #|<a>&#xD800;</a> => position 3: &#xD800; is not a character XML allows
      #|<a>&#xDFFF;</a> => position 3: &#xDFFF; is not a character XML allows
      #|<a>&#xFFFE;</a> => position 3: &#xFFFE; is not a character XML allows
      #|<a>&#xFFFF;</a> => position 3: &#xFFFF; is not a character XML allows
      #|<a>&#x110000;</a> => position 3: &#x110000; is not a character XML allows
      #|<a>&#99999999999999999999;</a> => position 3: &#99999999999999999999; is not a character XML allows
      #|<a v='&#x1F;'/> => position 6: &#x1F; is not a character XML allows
    ),
  )
  // The ends of Char's ranges as hexadecimal references (XML 1.0 §2.2 [2]:
  // #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]),
  // their letters in lower case and in upper case, as §4.1 [66] allows both
  // ('&#x' [0-9a-fA-F]+ ';'): each is a character XML allows, and the code
  // points just outside the ranges are not (WFC: Legal Character). Python's
  // expat 2.10.0 accepts and refuses the same references.
  inspect(
    errors([
      "<a>&#x9;</a>", "<a>&#xa;</a>", "<a>&#xA;</a>", "<a>&#xd;</a>", "<a>&#xD;</a>",
      "<a>&#x20;</a>", "<a>&#xd7ff;</a>", "<a>&#xD7FF;</a>", "<a>&#xe000;</a>", "<a>&#xE000;</a>",
      "<a>&#xfffd;</a>", "<a>&#xFFFD;</a>", "<a>&#x10000;</a>", "<a>&#x10ffff;</a>",
      "<a>&#x10FFFF;</a>", "<a>&#xb;</a>", "<a>&#xC;</a>", "<a>&#xe;</a>", "<a>&#x1f;</a>",
      "<a>&#xd800;</a>", "<a>&#xdfff;</a>", "<a>&#xfffe;</a>", "<a>&#xffff;</a>",
    ]),
    content=(
      #|<a>&#x9;</a> => parsed
      #|<a>&#xa;</a> => parsed
      #|<a>&#xA;</a> => parsed
      #|<a>&#xd;</a> => parsed
      #|<a>&#xD;</a> => parsed
      #|<a>&#x20;</a> => parsed
      #|<a>&#xd7ff;</a> => parsed
      #|<a>&#xD7FF;</a> => parsed
      #|<a>&#xe000;</a> => parsed
      #|<a>&#xE000;</a> => parsed
      #|<a>&#xfffd;</a> => parsed
      #|<a>&#xFFFD;</a> => parsed
      #|<a>&#x10000;</a> => parsed
      #|<a>&#x10ffff;</a> => parsed
      #|<a>&#x10FFFF;</a> => parsed
      #|<a>&#xb;</a> => position 3: &#xb; is not a character XML allows
      #|<a>&#xC;</a> => position 3: &#xC; is not a character XML allows
      #|<a>&#xe;</a> => position 3: &#xe; is not a character XML allows
      #|<a>&#x1f;</a> => position 3: &#x1f; is not a character XML allows
      #|<a>&#xd800;</a> => position 3: &#xd800; is not a character XML allows
      #|<a>&#xdfff;</a> => position 3: &#xdfff; is not a character XML allows
      #|<a>&#xfffe;</a> => position 3: &#xfffe; is not a character XML allows
      #|<a>&#xffff;</a> => position 3: &#xffff; is not a character XML allows
    ),
  )
}

///|
/// Parses `text`, encoded as UTF-8, and shows the error, or `parsed`.
fn text_error(text : String) -> String {
  error_of(@utf8.encode(text))
}

///|
test "a character XML does not allow is rejected wherever it is" {
  let not_allowed = "is not a character XML allows"
  inspect(
    text_error("<a>\u{1}</a>"),
    content="position 3: U+0001 \{not_allowed}",
  )
  inspect(
    text_error("<a v='x\u{0}'/>"),
    content="position 7: U+0000 \{not_allowed}",
  )
  inspect(
    text_error("<!--\u{B}--><a/>"),
    content="position 4: U+000B \{not_allowed}",
  )
  inspect(
    text_error("<a><![CDATA[\u{FFFE}]]></a>"),
    content="position 12: U+FFFE \{not_allowed}",
  )
  inspect(
    text_error("<?pi \u{1F}?><a/>"),
    content="position 5: U+001F \{not_allowed}",
  )
  inspect(
    text_error("<a>\u{FFFF}</a>"),
    content="position 3: U+FFFF \{not_allowed}",
  )
  inspect(
    text_error("<a><!-- \u{1B} --></a>"),
    content="position 8: U+001B \{not_allowed}",
  )
  // U+0000, the first code point, is not one either (XML 1.0 §2.2 [2]),
  // and it does not end the input: in a processing instruction, in a value
  // of the XML declaration, and after the root element, where only
  // comments, processing instructions and whitespace may follow (§2.8
  // [27]), the error is at its byte, as anywhere else.
  inspect(
    text_error("<?pi \u{0}?><a/>"),
    content="position 5: U+0000 \{not_allowed}",
  )
  inspect(
    text_error("<?xml version='\u{0}'?><a/>"),
    content="position 15: U+0000 \{not_allowed}",
  )
  inspect(text_error("<a/>\u{0}"), content="position 4: U+0000 \{not_allowed}")
}

///|
test "a document needs exactly one root element, with only markup around it" {
  inspect(
    errors([
      "", "   ", "<!-- only a comment -->", "text<a/>", "<a/>text", "<a/><b/>", "<a/><![CDATA[x]]>",
      "<a/>&amp;",
    ]),
    content=(
      #| => position 0: no root element
      #|    => position 3: no root element
      #|<!-- only a comment --> => position 23: no root element
      #|text<a/> => position 0: text is not allowed before the root element
      #|<a/>text => position 4: only comments, processing instructions and whitespace may follow the root element
      #|<a/><b/> => position 4: only comments, processing instructions and whitespace may follow the root element
      #|<a/><![CDATA[x]]> => position 4: only comments, processing instructions and whitespace may follow the root element
      #|<a/>&amp; => position 4: only comments, processing instructions and whitespace may follow the root element
    ),
  )
}

///|
test "tags must be well-formed and nest properly" {
  inspect(
    errors([
      "<a>", "<a><b></a>", "<a></b>", "<a></a x>", "<a></a >", "<1a/>", "<a b='1' b='2'/>",
      "<a p:b='1' q:b='2' p:b='3'/>", "<a b='1'c='2'/>", "<a b/>", "<a b=1/>", "<a b='<'/>",
      "<a b='1", "<a", "<a/", "< a/>",
    ]),
    content=(
      #|<a> => position 0: element a is not closed
      #|<a><b></a> => position 6: end tag </a> does not match start tag <b>
      #|<a></b> => position 3: end tag </b> does not match start tag <a>
      #|<a></a x> => position 7: expected >
      #|<a></a > => parsed
      #|<1a/> => position 1: expected a name
      #|<a b='1' b='2'/> => position 9: attribute b is repeated
      #|<a p:b='1' q:b='2' p:b='3'/> => position 19: attribute p:b is repeated
      #|<a b='1'c='2'/> => position 8: expected whitespace, > or />
      #|<a b/> => position 4: expected =
      #|<a b=1/> => position 5: expected a quoted attribute value
      #|<a b='<'/> => position 6: < is not allowed in an attribute value; write &lt;
      #|<a b='1 => position 5: an attribute value is not closed
      #|<a => position 2: expected whitespace, > or />
      #|<a/ => position 2: expected whitespace, > or />
      #|< a/> => position 1: expected a name
    ),
  )
}

///|
test "a repeated attribute is found among many" {
  let many = StringBuilder()
  many.write_string("<a")
  for i in 0..<1000 {
    many.write_string(" a\{i}=''")
  }
  inspect(text_error(many.to_string() + "/>"), content="parsed")
  // a5 and a7 are both repeated at the end; a5 comes first.
  let repeated = many.to_string() + " a5='' a7=''/>"
  let offset = repeated.length() - " a5='' a7=''/>".length() + 1
  inspect(
    text_error(repeated),
    content="position \{offset}: attribute a5 is repeated",
  )
  // The names of a tag with more than eight attributes are sorted to find
  // a repeated one (the README's Documents), and a few are checked in
  // place. At eight attributes and at nine, whichever name the last one
  // repeats, the error is at it (XML 1.0 §3.1, WFC: Unique Att Spec).
  let names = ["a", "b", "c", "d", "e", "f", "g", "h"]
  for count in [8, 9] {
    let tag = StringBuilder()
    tag.write_string("<t")
    for name in names[:count - 1] {
      tag.write_string(" \{name}=''")
    }
    let before = tag.to_string()
    for name in names[:count - 1] {
      inspect(
        text_error(before + " \{name}=''/>"),
        content="position \{before.length() + 1}: attribute \{name} is repeated",
      )
    }
  }
}

///|
test "text, comments, CDATA sections and processing instructions must be well-formed" {
  inspect(
    errors([
      "<a>]]></a>", "<a>]] ]></a>", "<a><!-- a -- b --></a>", "<a><!-- x ---></a>",
      "<a><![CDATA[x</a>", "<a><!-- x</a>", "<a><?pi x</a>", "<a><?pi?></a>", "<a><?pi?x?></a>",
      "<a><? pi?></a>", "<a><!x></a>", "<a><![CDATA [x]]></a>",
    ]),
    content=(
      #|<a>]]></a> => position 3: ]]> is not allowed in text
      #|<a>]] ]></a> => parsed
      #|<a><!-- a -- b --></a> => position 10: -- is not allowed in a comment
      #|<a><!-- x ---></a> => position 10: -- is not allowed in a comment
      #|<a><![CDATA[x</a> => position 3: a CDATA section is not closed
      #|<a><!-- x</a> => position 3: a comment is not closed
      #|<a><?pi x</a> => position 3: a processing instruction is not closed
      #|<a><?pi?></a> => parsed
      #|<a><?pi?x?></a> => position 7: expected whitespace or ?>
      #|<a><? pi?></a> => position 5: expected a name
      #|<a><!x></a> => position 3: expected a comment or a CDATA section after <!
      #|<a><![CDATA [x]]></a> => position 3: expected a comment or a CDATA section after <!
    ),
  )
}

///|
/// The last case is a value of the declaration without quotes, which
/// XML 1.0 §2.8 [24] forbids: `VersionInfo ::= S 'version' Eq ("'"
/// VersionNum "'" | '"' VersionNum '"')`, as [80] and [32] quote the
/// encoding and standalone values. Its error is at the byte where the
/// quote is missing, as `ParseError`'s position is documented, and its
/// message is the one #283 names: "expected a quoted value".
test "an XML declaration must come first, and be well-formed" {
  inspect(
    errors([
      " <?xml version='1.0'?><a/>", "<a><?xml version='1.0'?></a>", "<?XML version='1.0'?><a/>",
      "<a/><?Xml?>", "<?xml?><a/>", "<?xml encoding='UTF-8'?><a/>", "<?xml version='2.0'?><a/>",
      "<?xml version='1.'?><a/>", "<?xml version=\"1.0'?><a/>", "<?xml version='1.0' standalone='maybe'?><a/>",
      "<?xml version='1.0' encoding='UTF-8' version='1.0'?><a/>", "<?xml version='1.0'encoding='UTF-8'?><a/>",
      "<?xml version='1.0' standalone='yes' encoding='UTF-8'?><a/>", "<?xml version=1.0?><a/>",
    ]),
    content=(
      #| <?xml version='1.0'?><a/> => position 1: the XML declaration must come first
      #|<a><?xml version='1.0'?></a> => position 3: the XML declaration must come first
      #|<?XML version='1.0'?><a/> => position 2: processing instruction target XML is reserved
      #|<a/><?Xml?> => position 6: processing instruction target Xml is reserved
      #|<?xml?><a/> => position 5: expected version in the XML declaration
      #|<?xml encoding='UTF-8'?><a/> => position 6: expected version in the XML declaration
      #|<?xml version='2.0'?><a/> => position 15: XML version 2.0 is not supported
      #|<?xml version='1.'?><a/> => position 15: XML version 1. is not supported
      #|<?xml version="1.0'?><a/> => position 14: a quoted value is not closed
      #|<?xml version='1.0' standalone='maybe'?><a/> => position 32: standalone must be yes or no
      #|<?xml version='1.0' encoding='UTF-8' version='1.0'?><a/> => position 37: expected ?> to end the XML declaration
      #|<?xml version='1.0'encoding='UTF-8'?><a/> => position 19: expected ?> to end the XML declaration
      #|<?xml version='1.0' standalone='yes' encoding='UTF-8'?><a/> => position 37: expected ?> to end the XML declaration
      #|<?xml version=1.0?><a/> => position 14: expected a quoted value
    ),
  )
  // Cut off one byte after `<?xml`, the declaration still lacks its
  // version where XML 1.0 §2.8 [24] puts it, after whitespace: the error
  // is the one `<?xml?><a/>` gives above, at the `?`, or at the input's
  // end after the space.
  inspect(
    errors(["<?xml?", "<?xml "]),
    content=(
      #|<?xml? => position 5: expected version in the XML declaration
      #|<?xml  => position 6: expected version in the XML declaration
    ),
  )
  // A version is `1.` and one or more digits (§2.8 [26]): the characters
  // just before `0` and just after `9`, and a letter after a digit, make
  // none, and the error is where `2.0` and `1.` have it above.
  inspect(
    errors([
      "<?xml version='1./'?><a/>", "<?xml version='1.:'?><a/>", "<?xml version='1.0a'?><a/>",
    ]),
    content=(
      #|<?xml version='1./'?><a/> => position 15: XML version 1./ is not supported
      #|<?xml version='1.:'?><a/> => position 15: XML version 1.: is not supported
      #|<?xml version='1.0a'?><a/> => position 15: XML version 1.0a is not supported
    ),
  )
  // Cut off right after `<?xml`, at the start or after a byte order mark,
  // the input holds no declaration, which needs whitespace and a version
  // there (§2.8 [23], [24]), and no root element (§2.1 [1]); parsing
  // ends with an error for every input (the README's Documents). Only the
  // refusal is asserted. The message both get today is a defect that #430
  // records, as the maintainer decided on 2026-11-21: no test pins it, and
  // #430's fix gives them their message and its tests.
  for input in [b"<?xml", b"\xEF\xBB\xBF<?xml"] {
    assert_true(error_of(input) != "parsed")
  }
  // Only `xml` in some case is reserved among processing instruction
  // targets (XML 1.0 §2.6 [17]: PITarget ::= Name - (('X' | 'x') ('M' |
  // 'm') ('L' | 'l'))), as `XML` and `Xml` are above: a target one letter
  // away from it in either case, or one letter shorter or longer, is a
  // target like any other. Python's expat 2.10.0 reads each.
  inspect(
    errors([
      "<a/><?wml?>", "<a/><?yml?>", "<a/><?xll?>", "<a/><?xnl?>", "<a/><?xmk?>",
      "<a/><?xmm?>", "<a/><?WML?>", "<a/><?YML?>", "<a/><?XLL?>", "<a/><?XNL?>",
      "<a/><?XMK?>", "<a/><?XMM?>", "<a/><?xm?>", "<a/><?xmlx?>",
    ]),
    content=(
      #|<a/><?wml?> => parsed
      #|<a/><?yml?> => parsed
      #|<a/><?xll?> => parsed
      #|<a/><?xnl?> => parsed
      #|<a/><?xmk?> => parsed
      #|<a/><?xmm?> => parsed
      #|<a/><?WML?> => parsed
      #|<a/><?YML?> => parsed
      #|<a/><?XLL?> => parsed
      #|<a/><?XNL?> => parsed
      #|<a/><?XMK?> => parsed
      #|<a/><?XMM?> => parsed
      #|<a/><?xm?> => parsed
      #|<a/><?xmlx?> => parsed
    ),
  )
}

///|
test "element and attribute names are a local name with at most one prefix" {
  inspect(
    errors([
      "<a:b:c/>", "<:a/>", "<a:/>", "<a b:='1'/>", "<a :b='1'/>", "<a x:y:z='1'/>",
    ]),
    content=(
      #|<a:b:c/> => position 1: name a:b:c has more than one colon
      #|<:a/> => position 1: name :a has an empty prefix
      #|<a:/> => position 1: name a: has an empty local name
      #|<a b:='1'/> => position 3: name b: has an empty local name
      #|<a :b='1'/> => position 3: name :b has an empty prefix
      #|<a x:y:z='1'/> => position 3: name x:y:z has more than one colon
    ),
  )
  // Two colons side by side are two colons too: the prefix and the local
  // part are NCNames, which hold none (Namespaces in XML 1.0 §4 [8], [10],
  // [11]; the README's Documents: at most one colon). Python's expat 2.10.0
  // refuses each, with namespaces on.
  inspect(
    errors(["<a::b/>", "<a::/>", "<a x::y='1'/>"]),
    content=(
      #|<a::b/> => position 1: name a::b has more than one colon
      #|<a::/> => position 1: name a:: has more than one colon
      #|<a x::y='1'/> => position 3: name x::y has more than one colon
    ),
  )
}

///|
test "UTF-8 of every length is read in text, names and attribute values; overlong, surrogate, out-of-range and cut-off sequences are rejected" {
  let read = @xml.parse(
    b"<\xC3\xA9 a='\xE2\x82\xAC'>\xF0\x9F\x98\x80\xC3\xA9</\xC3\xA9>",
  )
  debug_inspect(
    [
      read.select(@xml.compile_path("/é")),
      read.select(@xml.compile_path("/é/@a")),
    ],
    content=(
      #|[["😀é"], ["€"]]
    ),
  )
  // The first and the last character of each row of RFC 3629's syntax
  // (§4), each in an element of its own: U+007F, the last of UTF8-1; U+0080
  // and U+07FF, UTF8-2; U+0800 and U+0FFF after E0, U+1000 and U+CFFF after
  // E1 to EC, U+D000 and U+D7FF after ED, U+E000 and U+FFFD after EE and EF
  // (U+FFFE and U+FFFF are no characters XML allows); U+10000 and U+3FFFF
  // after F0, U+40000 and U+FFFFF after F1 to F3, U+100000 and U+10FFFF
  // after F4. XML 1.0 §2.2 [2] allows each of them, though it discourages
  // U+007F, U+0080, U+3FFFF, U+FFFFF and U+10FFFF.
  let edges = @xml.parse(
    b"<r><c>\x7F</c><c>\xC2\x80</c><c>\xDF\xBF</c><c>\xE0\xA0\x80</c><c>\xE0\xBF\xBF</c><c>\xE1\x80\x80</c><c>\xEC\xBF\xBF</c><c>\xED\x80\x80</c><c>\xED\x9F\xBF</c><c>\xEE\x80\x80</c><c>\xEF\xBF\xBD</c><c>\xF0\x90\x80\x80</c><c>\xF0\xBF\xBF\xBF</c><c>\xF1\x80\x80\x80</c><c>\xF3\xBF\xBF\xBF</c><c>\xF4\x80\x80\x80</c><c>\xF4\x8F\xBF\xBF</c></r>",
  )
  assert_eq(edges.select(@xml.compile_path("/r/c")), [
    "\u{7F}", "\u{80}", "\u{7FF}", "\u{800}", "\u{FFF}", "\u{1000}", "\u{CFFF}",
    "\u{D000}", "\u{D7FF}", "\u{E000}", "\u{FFFD}", "\u{10000}", "\u{3FFFF}", "\u{40000}",
    "\u{FFFFF}", "\u{100000}", "\u{10FFFF}",
  ])
  // The last six have a tail byte past BF (RFC 3629 §4: UTF8-tail is
  // %x80-BF), in each place that a tail may be.
  let rejected = [
    b"<a>\x80</a>", b"<a>\xC1\xBF</a>", b"<a>\xE0\x9F\xBF</a>", b"<a>\xF0\x8F\xBF\xBF</a>",
    b"<a>\xF4\x90\x80\x80</a>", b"<a>\xF5\x80\x80\x80</a>", b"<a>\xED\xBF\xBF</a>",
    b"<a>\xE2\x82</a>", b"<a>\xF0\x9F\x98</a>", b"<a\xE2\x82/>", b"<a>\xE2\x82",
    b"<a>\xC2\xC0</a>", b"<a>\xE1\xC0\x80</a>", b"<a>\xE1\x80\xC0</a>", b"<a>\xF1\xC0\x80\x80</a>",
    b"<a>\xF1\x80\xC0\x80</a>", b"<a>\xF1\x80\x80\xC0</a>",
  ]
  inspect(
    rejected.map(error_of).join("\n"),
    content=(
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 2: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
      #|position 3: the input is not UTF-8
    ),
  )
  // A reference's name starts with any name character, ASCII or not.
  // After `&`, the byte FF starts no name, and it is not UTF-8 either
  // (RFC 3629 §1): the input breaks two rules, and by the README's rule
  // the error found first reading from the left is reported, at the `&`,
  // which starts no reference.
  inspect(
    [error_of(b"<a>&\xC3\xA9;</a>"), error_of(b"<a>&\xFF;</a>")].join("\n"),
    content=(
      #|position 3: entity &é; is not declared
      #|position 3: & starts a reference; write &amp; for &
    ),
  )
}
