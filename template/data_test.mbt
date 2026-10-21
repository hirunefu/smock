// Tests of the `data` root: `data.NAME` reads a Data bucket of the Stub's
// Mock, which the template names when it is parsed, from the data a
// rendering is given. They run on native and on wasm-gc, and give the same
// output on both.

///|
/// The buckets of the Mock the templates below are parsed for.
let shop_buckets : @template.Buckets = @template.Buckets([
  "orders", "visits", "cart", "odd-name_1",
])

///|
/// The data the templates below read, by bucket name.
let shop_data : Map[String, Json] = {
  "orders": [
    { "id": 1001, "status": "paid", "total": 12.50 },
    { "id": 1002, "status": "pending", "total": 9.9 },
  ],
  "visits": 3,
  "cart": null,
  "odd-name_1": { "a b": true },
}

///|
/// A request with no body.
let orders_request : @template.Input = {
  meth: "GET",
  path: "/orders",
  query: [],
  headers: [],
  body: b"",
}

///|
/// Parses `source`, JSON text, as the `json` of a response at `/response/json`
/// for a Mock with `buckets`, and renders it reading `data`, or gives its
/// problems, one per line, or the render error.
fn with_data(
  source : String,
  buckets? : @template.Buckets = shop_buckets,
  data? : Map[String, Json],
) -> String {
  let json = @json.parse(source) catch { _ => panic() }
  match @template.Structured::parse(json, pointer="/response/json", buckets~) {
    Ok(template) => {
      let context = @template.Context::new(
        orders_request,
        now=0,
        rand=@template.helper_generator(1),
        data?,
      )
      @utf8.decode_lossy(template.render(context)) catch {
        RenderError(at~, message~) => "error at \{at}: \{message}"
      }
    }
    Err(problems) => problems.map(p => "\{p.pointer}: \{p.message}").join("\n")
  }
}

///|
test "data.NAME gives a bucket's value, and steps, $each and len read into it" {
  let template =
    #|{ "all": "${data.orders}", "first": "${data.orders[0].id}",
    #|  "quoted": "${data['orders'][1].status}", "visits": "${data.visits}",
    #|  "cart": "${data.cart}", "odd": "${data['odd-name_1']['a b']}",
    #|  "count": "${len(data.orders)}",
    #|  "ids": { "$each": "data.orders", "as": "o", "do": "${o.id}-${o.status}" },
    #|  "nowhere": "${data.orders[5].id ?? 'none'}",
    #|  "has": { "$if": "data.visits == 3", "then": "yes", "else": "no" } }
  inspect(
    with_data(template, data=shop_data),
    content=(
      #|{"all":[{"id":1001,"status":"paid","total":12.5},{"id":1002,"status":"pending","total":9.9}],"first":1001,"quoted":"pending","visits":3,"cart":null,"odd":true,"count":2,"ids":["1001-paid","1002-pending"],"nowhere":"none","has":"yes"}
    ),
  )
}

///|
test "a bucket the data does not hold is missing, so ?? applies" {
  inspect(
    [
      with_data("\"${data.visits ?? 'gone'}\"", data={ "orders": [] }),
      with_data("\"${data.visits ?? 'gone'}\""),
      with_data("\"${data.visits}\""),
      with_data("{ \"$each\": \"data.orders\", \"as\": \"o\", \"do\": 1 }"),
    ].join("\n"),
    content=(
      #|"gone"
      #|"gone"
      #|error at /response/json: data.visits is missing
      #|error at /response/json/$each: data.orders is missing
    ),
  )
}

///|
test "data takes the name of one of the Mock's buckets first, and cannot be a loop variable" {
  inspect(
    [
      with_data("\"${data}\""),
      with_data("\"${data[0]}\""),
      with_data("\"${data ?? 1}\""),
      with_data("\"${data.order}\""),
      with_data("\"${data['no such'].x ?? 1}\""),
      with_data("\"${data.orders}\"", buckets=@template.no_buckets),
      with_data("{ \"$each\": \"data.order\", \"as\": \"o\", \"do\": 1 }"),
      with_data("{ \"$each\": \"range(1, 2)\", \"as\": \"data\", \"do\": 1 }"),
      with_data("{ \"$if\": \"!data.cart\", \"then\": 1, \"else\": 2 }"),
    ].join("\n"),
    content=(
      #|/response/json: template: column 3: data: data takes the name of a Data bucket first, such as data.orders or data.orders[0].id
      #|/response/json: template: column 3: data[0]: data takes the name of a Data bucket first, such as data.orders or data.orders[0].id
      #|/response/json: template: column 3: data: data takes the name of a Data bucket first, such as data.orders or data.orders[0].id
      #|/response/json: template: column 3: data.order: the Mock has no Data bucket "order"
      #|/response/json: template: column 3: data['no such'].x: the Mock has no Data bucket "no such"
      #|/response/json: template: column 3: data.orders: the Mock has no Data bucket "orders"
      #|/response/json/$each: template: column 1: data.order: the Mock has no Data bucket "order"
      #|/response/json/as: template: "data" cannot be a loop variable: it is a request field, env, vars, data, loop or a reserved word
      #|1
    ),
  )
}

///|
test "a text template reads data too" {
  let text = (source : String) => {
    match
      @template.Text::parse(
        source,
        pointer="/response/body",
        kind=Body(Plain),
        buckets=shop_buckets,
      ) {
      Ok(template) => {
        let context = @template.Context::new(
          orders_request,
          now=0,
          rand=@template.helper_generator(1),
          data=shop_data,
        )
        template.render(context) catch {
          RenderError(at~, message~) => "error at \{at}: \{message}"
        }
      }
      Err(problem) => "\{problem.pointer}: \{problem.message}"
    }
  }
  inspect(
    [
      text("visits: ${data.visits}, first: ${data.orders[0].status}"),
      text("${json(data.orders[1])}"),
      text("${data.nope}"),
    ].join("\n"),
    content=(
      #|visits: 3, first: paid
      #|{"id":1002,"status":"pending","total":9.9}
      #|/response/body: template: column 3: data.nope: the Mock has no Data bucket "nope"
    ),
  )
}
