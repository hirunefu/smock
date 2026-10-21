// Tests of the encoding helpers, base64, base64url and percent-encoding,
// through the template package's public interface. Expected encodings come
// from RFC 4648's test vectors and the UTF-8 of the texts. They run on
// native and on wasm-gc, and give the same output on both.

///|
/// A request whose query and body hold texts to encode and decode.
let encoded : @template.Input = {
  meth: "GET",
  path: "/",
  query: [("q", "a b&c=d/é"), ("t", "Zm9vYmFy")],
  headers: [],
  body: @utf8.encode(
    (
      #|{ "cjk": "日本語", "emoji": "👍", "n": 1.50, "flag": true,
      #|  "none": null, "list": ["a"], "object": { "a": 1 },
      #|  "tabbed": "Zm9v\tYmFy" }
    ),
  ),
}

///|
test "base64 and base64url encode the UTF-8 bytes of a text; base64url writes no padding" {
  inspect(
    [
      rendered(
        "${base64('')}|${base64('f')}|${base64('fo')}|${base64('foo')}|${base64('foob')}|${base64('fooba')}|${base64('foobar')}",
        input=encoded,
      ),
      rendered(
        "${base64url('')}|${base64url('f')}|${base64url('fo')}|${base64url('foo')}|${base64url('foob')}|${base64url('fooba')}|${base64url('foobar')}",
        input=encoded,
      ),
      rendered(
        "${base64(body.cjk)} ${base64(body.emoji)} ${base64('\u{FBFF}')}",
        input=encoded,
      ),
      rendered(
        "${base64url(body.cjk)} ${base64url(body.emoji)} ${base64url('\u{FBFF}')}",
        input=encoded,
      ),
      rendered(
        "${base64(body.n)} ${base64(body.flag)} ${base64url(42)}",
        input=encoded,
      ),
      rendered("${base64(query.missing) ?? 'none'}", input=encoded),
      rendered_json("{ \"token\": \"${base64url(query.q)}\" }", input=encoded),
    ].join("\n"),
    content=(
      #||Zg==|Zm8=|Zm9v|Zm9vYg==|Zm9vYmE=|Zm9vYmFy
      #||Zg|Zm8|Zm9v|Zm9vYg|Zm9vYmE|Zm9vYmFy
      #|5pel5pys6Kqe 8J+RjQ== 76+/
      #|5pel5pys6Kqe 8J-RjQ 76-_
      #|MS41 dHJ1ZQ== NDI
      #|none
      #|{"token":"YSBiJmM9ZC_DqQ"}
    ),
  )
}

///|
test "base64Decode and base64urlDecode decode their own alphabet, with padding or without, into text" {
  inspect(
    [
      rendered(
        "${base64Decode('Zm9vYmFy')}|${base64Decode('Zm9vYg==')}|${base64Decode('Zm9vYg')}|${base64Decode('Zm9vYmE=')}|${base64Decode('Zm9vYmE')}|${base64Decode('')}|",
        input=encoded,
      ),
      rendered(
        "${base64urlDecode('Zm9vYmFy')}|${base64urlDecode('Zm9vYg==')}|${base64urlDecode('Zm9vYg')}|${base64urlDecode('Zm9vYmE=')}|${base64urlDecode('')}|",
        input=encoded,
      ),
      rendered(
        "${base64Decode('76+/')} ${base64urlDecode('76-_')} ${base64Decode(base64(body.cjk))} ${base64urlDecode(base64url(body.emoji))} ${base64Decode(query.t)}",
        input=encoded,
      ),
      rendered(
        "${base64Decode('Zh==')} ${base64urlDecode('Zh')}",
        input=encoded,
      ),
      rendered(
        "${base64Decode('/w==')}|${base64Decode('gIA=')}|${base64urlDecode('YeKC')}",
        input=encoded,
      ),
      rendered("${base64Decode(query.missing) ?? 'none'}", input=encoded),
      rendered_json(
        "{ \"text\": \"${base64urlDecode(base64url(query.q))}\" }",
        input=encoded,
      ),
    ].join("\n"),
    content=(
      #|foobar|foob|foob|fooba|fooba||
      #|foobar|foob|foob|fooba||
      #|ﯿ ﯿ 日本語 👍 foobar
      #|f f
      #|�|��|a�
      #|none
      #|{"text":"a b&c=d/é"}
    ),
  )
}

