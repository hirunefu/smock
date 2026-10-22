#!/usr/bin/env python3
"""Writes the release benchmark's definition set, bench/definitions/, its
Scenario variant, bench/definitions-scenarios/, and its CRUD variant,
bench/definitions-crud/, with the CRUD variant's request mix,
bench/requests-crud.json.

The set stands in for four services of a shop, each a Mock with its own
Host, with about 1,200 Stubs in all (e2e/bench_test.mbt pins the exact
count). Most Stubs have an exact path, so the match index finds them; a
few have path, query, header or body patterns, or `json` body conditions,
which smock tries in their place in the order:

- catalog (catalog.bench.internal): 600 items by SKU, a search with query
  patterns whose results come from a body file, and two path patterns;
- users (users.bench.internal): 300 profiles that need a bearer token
  (a header pattern), and two path patterns;
- orders (orders.bench.internal): 48 ways to create an order, told apart
  by `json` body conditions, an order by ID (a path pattern) and a status
  update (a path pattern and a body pattern);
- payments (payments.bench.internal), the Default Mock: six currencies to
  pay in (`json` body conditions and a header pattern) and 200 payments by
  ID.

Every Mock keeps its Journal on, as smock does by default. The requests
that bench/bench.py sends are in bench/requests.json; e2e/bench_test.mbt
checks that each one reaches the Stub it names.

The Scenario variant is the same set, but each Stub that a request of the
mix names has a Scenario clause named for the request, which requires
`Started` and moves to `Seen`, and right after it a twin, `<id>-seen`, with
the same request and response, which requires `Seen` and moves back to
`Started`. Each request carries its own Session, so its Scenario is its
own: the two Stubs take turns, and every request of the mix matches one of
them and moves its Scenario, in every Mock. bench/bench.py serves it with
`--definitions bench/definitions-scenarios`; e2e/bench_test.mbt checks that
each request moves its Scenario.

The CRUD variant is the same set, but the catalog's items and the orders
are Data buckets, each served by a CRUD Stub in place of the Stubs that
answered them one by one: `items` (keyed by `sku`, the 600 items that the
item Stubs answered, in their order), through `catalog-items` at
`/catalog/items`, where those Stubs were; and `orders` (keyed by `id`, an
order for each of the 48 ways to create one, the mix's order among them),
through `orders` at `/orders`, right after the Stubs that create an order
and in place of `get-order`. A POST to `/orders` still matches a create
Stub first, so the CRUD Stub never creates. Its request mix,
bench/requests-crud.json, is bench/requests.json, but the catalog search
becomes `catalog-list`, a list query, and the status update becomes
`update-order`, a PATCH of the order: the CRUD Stubs list, read and update
items, and no request creates one. bench/bench.py sends that mix when it
serves the variant, with `--definitions bench/definitions-crud`;
e2e/bench_test.mbt checks that each of its requests gets the CRUD operation
its `expect.crud` names.

The files are checked in. Run this script again after changing it, and
commit what it writes.

usage: python3 bench/gen_definitions.py [--check]
  --check  writes nothing; exits 1 if a file of the sets or the CRUD mix
           differs from what it would write
"""

import json
import re
import sys
import uuid
from itertools import product
from pathlib import Path

BENCH = Path(__file__).resolve().parent

# Each set's directory, by its name under bench/.
SETS = ("definitions", "definitions-scenarios", "definitions-crud")

# The request mix of the CRUD variant, by its name under bench/.
CRUD_MIX = "requests-crud.json"

JSON_HEADERS = {"Content-Type": "application/json", "Cache-Control": "no-store"}
UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
CATEGORIES = ["lighting", "furniture", "kitchen", "garden", "office", "storage"]
CHANNELS = ["web", "app", "partner", "pos", "call-center", "kiosk"]
TIERS = ["bronze", "silver", "gold", "platinum", "staff", "trial", "b2b", "vip"]
CURRENCIES = ["USD", "GBP", "JPY", "EUR", "CHF", "SEK"]
ORDER_STATUSES = ["created", "paid", "shipped", "delivered", "cancelled"]

