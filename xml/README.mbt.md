# smock/xml

A small XML parser for MoonBit that refuses DTDs, and simple paths that
select values from a parsed document. It is made for matching XML request
bodies, such as SOAP envelopes, by meaning rather than by bytes. The module
does no I/O and depends only on `moonbitlang/core`. It builds for every
MoonBit target and is tested on native and `wasm-gc`.

## Use

Parse a document once, compile each path once, then select as often as
needed. Input is UTF-8 bytes.

```mbt check
///|
test "parse once, then select several paths" {
  let document = @xml.parse(
    b"<order status='paid'><item sku='a-1'/><item sku='b-2'/></order>"[:],
  )
  let status = @xml.compile_path("/order/@status")
  let skus = @xml.compile_path("/order/item/@sku")
  debug_inspect(document.select(status), content="[\"paid\"]")
  debug_inspect(document.select(skus), content="[\"a-1\", \"b-2\"]")
}
```

- `@xml.parse(input)` returns a `Document`, or raises a `ParseError`.
- `@xml.compile_path(path)` returns a `Path`, or raises a `PathError`.
- `Document::select(path)` returns the values of the nodes the path
  selects, in document order. It returns none when the path selects
  nothing.
- A `Path` shows as it is written, and two paths are equal when they are
  written the same.

Both errors carry a position and a message, and show as
`position <n>: <message>`. A `ParseError`'s position is a byte offset into
the input, from 0. A `PathError`'s position is in characters (code points)
from 0.

```mbt check
///|
test "errors say where the problem is" {
  let message = input => {
    try @xml.parse(input) catch {
      e => e.to_string()
    } noraise {
      _ => "parsed"
    }
  }
  inspect(
    message(
      b"<!DOCTYPE a [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><a>&x;</a>",
    ),
    content="position 0: a DOCTYPE is not allowed",
  )
  inspect(
    message(b"<a><b></a>"),
    content="position 6: end tag </a> does not match start tag <b>",
  )
  let error = try @xml.compile_path("/order//item") catch {
    e => e.to_string()
  } noraise {
    _ => "compiled"
  }
  inspect(
    error,
    content="position 6: // (descendants) is not supported in smock's XML paths",
  )
}
```

## Paths

A path is `/` followed by one or more element names separated by `/`,
optionally ending in `/@` and an attribute name.

| Path | Selects |
|---|---|
| `/order` | the root element, when its local name is `order` |
| `/order/item` | every `item` child of that root element, in document order |
| `/order/item/@sku` | the `sku` attribute of each of those elements |

- Names are local names. A prefix in the document is ignored, so
  `/Envelope/Body` selects the body of a SOAP envelope whatever prefix the
  client chose. Namespace URIs are not compared, so elements that differ
  only by namespace cannot be told apart.
- Namespace declarations (`xmlns` and `xmlns:*`) are not attributes that a
  path selects, so a path that ends in `@xmlns` is a compile error.
- A path selects every element it reaches, so a repeated element gives
  one value per element.

Everything else is a compile error: `//`, wildcards (`*`, `@*`),
predicates and indexes (`[...]`), axes (`child::`), functions (`text()`),
`.` and `..`, a prefix (`/soap:Envelope`), an attribute step anywhere but
last, an empty step, and whitespace.

### Values

- An element's value is its XPath string-value, all the text in it and in
  its descendants, CDATA included, trimmed of leading and trailing XML
  whitespace (space, tab, line feed and carriage return). So an element
  that holds only text has the same value whether the XML is
  pretty-printed or compact. Whitespace between its children stays in the
  value of an element that holds other elements.
- An attribute's value is its value after XML's attribute-value
  normalisation: each tab, line feed and line end written in it is a
  space, and a character reference keeps its character. It is not
  trimmed.

```mbt check
///|
test "an element's value is its text, trimmed" {
  let document = @xml.parse(
    b"<user>\n  <name>\n    Alice\n  </name>\n  <city>Kyoto</city>\n</user>"[:],
  )
  debug_inspect(
    document.select(@xml.compile_path("/user/name")),
    content="[\"Alice\"]",
  )
  debug_inspect(
    document.select(@xml.compile_path("/user")),
    content=(
      #|["Alice\n  \n  Kyoto"]
    ),
  )
}
```

## Documents

The parser reads XML 1.0 documents that are well-formed, with these rules:

- The input is UTF-8, optionally after a byte order mark. Bytes that are
  not well-formed UTF-8 are an error, and so is an XML declaration that
  names another encoding.
- Any DOCTYPE is an error, so no entity is ever declared or expanded. The
  five predefined entities (`&lt;`, `&gt;`, `&amp;`, `&apos;`, `&quot;`)
  and character references are decoded, and any other entity reference is
  an error. This rules out external entities (XXE) and entity expansion
  bombs.
- Elements nest at most 256 deep.
- A character that XML does not allow is an error, whether it is written
  directly or as a character reference.
- Element and attribute names have at most one colon, between a prefix and
  a local name.

Comments and processing instructions are skipped, and CDATA is text. Line
ends (CR LF, or a lone CR) are read as line feeds. The XML declaration may
give a version 1.x, the encoding UTF-8 and `standalone`; it may only come
first.

Parsing does no I/O and ends with a document or an error for every
input. It takes time linear in the length of the input, except that the
attribute names of a tag with more than eight attributes are sorted, in
O(n log n) time for n attributes, to find a repeated one. The module does
not bound the size of the input; smock bounds the size of a request body.

### Differences from XML 1.0 and Namespaces in XML

- A non-validating XML processor must read a DOCTYPE's internal subset.
  This parser refuses every DOCTYPE instead, even one that declares
  nothing.
- XML processors must read UTF-16 as well as UTF-8. This parser reads UTF-8
  only.
- Prefixes are not resolved. A prefix need not be declared, `xmlns:p=""`
  is accepted, and two attributes with the same local name are accepted
  even when their prefixes are bound to the same namespace.
- Elements nest at most 256 deep.