///|
test "a decoder refuses a character outside its alphabet, whitespace included, and padding that is incomplete, too long or before the end" {
  inspect(
    [
      rendered("${base64Decode('76-_')}", input=encoded),
      rendered("${base64urlDecode('76+/')}", input=encoded),
      rendered("${base64Decode('Zm9v YmFy')}", input=encoded),
      rendered("${base64Decode(body.tabbed)}", input=encoded),
      rendered("${base64urlDecode(body.cjk)}", input=encoded),
      rendered("${base64Decode('8J+RjQ==!')}", input=encoded),
      rendered("${base64Decode('Zg==Zg==')}", input=encoded),
      rendered("${base64urlDecode('Zm9v=YmFy')}", input=encoded),
      rendered("${base64Decode('Zm9vYg=')}", input=encoded),
      rendered("${base64Decode('Zm9vYmE==')}", input=encoded),
      rendered("${base64urlDecode('Zm9vYg===')}", input=encoded),
      rendered("${base64Decode('Zm9vYmFy=')}", input=encoded),
      rendered("${base64urlDecode('==')}", input=encoded),
      rendered("${base64Decode('Zm9vY')}", input=encoded),
      rendered("${base64urlDecode('Z===')}", input=encoded),
      rendered("${base64Decode(body.none)}", input=encoded),
      rendered("${base64urlDecode(body.list)}", input=encoded),
      rendered("${base64Decode(null)}", input=encoded),
      rendered("${base64urlDecode()}", input=encoded),
    ].join("\n"),
    content=(
      #|error at /response/body: base64Decode(): character 3, "-", is not in the base64 alphabet
      #|error at /response/body: base64urlDecode(): character 3, "+", is not in the base64url alphabet
      #|error at /response/body: base64Decode(): character 5, " ", is not in the base64 alphabet
      #|error at /response/body: base64Decode(): character 5, "\t", is not in the base64 alphabet
      #|error at /response/body: base64urlDecode(): character 1, "日", is not in the base64url alphabet
      #|error at /response/body: base64Decode(): character 9, "!", is not in the base64 alphabet
      #|error at /response/body: base64Decode(): character 3, "=", is padding before the end
      #|error at /response/body: base64urlDecode(): character 5, "=", is padding before the end
      #|error at /response/body: base64Decode(): the padding has 1 "=", but a last group of 2 characters takes 2 or none
      #|error at /response/body: base64Decode(): the padding has 2 "=", but a last group of 3 characters takes 1 or none
      #|error at /response/body: base64urlDecode(): the padding has 3 "=", but a last group of 2 characters takes 2 or none
      #|error at /response/body: base64Decode(): the padding has 1 "=", but whole groups of 4 characters take none
      #|error at /response/body: base64urlDecode(): the padding has 2 "=", but whole groups of 4 characters take none
      #|error at /response/body: base64Decode(): the last group has 1 character, too few for a byte
      #|error at /response/body: base64urlDecode(): the last group has 1 character, too few for a byte
      #|error at /response/body: base64Decode(): argument 1 must be a string, a number or a boolean, not null
      #|error at /response/body: base64urlDecode(): argument 1 must be a string, a number or a boolean, not an array
      #|problem at /response/body: template: column 16: base64Decode(): argument 1 must be a string, a number or a boolean, not null
      #|problem at /response/body: template: column 3: base64urlDecode() takes 1 argument, not 0
    ),
  )
}

///|
test "urlEncode percent-encodes the UTF-8 bytes of a text with upper-case hex digits, leaving only the unreserved characters" {
  inspect(
    [
      rendered(
        "${urlEncode(query.q)} ${urlEncode('-._~AZaz09')} ${urlEncode(body.cjk)} ${urlEncode(body.emoji)}",
        input=encoded,
      ),
      rendered(
        "${urlEncode('+!*\\'()')} ${urlEncode('100%')} ${urlEncode('')}| ${urlEncode(body.n)} ${urlEncode(body.flag)}",
        input=encoded,
      ),
      rendered("${urlEncode(query.missing) ?? 'none'}", input=encoded),
      rendered_json("{ \"next\": \"${urlEncode(query.q)}\" }", input=encoded),
      rendered("${urlEncode(body.object)}", input=encoded),
      rendered("${urlEncode(null)}", input=encoded),
      rendered("${urlEncode('a', 'b')}", input=encoded),
    ].join("\n"),
    content=(
      #|a%20b%26c%3Dd%2F%C3%A9 -._~AZaz09 %E6%97%A5%E6%9C%AC%E8%AA%9E %F0%9F%91%8D
      #|%2B%21%2A%27%28%29 100%25 | 1.5 true
      #|none
      #|{"next":"a%20b%26c%3Dd%2F%C3%A9"}
      #|error at /response/body: urlEncode(): argument 1 must be a string, a number or a boolean, not an object
      #|problem at /response/body: template: column 13: urlEncode(): argument 1 must be a string, a number or a boolean, not null
      #|problem at /response/body: template: column 3: urlEncode() takes 1 argument, not 2
    ),
  )
}