# The order that the requests of the mix read and update.
ORDER = "7f9c2ba4-e88f-4c1a-9c5b-2d3a1e8f6b10"

# That order, as get-order answers it.
MIX_ORDER = {"id": ORDER, "status": "paid", "total": {"amount": 10597, "currency": "EUR"}}

# Each CRUD Stub's headers besides those smock sets, as the Stubs it takes
# the place of answer.
CRUD_HEADERS = {"Cache-Control": "no-store"}


def body(value):
    """A response body: `value` as compact JSON."""
    return json.dumps(value, separators=(",", ":"))


def mocks():
    return {
        "mocks": [
            {"name": "catalog", "hosts": ["catalog.bench.internal"]},
            {"name": "users", "hosts": ["users.bench.internal"]},
            {"name": "orders", "hosts": ["orders.bench.internal"]},
            {"name": "payments", "hosts": ["payments.bench.internal"], "default": True},
        ]
    }


def catalog_items():
    """The catalog's 600 items, in order."""
    return [
        {
            "sku": f"SKU-{i:05d}",
            "name": f"Item {i}",
            "category": CATEGORIES[i % len(CATEGORIES)],
            "price": {"amount": 499 + (i * 37) % 9500, "currency": "EUR"},
            "stock": (i * 13) % 50,
        }
        for i in range(1, 601)
    ]


def catalog():
    stubs = []
    for i, item in enumerate(catalog_items(), start=1):
        stubs.append(
            {
                "id": f"catalog-item-{i:05d}",
                "mock": "catalog",
                "request": {"method": "GET", "path": f"/catalog/items/{item['sku']}"},
                "response": {"status": 200, "headers": JSON_HEADERS, "body": body(item)},
            }
        )
    stubs += [
        {
            "id": "catalog-search",
            "mock": "catalog",
            "request": {
                "method": "GET",
                "path": "/catalog/search",
                "query": {"q": {"pattern": "[a-z ]+"}, "page": {"pattern": "[0-9]+"}},
            },
            "response": {
                "status": 200,
                "headers": JSON_HEADERS,
                "bodyFile": "search-results.json",
            },
        },
        {
            "id": "catalog-item-reviews",
            "mock": "catalog",
            "request": {"method": "GET", "path": {"pattern": "/catalog/items/SKU-[0-9]{5}/reviews"}},
            "response": {"status": 200, "headers": JSON_HEADERS, "body": body({"reviews": []})},
        },
        {
            "id": "catalog-category",
            "mock": "catalog",
            "request": {"method": "GET", "path": {"pattern": "/catalog/categories/[a-z-]+"}},
            "response": {"status": 200, "headers": JSON_HEADERS, "body": body({"items": []})},
        },
    ]
    return {"stubs": stubs}


def search_results():
    items = [
        {
            "sku": f"SKU-{i:05d}",
            "name": f"Item {i}",
            "category": CATEGORIES[i % len(CATEGORIES)],
            "price": {"amount": 499 + (i * 37) % 9500, "currency": "EUR"},
        }
        for i in range(311, 323)
    ]
    return json.dumps({"page": 2, "pageSize": 12, "total": 87, "items": items}, indent=2) + "\n"


def users():
    stubs = []
    for i in range(1, 301):
        user = 10000 + i
        stubs.append(
            {
                "id": f"user-{user}",
                "mock": "users",
                "request": {
                    "method": "GET",
                    "path": f"/users/{user}",
                    "headers": {"Authorization": {"pattern": "Bearer [A-Za-z0-9._-]+"}},
                },
                "response": {
                    "status": 200,
                    "headers": JSON_HEADERS,
                    "body": body(
                        {
                            "id": user,
                            "name": f"User {user}",
                            "email": f"user{user}@example.com",
                            "locale": "en-GB",
                            "tier": TIERS[i % len(TIERS)],
                            "createdAt": "2025-03-14T09:26:53Z",
                        }
                    ),
                },
            }
        )
    stubs += [
        {
            "id": "user-preferences",
            "mock": "users",
            "request": {"method": "GET", "path": {"pattern": "/users/[0-9]+/preferences"}},
            "response": {
                "status": 200,
                "headers": JSON_HEADERS,
                "body": body({"newsletter": False, "currency": "EUR", "language": "en"}),
            },
        },
        {
            "id": "user-addresses",
            "mock": "users",
            "request": {"method": "GET", "path": {"pattern": "/users/[0-9]+/addresses"}},
            "response": {"status": 200, "headers": JSON_HEADERS, "body": body({"addresses": []})},
        },
    ]
    return {"stubs": stubs}


