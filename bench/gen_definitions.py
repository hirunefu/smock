#!/usr/bin/env python3
"""Writes the release benchmark's definition set, bench/definitions/, and
its Scenario variant, bench/definitions-scenarios/.

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

The files are checked in. Run this script again after changing it, and
commit what it writes.

usage: python3 bench/gen_definitions.py [--check]
  --check  writes nothing; exits 1 if the files of either set differ from
           what it would write
"""

import json
import sys
from pathlib import Path

BENCH = Path(__file__).resolve().parent

# Each set's directory, by its name under bench/.
SETS = ("definitions", "definitions-scenarios")

JSON_HEADERS = {"Content-Type": "application/json", "Cache-Control": "no-store"}
UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
CATEGORIES = ["lighting", "furniture", "kitchen", "garden", "office", "storage"]
CHANNELS = ["web", "app", "partner", "pos", "call-center", "kiosk"]
TIERS = ["bronze", "silver", "gold", "platinum", "staff", "trial", "b2b", "vip"]
CURRENCIES = ["USD", "GBP", "JPY", "EUR", "CHF", "SEK"]


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


def catalog():
    stubs = []
    for i in range(1, 601):
        sku = f"SKU-{i:05d}"
        stubs.append(
            {
                "id": f"catalog-item-{i:05d}",
                "mock": "catalog",
                "request": {"method": "GET", "path": f"/catalog/items/{sku}"},
                "response": {
                    "status": 200,
                    "headers": JSON_HEADERS,
                    "body": body(
                        {
                            "sku": sku,
                            "name": f"Item {i}",
                            "category": CATEGORIES[i % len(CATEGORIES)],
                            "price": {"amount": 499 + (i * 37) % 9500, "currency": "EUR"},
                            "stock": (i * 13) % 50,
                        }
                    ),
                },
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
                            "Location": "/orders/7f9c2ba4-e88f-4c1a-9c5b-2d3a1e8f6b10",
                        },
                        "body": body(
                            {
                                "id": "7f9c2ba4-e88f-4c1a-9c5b-2d3a1e8f6b10",
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
                "body": body(
                    {
                        "id": "7f9c2ba4-e88f-4c1a-9c5b-2d3a1e8f6b10",
                        "status": "paid",
                        "total": {"amount": 10597, "currency": "EUR"},
                    }
                ),
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
    """A Definition file with one Mock or Stub per line, so that a change
    shows as a change to that line."""
    (key, items), = content.items()
    lines = [json.dumps(item, separators=(", ", ": ")) for item in items]
    return '{\n  "%s": [\n    %s\n  ]\n}\n' % (key, ",\n    ".join(lines))


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


def files():
    """Every file of both sets, by its path under bench/."""
    contents = {
        "00-mocks.json": mocks(),
        "catalog.json": catalog(),
        "users.json": users(),
        "orders.json": orders(),
        "payments.json": payments(),
    }
    mix = json.loads((BENCH / "requests.json").read_text())["requests"]
    written = {}
    for directory, transform in (("definitions", lambda content: content),
                                 ("definitions-scenarios", lambda content: with_scenarios(content, mix))):
        for name, content in contents.items():
            written[f"{directory}/{name}"] = definition_file(transform(content))
        written[f"{directory}/files/search-results.json"] = search_results()
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
    sets = " and ".join(f"bench/{name}/" for name in SETS)
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