///|
test "urlDecode decodes percent-escapes in either case and keeps + as it is; a malformed escape is an error" {
  inspect(
    [
      rendered(
        "${urlDecode('%41%42')} ${urlDecode('%e6%97%a5%E6%9C%AC')} ${urlDecode('a+b%2Bc')} [${urlDecode('a%20b')}] ${urlDecode(body.cjk)} ${urlDecode('')}|",
        input=encoded,
      ),
      rendered(
        "${urlDecode(urlEncode(query.q))} ${urlDecode(urlEncode(body.emoji))} ${urlDecode(42)}",
        input=encoded,
      ),
      rendered("${urlDecode('%FF')}|${urlDecode('a%E6%97b')}", input=encoded),
      rendered("${urlDecode(query.missing) ?? 'none'}", input=encoded),
      rendered("${urlDecode('100%')}", input=encoded),
      rendered("${urlDecode('%4')}", input=encoded),
      rendered("${urlDecode('a%G1')}", input=encoded),
      rendered("${urlDecode('日%%41')}", input=encoded),
      rendered("${urlDecode(body.list)}", input=encoded),
      rendered("${urlDecode(null)}", input=encoded),
    ].join("\n"),
    content=(
      #|AB 日本 a+b+c [a b] 日本語 |
      #|a b&c=d/é 👍 42
      #|�|a�b
      #|none
      #|error at /response/body: urlDecode(): character 4, "%", is not followed by two hex digits
      #|error at /response/body: urlDecode(): character 1, "%", is not followed by two hex digits
      #|error at /response/body: urlDecode(): character 2, "%", is not followed by two hex digits
      #|error at /response/body: urlDecode(): character 2, "%", is not followed by two hex digits
      #|error at /response/body: urlDecode(): argument 1 must be a string, a number or a boolean, not an array
      #|problem at /response/body: template: column 13: urlDecode(): argument 1 must be a string, a number or a boolean, not null
    ),
  )
}

///|
/// A request whose body is `s` repeated `n` times.
fn repeated(s : String, n : Int) -> @template.Input {
  { ..request, body: @utf8.encode(s.repeat(n)), }
}

///|
test "an encoding helper whose result takes more than 1 MiB of UTF-8 is a render error" {
  let length = (source : String, input : @template.Input) => {
    let out = rendered(source, input~)
    if out.has_prefix("error") {
      out
    } else {
      "\{@utf8.encode(out).length()} bytes"
    }
  }
  inspect(
    [
      length("${base64(bodyText)}", repeated("x", 786432)),
      length("${base64(bodyText)}", repeated("x", 786433)),
      length("${base64url(bodyText)}", repeated("x", 786432)),
      length("${base64url(bodyText)}", repeated("x", 786433)),
      length("${base64Decode(bodyText)}", repeated("AAAA", 349525)),
      length("${base64Decode(bodyText)}", repeated("AAAA", 349526)),
      length("${base64urlDecode(bodyText)}", repeated("____", 116508)),
      length("${base64urlDecode(bodyText)}", repeated("____", 116509)),
      length("${urlEncode(bodyText)}", repeated("x", 1048576)),
      length("${urlEncode(bodyText)}", repeated(" ", 349526)),
      length("${urlDecode(bodyText)}", repeated("%41", 1048576)),
      length("${urlDecode(bodyText)}", repeated("x", 1048577)),
      length("${urlDecode(bodyText)}", repeated("%FF", 349525)),
      length("${urlDecode(bodyText)}", repeated("%FF", 349526)),
    ].join("\n"),
    content=(
      #|1048576 bytes
      #|error at /response/body: base64(): the result takes more than 1 MiB
      #|1048576 bytes
      #|error at /response/body: base64url(): the result takes more than 1 MiB
      #|1048575 bytes
      #|error at /response/body: base64Decode(): the result takes more than 1 MiB
      #|1048572 bytes
      #|error at /response/body: base64urlDecode(): the result takes more than 1 MiB
      #|1048576 bytes
      #|error at /response/body: urlEncode(): the result takes more than 1 MiB
      #|1048576 bytes
      #|error at /response/body: urlDecode(): the result takes more than 1 MiB
      #|1048575 bytes
      #|error at /response/body: urlDecode(): the result takes more than 1 MiB
    ),
  )
}