def orders():
    stubs = []
    for channel in CHANNELS:
        for tier in TIERS:
            stubs.append(
                {
                    "id": f"create-order-{channel}-{tier}",
                    "mock": "orders",
                    "request": {
                        "method": "POST",
                        "path": "/orders",
                        "query": {"dryRun": "false"},
                        "headers": {"Content-Type": "application/json"},
                        "body": {"json": {"channel": channel, "customer": {"tier": tier}}},
                    },
                    "response": {
                        "status": 201,
                        "headers": {
                            **JSON_HEADERS,
                            "Location": f"/orders/{ORDER}",
                        },
                        "body": body(
                            {
                                "id": ORDER,
                                "status": "created",
                                "channel": channel,
                                "tier": tier,
                                "total": {"amount": 10597, "currency": "EUR"},
                            }
                        ),
                    },
                }
            )
    stubs += [
        {
            "id": "get-order",
            "mock": "orders",
            "request": {"method": "GET", "path": {"pattern": f"/orders/{UUID}"}},
            "response": {
                "status": 200,
                "headers": JSON_HEADERS,
                "body": body(MIX_ORDER),
            },
        },
        {
            "id": "update-order-status",
            "mock": "orders",
            "request": {
                "method": "PUT",
                "path": {"pattern": f"/orders/{UUID}/status"},
                "body": {"pattern": '(?s).*"status":"(paid|shipped|delivered|cancelled)".*'},
            },
            "response": {"status": 200, "headers": JSON_HEADERS, "body": body({"updated": True})},
        },
    ]
    return {"stubs": stubs}


def orders_data():
    """An order for each way to create one: the mix's order (partner, gold),
    with get-order's id, status and total, and one made up for each other
    way. Each item has its channel and tier after its status."""
    data = []
    for i, (channel, tier) in enumerate(product(CHANNELS, TIERS)):
        if (channel, tier) == ("partner", "gold"):
            order = MIX_ORDER
        else:
            order_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://orders.bench.internal/orders/{channel}-{tier}"))
            order = {"id": order_id, "status": ORDER_STATUSES[i % len(ORDER_STATUSES)],
                     "total": {"amount": 1999 + (i * 731) % 15000, "currency": "EUR"}}
        data.append({"id": order["id"], "status": order["status"], "channel": channel, "tier": tier,
                     "total": order["total"]})
    return data


def payments():
    stubs = [
        {
            "id": f"create-payment-{currency.lower()}",
            "mock": "payments",
            "request": {
                "method": "POST",
                "path": "/payments",
                "headers": {"Idempotency-Key": {"pattern": UUID}},
                "body": {"json": {"currency": currency, "method": {"type": "card"}}},
            },
            "response": {
                "status": 201,
                "headers": JSON_HEADERS,
                "body": body({"id": "PAY-000042", "status": "authorised", "currency": currency}),
            },
        }
        for currency in CURRENCIES
    ]
    for i in range(1, 201):
        stubs.append(
            {
                "id": f"payment-{i:06d}",
                "mock": "payments",
                "request": {"method": "GET", "path": f"/payments/PAY-{i:06d}"},
                "response": {
                    "status": 200,
                    "headers": JSON_HEADERS,
                    "body": body(
                        {
                            "id": f"PAY-{i:06d}",
                            "status": "captured",
                            "amount": {"value": 1000 + i * 7, "currency": "EUR"},
                        }
                    ),
                },
            }
        )
    return {"stubs": stubs}


def definition_file(content):
    """A Definition file with one Mock, Stub or Data bucket per line, so
    that a change shows as a change to that line."""
    lists = []
    for key, items in content.items():
        lines = [json.dumps(item, separators=(", ", ": ")) for item in items]
        lists.append('  "%s": [\n    %s\n  ]' % (key, ",\n    ".join(lines)))
    return "{\n%s\n}\n" % ",\n".join(lists)


