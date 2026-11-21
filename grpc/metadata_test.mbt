// The rules of metadata, through the module's public interface: the names
// gRPC's grammar allows and those it reserves, the values of ASCII
// metadata, binary metadata in base64, and a call's binary metadata
// without its padding. The expected values follow
// gRPC's HTTP/2 protocol document
// (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md): a
// Header-Name is 1 or more of `0-9`, `a-z`, `_`, `-` and `.`; an
// ASCII-Value holds characters from 0x20 to 0x7E; a Binary-Header's name
// ends with `-bin` and its value is base64, padded or not.

///|
test "a metadata name holds only 0-9, a-z, _, - and ., at least one of them" {
  for name in ["x-trace", "trace-bin", "a.b_c-9", "0", "-", ".", "_"] {
    inspect(@grpc.is_metadata_name(name), content="true")
  }
  // Upper case, a space, a colon, a slash, other token characters, non-ASCII
  // letters and the empty name are outside the grammar.
  for name in ["X-Trace", "x trace", ":path", "a/b", "x!y", "x~y", "é", ""] {
    inspect(@grpc.is_metadata_name(name), content="false")
  }
}

///|
test "gRPC reserves content-type, te and every name that starts with grpc-" {
  for name in ["content-type", "te", "grpc-status", "grpc-foo", "grpc-"] {
    inspect(@grpc.is_reserved_name(name), content="true")
  }
  for name in ["x-content-type", "tea", "t", "grpc", "my-grpc-foo", "grpcx"] {
    inspect(@grpc.is_reserved_name(name), content="false")
  }
}

///|
test "a binary metadata name ends with -bin" {
  for name in ["trace-bin", "-bin", "x.y-bin"] {
    inspect(@grpc.is_binary_name(name), content="true")
  }
  for name in ["bin", "trace_bin", "trace-binary", "trace-bin.x"] {
    inspect(@grpc.is_binary_name(name), content="false")
  }
}

///|
test "an ASCII metadata value holds only characters from 0x20 to 0x7E, and may be empty" {
  let printable = StringBuilder()
  for code in 0x20..<=0x7E {
    printable.write_char(code.unsafe_to_char())
  }
  inspect(@grpc.is_ascii_value(printable.to_string()), content="true")
  inspect(@grpc.is_ascii_value(""), content="true")
  for value in ["a\tb", "a\nb", "\u{1f}", "\u{7f}", "é", "☺", "😈"] {
    inspect(@grpc.is_ascii_value(value), content="false")
  }
}

///|
test "a binary metadata value is standard base64, padded or not, and loses its padding" {
  let unpadded = (value : String) => {
    match @grpc.unpadded_base64(value) {
      Some(view) => view.to_owned()
      None => "not base64"
    }
  }
  inspect(unpadded("AAE="), content="AAE")
  inspect(unpadded("AAE"), content="AAE")
  inspect(unpadded("AA=="), content="AA")
  inspect(unpadded("AA"), content="AA")
  inspect(unpadded("+/8="), content="+/8")
  inspect(unpadded("AAAA"), content="AAAA")
  inspect(unpadded("AAAABBB="), content="AAAABBB")
  inspect(unpadded(""), content="")
}

///|
test "a binary metadata value that is not base64 has no unpadded form" {
  for
    value in [
      "A", "AAAAB", "AA=", "A===", "AAE==", "AA==A", "=", "==", "AA=A", "-_8", "AA E",
      " AAE", "AAE=,AAE=", "AAÉ",
    ] {
    inspect(@grpc.unpadded_base64(value) is None, content="true")
  }
}

///|
test "a call's binary metadata loses the padding that ends each comma-separated element, commas kept, without being checked as base64" {
  inspect(@grpc.unpadded_elements("AAE="), content="AAE")
  inspect(@grpc.unpadded_elements("AA=="), content="AA")
  // A proxy may join repeated fields with commas.
  inspect(@grpc.unpadded_elements("AAA=,BBB="), content="AAA,BBB")
  inspect(@grpc.unpadded_elements("AA==,AAAA,B="), content="AA,AAAA,B")
  inspect(@grpc.unpadded_elements("AAA=, BBB="), content="AAA, BBB")
  // Only the `=` that end an element are padding; nothing is decoded.
  inspect(@grpc.unpadded_elements("AA=A"), content="AA=A")
  // The value is split at each comma, as PROTOCOL-HTTP2 has it
  // ("Implementations must split Binary-Headers on "," before decoding"),
  // so the first element is `AAA= `, which ends with a space, not with `=`,
  // and keeps its padding. HTTP's list syntax, with optional spaces around
  // each comma (RFC 9110, section 5.6.1), is not applied. The maintainer
  // confirmed that reading on 2026-11-21 (#327).
  inspect(@grpc.unpadded_elements("AAA= ,B"), content="AAA= ,B")
  inspect(@grpc.unpadded_elements("not base64!="), content="not base64!")
  inspect(@grpc.unpadded_elements("=,==,"), content=",,")
  inspect(@grpc.unpadded_elements(""), content="")
  // docs/grpc/metadata-and-status.md: "A call's `-bin` value loses the `=`
  // that end each comma-separated element, and keeps the commas." The
  // first element ends with `=` here even when that `=` is the value's
  // first character, and no other element has padding.
  inspect(@grpc.unpadded_elements("="), content="")
  inspect(@grpc.unpadded_elements("=,AA"), content=",AA")
}

///|
test "a call's binary metadata without padding is the very value, not a copy" {
  for value in ["AAE", "AAA,BBB", "", ",", "AA=A", "AAAA,BBBB"] {
    inspect(
      physical_equal(@grpc.unpadded_elements(value), value),
      content="true",
    )
  }
}
