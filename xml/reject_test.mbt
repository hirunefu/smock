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
}

///|
/// `depth` elements `a`, each inside the one before.
fn nested(depth : Int) -> String {
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
test "an XML declaration must come first, and be well-formed" {
  inspect(
    errors([
      " <?xml version='1.0'?><a/>", "<a><?xml version='1.0'?></a>", "<?XML version='1.0'?><a/>",
      "<a/><?Xml?>", "<?xml?><a/>", "<?xml encoding='UTF-8'?><a/>", "<?xml version='2.0'?><a/>",
      "<?xml version='1.'?><a/>", "<?xml version=\"1.0'?><a/>", "<?xml version='1.0' standalone='maybe'?><a/>",
      "<?xml version='1.0' encoding='UTF-8' version='1.0'?><a/>", "<?xml version='1.0'encoding='UTF-8'?><a/>",
      "<?xml version='1.0' standalone='yes' encoding='UTF-8'?><a/>",
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
}