def bucket_file(items):
    """A Data bucket's file: a JSON array with one item per line."""
    lines = [json.dumps(item, separators=(", ", ": ")) for item in items]
    return "[\n  %s\n]\n" % ",\n  ".join(lines)


def with_scenarios(content, mix):
    """The Scenario variant of a Definition file's content: each Stub that a
    request of `mix` names gets a clause of the Scenario named for the
    request, which requires Started and moves to Seen, and is followed by
    its twin, <id>-seen, which requires Seen and moves back to Started."""
    (key, items), = content.items()
    if key != "stubs":
        return content
    named = {request["expect"]["stub"]: request["name"] for request in mix}
    stubs = []
    for stub in items:
        name = named.get(stub["id"])
        if name is None:
            stubs.append(stub)
            continue
        stubs.append({**stub, "scenario": {"name": name, "requires": "Started", "moveTo": "Seen"}})
        stubs.append({**stub, "id": f"{stub['id']}-seen",
                      "scenario": {"name": name, "requires": "Seen", "moveTo": "Started"}})
    return {key: stubs}


def is_item_stub(stub):
    """Whether `stub` is one of the catalog's 600 item Stubs, whose IDs are
    catalog-item-00001 to catalog-item-00600."""
    return re.fullmatch(r"catalog-item-\d{5}", stub["id"]) is not None


def with_crud(name, content):
    """The CRUD variant of the Definition file `name`'s content: in the
    catalog, the bucket `items` and the CRUD Stub `catalog-items` in place
    of the 600 item Stubs; in the orders, the bucket `orders` and the CRUD
    Stub `orders` in place of get-order, after the Stubs that create an
    order, so that a POST to /orders still creates nothing."""
    if name == "catalog.json":
        stubs = [stub for stub in content["stubs"] if not is_item_stub(stub)]
        return {"data": [{"mock": "catalog", "name": "items", "key": "sku", "jsonFile": "items.json"}],
                "stubs": [{"id": "catalog-items", "mock": "catalog",
                           "crud": {"bucket": "items", "path": "/catalog/items", "headers": CRUD_HEADERS}},
                          *stubs]}
    if name == "orders.json":
        crud = {"id": "orders", "mock": "orders",
                "crud": {"bucket": "orders", "path": "/orders", "headers": CRUD_HEADERS}}
        return {"data": [{"mock": "orders", "name": "orders", "key": "id", "jsonFile": "orders.json"}],
                "stubs": [crud if stub["id"] == "get-order" else stub for stub in content["stubs"]]}
    return content


def crud_mix(mix):
    """The CRUD variant's request mix: `mix`, but the catalog search becomes
    catalog-list, a list query, and the status update becomes update-order,
    a PATCH of the order, each with the headers and body of the request it
    replaces and a Session of its own; the requests that a CRUD Stub
    answers name it, and each request names the CRUD operation it makes
    (`expect.crud`), or none."""
    def renamed(request, name, session):
        """`request` named `name`, with the Session `session` in its
        baggage."""
        old = request["expect"]["session"]
        headers = [[header, value.replace(f"smock-session={old},", f"smock-session={session},")]
                   for header, value in request["headers"]]
        return {**request, "name": name, "headers": headers}

    requests = []
    for request in mix:
        crud = None
        if request["name"] == "catalog-search":
            request = {**renamed(request, "catalog-list", "bench-catalog-list"),
                       "target": "/catalog/items?category=lighting&$sort=-stock&$limit=10"}
            crud = {"session": "bench-catalog-list", "stub": "catalog-items", "crud": {"op": "list", "key": None}}
        elif request["name"] == "catalog-item":
            crud = {"stub": "catalog-items", "crud": {"op": "read", "key": "SKU-00317"}}
        elif request["name"] == "get-order":
            crud = {"stub": "orders", "crud": {"op": "read", "key": ORDER}}
        elif request["name"] == "update-order-status":
            request = {**renamed(request, "update-order", "bench-update-order"), "method": "PATCH",
                       "target": f"/orders/{ORDER}"}
            crud = {"session": "bench-update-order", "stub": "orders", "crud": {"op": "update", "key": ORDER}}
        requests.append({**request, "expect": {**request["expect"], **(crud or {"crud": None})}})
    about = ("The request mix of the CRUD variant of the release benchmark's definitions (bench/definitions-crud/), "
             "which bench/bench.py sends when it serves that variant. bench/gen_definitions.py writes it from "
             "bench/requests.json: the same requests, but catalog-search becomes catalog-list, a list query, and "
             "update-order-status becomes update-order, a PATCH of the order, each with a Session of its own. "
             "catalog-item and get-order read an item through a CRUD Stub, and no request creates one, so a "
             "Session's copy of a bucket never grows. `expect.crud` is the CRUD operation and key that the "
             "Journal records, or null; e2e/bench_test.mbt checks it.")
    return mix_file(about, requests)


def mix_file(about, requests):
    """A request mix as bench/requests.json lays it out: a request a block,
    a header a line, and `expect` on one line."""
    def value(item):
        return json.dumps(item, ensure_ascii=False)

    def request_text(request):
        lines = []
        for key, item in request.items():
            if key == "headers":
                headers = ",\n".join(f"        [{value(name)}, {value(text)}]" for name, text in item)
                lines.append(f'      "headers": [\n{headers}\n      ]')
            elif key == "expect":
                members = ", ".join(f"{value(name)}: {value(member)}" for name, member in item.items())
                lines.append(f'      "expect": {{ {members} }}')
            else:
                lines.append(f"      {value(key)}: {value(item)}")
        return "    {\n" + ",\n".join(lines) + "\n    }"

    return ("{\n" + f'  "about": {value(about)},\n' + '  "requests": [\n'
            + ",\n".join(request_text(request) for request in requests) + "\n  ]\n}\n")


def files():
    """Every file of the three sets, and the CRUD variant's request mix, by
    its path under bench/."""
    contents = {
        "00-mocks.json": mocks(),
        "catalog.json": catalog(),
        "users.json": users(),
        "orders.json": orders(),
        "payments.json": payments(),
    }
    mix = json.loads((BENCH / "requests.json").read_text())["requests"]
    written = {}
    for directory, transform in (("definitions", lambda name, content: content),
                                 ("definitions-scenarios", lambda name, content: with_scenarios(content, mix)),
                                 ("definitions-crud", with_crud)):
        for name, content in contents.items():
            written[f"{directory}/{name}"] = definition_file(transform(name, content))
        written[f"{directory}/files/search-results.json"] = search_results()
    written["definitions-crud/files/items.json"] = bucket_file(catalog_items())
    written["definitions-crud/files/orders.json"] = bucket_file(orders_data())
    written[CRUD_MIX] = crud_mix(mix)
    return written


def main(argv):
    if argv not in ([], ["--check"]):
        print(__doc__.split("usage: ")[1], file=sys.stderr)
        return 2
    wanted = files()
    present = {
        str(path.relative_to(BENCH)): path.read_text()
        for name in SETS
        for path in sorted((BENCH / name).rglob("*"))
        if path.is_file()
    }
    if (BENCH / CRUD_MIX).is_file():
        present[CRUD_MIX] = (BENCH / CRUD_MIX).read_text()
    sets = ", ".join(f"bench/{name}/" for name in SETS) + f" and bench/{CRUD_MIX}"
    if argv == ["--check"]:
        stale = sorted(name for name in set(wanted) | set(present) if wanted.get(name) != present.get(name))
        for name in stale:
            print(f"gen_definitions: bench/{name} is not what the script writes", file=sys.stderr)
        if stale:
            print("gen_definitions: run python3 bench/gen_definitions.py and commit the result", file=sys.stderr)
            return 1
        print(f"gen_definitions: {sets} are up to date ({len(wanted)} files)")
        return 0
    for name in set(present) - set(wanted):
        (BENCH / name).unlink()
    for name, text in wanted.items():
        path = BENCH / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    print(f"gen_definitions: wrote {len(wanted)} files to {sets}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
