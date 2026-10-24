# Benchmark

The release benchmark measures smock's real request path: realistic
requests, matched against a definition set with many Stubs, with the
Journal on. It sends them at a fixed arrival rate and reports p99 and p99.9
latency for each case, and checks the provisional performance targets.

| File | What it is |
|---|---|
| `bench/bench.py` | Runs the benchmark. |
| `bench/definitions/` | The definition set smock serves: four Mocks, one of them the Default Mock, and about 1,200 Stubs with exact, pattern and `json` conditions (`e2e/bench_test.mbt` pins the exact count). `bench/gen_definitions.py` writes it. |
| `bench/definitions-scenarios/` | Its Scenario variant, which `--definitions` selects ([Scenarios in the benchmark](#scenarios-in-the-benchmark)). `bench/gen_definitions.py` writes it too. |
| `bench/definitions-crud/` | Its CRUD variant, which `--definitions` selects too ([CRUD Stubs in the benchmark](#crud-stubs-in-the-benchmark)). `bench/gen_definitions.py` writes it too. |
| `bench/requests.json` | The request mix: nine kinds of request, with weights, realistic headers, a Session in `baggage`, and bodies. |
| `bench/requests-crud.json` | The CRUD variant's own request mix, which a run sends it. `bench/gen_definitions.py` writes it from `bench/requests.json`. |
| `bench/plan.json` | The cases, the CPU limits, and the rates and durations. |
| `bench/plan-autopilot.json` | Another plan: smock under the CPU and memory limits of the smallest GKE Autopilot Pods and of the Helm chart's default, at ladders of rates. The targets hold under its profiles. |
| `bench/plan-same-node.json` | The plan of a GKE run that compares smock binaries on one node: HTTP keep-alive at the lowest rates of `bench/plan-autopilot.json`'s ladders, and at half the lowest under 50m and 250m. |
| `bench/targets.json` | The provisional targets, a set for each CPU architecture, the one place to change them, and the rule that calls a change between two runs a regression. |
| `bench/compare.py` | Compares two runs: p99 and p99.9 at each step both ran, and the targets the newer one missed. |
| `bench/gke/` | The GKE Autopilot run's helper (`gke.py`: its plan, cost estimate, manifests and summary, and the comparison of binaries on one node), its load generator (`generator.py`), and what its images add. |
| `scripts/gke-bench.sh` | Runs the benchmark on GKE Autopilot, end to end. |

The commands below run from the repository root.

`e2e/bench_test.mbt` checks on every test run that each request of the mix
reaches the Mock and the Stub it names, on the plain and on the TLS port,
and lands in the Journal under its Session, that in the Scenario variant
each request moves its Scenario, and that in the CRUD variant each request
of its mix makes the CRUD operation it names. CI checks that
`bench/definitions/`, `bench/definitions-scenarios/`,
`bench/definitions-crud/` and `bench/requests-crud.json` are what
`bench/gen_definitions.py` writes.

The benchmark runs on a developer's machine. The full run of
`bench/plan-autopilot.json`, a run on GKE Autopilot, and their comparison
with the previous ones are part of the checklist before an integration
branch is merged into `main`,
[docs/merging-into-main.md](../docs/merging-into-main.md). Nothing runs it on
a schedule.

## Run it on your machine

It needs Linux on amd64 or arm64 with at least three CPUs, python3 3.10 or
later, `openssl`, `taskset` and `lscpu` (util-linux), oha 1.16.0 on `PATH`
(`scripts/install-oha.sh` installs it into `~/.local/bin`, checked against
its digest), and a systemd user manager that can set CPU quotas and memory
limits: `cpu` and `memory` must be in
`/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers`.
Recent systemd delegates them by default; otherwise add a drop-in for
`user@.service` with `Delegate=cpu cpuset io memory pids`.

```sh
scripts/build-release.sh                 # dist/smock, which the benchmark runs
python3 bench/bench.py run               # the whole plan, about 20 minutes
python3 bench/bench.py run --cases http-keep-alive --cpu-limits 1   # one case under one limit
python3 bench/bench.py run --plan bench/plan-autopilot.json            # the profiles the targets hold under, about 20 minutes
python3 bench/bench.py run --plan bench/plan-autopilot.json --profiles autopilot-burst-min   # one profile
python3 bench/bench.py run --plan bench/plan-autopilot.json --definitions bench/definitions-scenarios   # with Scenario Stubs
python3 bench/bench.py run --plan bench/plan-autopilot.json --definitions bench/definitions-crud   # with CRUD Stubs, sent their own mix
python3 bench/bench.py run --rate 500 --ramp 1 --duration 3 --tail 1 --settle 1 --cooldown 0   # a check of the setup, about 2 minutes
python3 bench/bench.py check-targets bench/results/<date>-<time>   # an earlier run against the targets as they are now
python3 -m unittest discover -s bench -v # the harness's own tests, about 5 minutes
```

`python3 bench/bench.py run --help` lists the options. A run first prints
how long it will take, then writes to `bench/results/<date>-<time>/` unless
`--out` says otherwise. Options that change the plan's rates or durations
are for checking the setup: the run records them, and the summary says it
was not a full run. For numbers worth comparing, close other programs and
plug a laptop in; the conditions record the CPU frequency governor.

## GKE Autopilot profiles

`bench/plan-autopilot.json` runs smock as it would run in the smallest
general-purpose GKE Autopilot Pods and in a Pod with the Helm chart's
default resources, simulated on your machine with the same cgroup limits:

| Profile | CPU limit | Memory limit | What it is |
|---|---|---|---|
| `autopilot-burst-min` | 50m | 52 MiB | The smallest Pod where Pods may burst. |
| `autopilot-min` | 250m | 512 MiB | The smallest Pod where they may not. |
| `chart-default` | 1 | 1 GiB | The Helm chart's default requests and limits, which Autopilot takes as they are. |

A CPU limit equal to the request is a CFS quota over a 100 ms period, as
here: under 50m, smock may run 5 ms in every 100 ms. smock runs with its
defaults, so if they do not fit a memory limit, the run shows OOM kills
rather than hiding them; the Journal's byte bound follows the memory limit
([The Journal](../README.md#the-journal)): 13 MiB under 52Mi, 64 MiB under the others.
Each profile measures idle RSS, then plain HTTP and TLS with keep-alive
connections, each at a ladder of fixed rates from 2,500 to 80,000 requests
a second per CPU (125 to 4,000 under 50m), 20 seconds a step. The top of
each ladder is about where smock uses up its CPU over TLS. Every ladder
has the rates of the amd64 [targets](#targets) (125, 1,250 and 10,000)
and of the arm64 ones under 50m and 250m (250 and 5,000). Plain HTTP's
ladder also has 30,000 a second per CPU, the rate of arm64's target under
1 CPU, and 50,000 a second per CPU, by which smock had used up its CPU
under each profile in the arm64 GKE probe those targets come from. A full
run takes about 20 minutes; it prints its estimate before it starts.

Before a full run:

- Plug the laptop in, and close heavy programs (browsers, builds, other
  benchmarks): smock and the load generator share this machine.
- Set the CPU frequency governor to `performance`, in a terminal of your
  own, since it needs root, and set it back afterwards (to the one
  `scaling_governor` had, such as `schedutil`):

  ```sh
  echo performance | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
  scripts/build-release.sh
  python3 bench/bench.py run --plan bench/plan-autopilot.json
  echo schedutil | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
  ```

The numbers are this machine's: the quota and the memory limit are the
Pod's, but the CPU is not the one GKE schedules the Pod on, and the load
comes over loopback, not a Pod network. Absolute numbers differ from GKE's;
compare profiles with each other, and runs on the same machine. The summary
says so too.

## Scenarios in the benchmark

`--definitions` serves another definitions directory than
`bench/definitions/`. `bench/definitions-scenarios/` is its Scenario
variant: the same Mocks and Stubs, but each Stub that a request of the mix
names has a [Scenario](../docs/definition-files.md#scenarios) clause, which
requires `Started` and moves to `Seen`, and right after it a twin,
`<id>-seen`, with the same request and response, which requires `Seen` and
moves back to `Started`. Each request carries its own Session, so its
Scenario is its own, and the two Stubs take turns. So in every Mock,
every request of the mix matches a Scenario Stub and moves its Scenario:
smock looks up the Session's states, checks the state the Stub requires,
moves it, and records the move in the Journal. Every other request also
tries the Stub whose state does not hold before the twin that answers,
as the Stubs of a Scenario with the same request do. The plain set has no
Scenario Stub, so each of its requests pays only the test of whether its
Mock has one.

To see what Scenarios cost, run each set on the same machine with the same
plan and compare the runs with `bench/compare.py`, which names the
definition set as a condition that differs. Each run checks the targets.
On GKE, a variant with the `scenarios` option serves it
([Comparing smock binaries on one node](#comparing-smock-binaries-on-one-node)).

## CRUD Stubs in the benchmark

`bench/definitions-crud/` is the CRUD variant of the definitions: the
same Mocks and Stubs, but two resources are
[Data buckets](../docs/definition-files.md#data-buckets), each served by
a [CRUD Stub](../docs/definition-files.md#crud-stubs) in place of the
Stubs that answered its items one by one:

- `items`, keyed by `sku`, holds the catalog's 600 items, which the 600
  item Stubs answered, in their order. The CRUD Stub `catalog-items`
  serves it at `/catalog/items`, first in the catalog's file, where those
  Stubs were.
- `orders`, keyed by `id`, holds an order for each of the 48 ways to
  create one, the mix's order among them, paid as `get-order` answered
  it. The CRUD Stub `orders` serves it at `/orders`, in place of `get-order`,
  after the 48 Stubs that create an order. A `POST /orders` still matches
  one of those first, so the CRUD Stub never creates.

The plain mix has no request that lists or updates an item through a CRUD
Stub, so a run that serves this variant sends it a mix of its own,
`bench/requests-crud.json`. `bench/gen_definitions.py` writes it from
`bench/requests.json`: the same requests, with the same weights, but two.
`catalog-search` becomes `catalog-list`, a
[list query](../docs/definition-files.md#list-queries),
`GET /catalog/items?category=lighting&$sort=-stock&$limit=10`, which
filters the 600 items to 100, sorts them and keeps 10. `update-order-status`
becomes `update-order`, a `PATCH` of the order with the same body. Each of
the two has a Session of its own. So, by weight, 35% of the requests read
an item (`catalog-item` and `get-order`), 10% list items and 5% update
one, through a CRUD Stub; the rest are answered as in the plain set.

No request creates an item, so no copy of a bucket grows during a run.
Reads never copy a bucket, so only the update's Session holds a copy,
made by its first `PATCH`: each later one changes the order in place.
`conditions.json` names the mix a run sent, and `summary.md` names it
beside the definition set when it is not `bench/requests.json`. The
plain set has no Data bucket and no CRUD Stub, so each of its requests
pays only the test of whether its Mock has one.

To see what CRUD Stubs cost, run each set on the same machine with the
same plan, and compare the runs with `bench/compare.py`, which names the
definition set and the request mix as conditions that differ. Each run
checks the targets. On GKE, a variant with the `crud` option serves it,
and the load generator sends that variant its mix
([Comparing smock binaries on one node](#comparing-smock-binaries-on-one-node)).

## Targets

smock's performance targets are provisional, and there is a set for each
CPU architecture: x86 (amd64) and Arm (arm64). `bench/targets.json` holds
both, says where each comes from, and is the one place to change them. A run
checks the set of the architecture it ran on: a run on a machine, the
machine's (an M1 is arm64); a GKE run, its nodes' (`--arch`). A run on an
architecture with no set reports every target as not measured, and says
why; `check-targets` (below) refuses to pass it. Each target holds under a
profile of `bench/plan-autopilot.json`, with plain HTTP over keep-alive
connections at one rate:

| Architecture | Profile | CPU and memory limits | Rate | p99 at most | p99.9 at most |
|---|---|---|---|---|---|
| amd64 | `chart-default` | 1, 1 GiB | 10,000 requests/s | 10 ms | 20 ms |
| amd64 | `autopilot-min` | 250m, 512 MiB | 1,250 requests/s | 100 ms | 200 ms |
| amd64 | `autopilot-burst-min` | 50m, 52 MiB | 125 requests/s | 100 ms | 300 ms |
| arm64 | `chart-default` | 1, 1 GiB | 30,000 requests/s | 3 ms | 10 ms |
| arm64 | `autopilot-min` | 250m, 512 MiB | 5,000 requests/s | 3 ms | 5 ms |
| arm64 | `autopilot-burst-min` | 50m, 52 MiB | 250 requests/s | 3 ms | 50 ms |

On both, under every profile, smock's idle RSS is at most 20 MiB, and its
peak memory at the target's rate (`memory.peak`) at most 32 MiB. Under
`autopilot-burst-min`, the kernel may not OOM-kill it at that rate.

- **amd64** comes from three runs on GKE Autopilot, two on 2026-10-14 and
  one on 2026-10-15 with a smock that spends less CPU on each request, in
  general-purpose x86 Pods on ek-standard-8 nodes in us-central1-a, where a
  vCPU is a hyperthread. Under 1 CPU, smock kept up with about 19,000 to
  21,000 requests/s over plain HTTP and 14,000 over HTTPS. At 10,000, p99
  was 3.8 ms and p99.9 5.8 ms in the third run, with smock at 75% of its
  CPU limit (p99 12.9 and 4.2 ms, p99.9 22 and 11.7 ms in the first two);
  at 20,000, requests queued for seconds. Under 250m and 50m, the CFS quota
  showed in the slowest requests even at light load, and varied from run to
  run (p99 69 ms at 625 requests/s under 250m in one run; 3.3 to 45 ms at
  125 under 50m), hence their loose targets. Only the third run measured
  memory: idle RSS 16.2 to 16.3 MiB, and peak memory 27 MiB at 10,000
  requests/s under 1 CPU.
- **arm64** comes from a one-off probe on GKE Autopilot, in arm64
  general-purpose Pods on e4a nodes in us-central1, at the plain HTTP rates
  of `bench/plan-autopilot.json` (all but 30,000 a second per CPU, added
  since): under each profile, smock kept up with a rate at or above its
  target's, and under 50m the slowest requests took tens of milliseconds
  even at light load, hence its p99.9 of 50 ms. Per vCPU, Arm served about
  2.5 times what x86 did on GKE under 1 CPU (about 50,000 against 19,000
  to 21,000 requests/s), and 2 to 3.5 times under 250m and 50m. Runs on
  an M1 MacBook Air over loopback do better still: p99 and p99.9 stay about
  2 ms around each target's rate, and each profile keeps up with more than
  twice it.

The [chart's sizing table](../charts/smock/README.md#sizing) has the numbers
of each.

Latency counts from each request's scheduled send time, as the harness
measures it, so it includes the load generator's floor: oha's timer has a
resolution of 1 ms, which adds about a millisecond at p50 and about 2 ms at
p99, whatever smock does. The targets absorb it, so a p99 of 3 ms leaves
smock about a millisecond. The latency from release, reported beside it,
shows what smock itself adds; a target below the floor would need a load
generator that paces requests more finely than 1 ms.

A full run of `bench/plan-autopilot.json` measures every target of its
architecture; on GKE, idle RSS and peak memory come from smock's own
[process and cgroup metrics](../README.md#run), so a smock without them leaves
those two unmeasured. A run of `bench/plan.json`, as in CI, runs none of
these profiles, and reports each target as not measured.

To check an earlier run against the targets as they are now, such as after
they changed, without running anything:

```sh
python3 bench/bench.py check-targets bench/results/<run>   # a results directory, or its summary.json
```

It reads the run's `summary.json`, and the architecture it ran on from
`conditions.json` beside it, checks the set of that architecture (of
`--targets FILE` if given), and prints the *Targets* section of
`summary.md` to stdout. It changes nothing in the run's directory. It exits
with 1 when a target is missed, and with 2 when it cannot check: a summary
of another `format`, no `conditions.json` beside it, or a run on an
architecture the targets file has no set for.

## What a run does

- **Profiles.** A resource profile is a CPU limit and, optionally, a
  memory limit. In `bench/plan.json` each CPU limit is a profile, named by
  it, with no memory limit; `bench/plan-autopilot.json` names its profiles
  and gives each a memory limit. `--profiles` and `--cpu-limits` select some.
- **Idle RSS.** smock starts with the benchmark's definitions under a
  profile: in `bench/plan.json` the 1-CPU one, in
  `bench/plan-autopilot.json` each. Once it is ready and has idled for 5
  seconds, its RSS is the idle RSS.
- **Cases.** Each case of the plan runs under each profile it has a rate
  for, or a ladder of rates, one step for each from the lowest. In
  `bench/plan.json`, the profiles are 250m, 500m, 1 and 2 cores, and the
  cases are plain HTTP and TLS with keep-alive connections, plain HTTP and
  TLS with a new connection per request, plain HTTP with 1000 idle
  connections held open during the load, and a 10-minute run under 1 CPU
  that records RSS every second.
- **CPU limits and pinning.** smock runs in its own systemd scope with a
  CPU quota over the 100 ms period Kubernetes also uses, pinned to the
  fastest CPUs, as many as the largest CPU limit of the plan needs (two for
  `bench/plan.json`). The load generator and the harness run on the other
  CPUs. The run reads the quota back from smock's cgroup and stops if it
  did not take effect.
- **Other tasks on smock's CPUs.** Pinning keeps the load generator off
  smock's CPUs, but not other programs, nor the kernel's threads. When they
  run there, smock waits for its CPU, and the slowest requests show the
  machine rather than smock. So at the start and at the end of each step's
  measured window, the run reads how long tasks have run on smock's CPUs
  (the kernel's per-CPU scheduler statistics, `/proc/schedstat`), how long
  those CPUs spent in interrupts and softirqs (`/proc/stat`), and smock's
  CPU time (its cgroup's `cpu.stat`). The time tasks ran, less smock's and
  less the interrupts, is what other tasks used. The kernel counts the
  interrupts that come while smock runs, such as the loopback's delivery
  of its responses, in the CPU's run time but not in smock's, hence the
  second reading. Right after these readings, the run scrapes smock's
  `/metrics`, so that how long smock waited for a CPU, *CPU wait*, covers
  the same window. A step is **disturbed** when other tasks used at least
  1% of smock's CPUs' time in its window (`DISTURBED_SHARE` in
  `bench/bench.py`). In
  [#57](https://github.com/hirunefu/smock/issues/57), desktop programs at
  0.5% of smock's CPU left the slowest requests as they were, and a
  program pinned to smock's CPU, busy 3 ms in every 50 ms (6%), made p99.9
  1.0 to 1.7 ms worse at low rates. Kernel threads that work for smock,
  such as ksoftirqd, count as other tasks. Close other programs and
  rerun a disturbed step. A GKE run does not record it: smock is not
  pinned there, and the node's statistics are not the Pod's to read.
- **Memory limits and OOM kills.** Under a profile with a memory limit, the
  scope also gets `MemoryMax` and `MemorySwapMax=0`, so smock cannot swap,
  as in a Kubernetes container. The run reads `memory.max` and
  `memory.swap.max` back and stops if they did not take effect. It records
  smock's peak memory (`memory.peak`, all that `memory.max` counts: the
  Journal, socket buffers and page cache included) and how many times the
  kernel OOM-killed it, from `memory.events` of a slice that holds only
  smock's scope, which outlives it. An OOM kill does not stop the run: a
  case whose smock was killed before it was ready sends no load, and each
  request of its window counts as an error.
- **Fixed arrival rate.** oha sends each kind of request at its weight's
  share of the case's rate and connections. Its schedule releases request
  `i` at `i / rate` whether or not a connection is free to send it, and a
  request's latency counts from that time, when it was due. A request that
  waits behind a busy or stalled smock counts its wait, and so does one
  that oha releases late because it fell behind, as it can when a stalled
  smock answers a burst at once.
- **Latency from release and generator lag.** Beside the latency, each
  case reports the latency from the time oha actually released each
  request, and the generator lag, how late it released them: the latency is
  their sum. oha's timer has a resolution of 1 ms, so it releases requests
  about a millisecond late, and the scheduler adds a few milliseconds now
  and then. When the lag's p99.9 is over 5 ms or its maximum over 10 ms, the
  load generator fell behind its schedule, and the case says so
  (`load_generator_late`).
- **What oha's timer means for the targets.** Since every latency includes
  the generator lag, about a millisecond at p50 and 2 ms at p99, no
  latency can be measured below that floor, whatever smock does. The
  [targets](#targets) absorb it.
- **Window.** Requests scheduled in the first 2 seconds, while connections
  open, are not counted. The next 20 seconds are measured, and 3 more let
  the last of them finish.
- **Errors.** A request scheduled in the window that did not get the status
  `bench/requests.json` expects is an error, whether it got another status
  or no response.
- **Targets.** Each target of `bench/targets.json` for the machine's
  architecture is met, missed or not measured, with the reason. It holds
  under one profile, by its name and its CPU and memory limits: a run that
  did not run that profile with those limits does not measure it. The
  latency, peak memory and OOM-kill targets hold at one load, one case at
  one rate under the profile, and a run that did not run that step does
  not measure them. An OOM kill misses every
  target of its step. A latency target, counted from the scheduled send
  times, is not measured when the load generator fell behind, and missed by
  any error. Peak memory over its bound misses its target; within it, it is
  not measured if requests failed, since smock did not carry the load. The
  idle RSS target holds for the idle RSS under the profile.

## What a run writes

- `conditions.json`: what ran where. The smock version, commit, toolchain
  and binary digest; the definitions directory, its digest and the Mocks;
  the request mix; the plan file, with its SHA-256 and that of the plan without its
  `about` (`sha256_without_about`); the architecture, CPU model, kernel
  and CPU governors; the profiles with their CPU and memory limits, the CPU limits
  and the CPUs of smock and of the load generator; each case's profile,
  rate, durations and connection counts; oha and its version; the targets
  file; any options that changed the plan.
- `summary.json`: for each case at each rate (its `id` is
  `<case>@<profile>`, and `@<rate>` when it climbs a ladder), the latency
  from the scheduled send times and the latency from release (each p50,
  p90, p99, p99.9, max), the generator lag (p50, p99, p99.9, max) and
  whether the load generator fell behind, the achieved rate, the errors by
  kind, each second of the load from its start, ramp and tail included
  (`per_second`: how many of the requests oha released in that second got
  a response, `requests`, and their p99 from the scheduled send times,
  `p99_ms`, so that a burst at the start, a stall now and then and a step
  slow all through look apart; oha releases a request about a millisecond
  after it was due, so in the second it was due in, unless oha fell
  behind, as in a stall that holds it up too: then the request and its
  latency count in the second oha released it in, which may be a second
  or more later (in the window, `load_generator_late` then flags the
  step); oha keeps nothing of a request that got no response, so one
  leaves the second it was due in short, and overstates the p99 of that
  second and of each later one by up to the time between two requests of
  its kind, 1 / their rate),
  smock's CPU use and throttling
  (`smock_cpu`: from its cgroup's `cpu.stat`, with the requests smock
  answered meanwhile, from `smock_requests_total`, what the CPU time comes
  to a request, `us_per_request`, and against the CPU limit,
  `utilization`, the CPU time its process counted, `process_s`, from its
  `/metrics`, as a cross-check, how long smock's main thread waited for a
  CPU, `scheduling_delay_s`, how many times the kernel took the CPU from
  it, `involuntary_context_switches`, both including, under a CPU limit,
  the time the CFS quota held it back, `throttled_s`, and the machine's
  steal time, `node_steal_s`, from its `/metrics`, and the same for the
  step's first second, `first_second`, when connections open and TLS
  handshakes come at once, all from its `/metrics` and its cgroup's
  metrics there, scraped a second into the load: under a small CPU limit
  the scrape waits behind the load, so that second ends when smock
  answers it, which can be a second or more later; and the same for the
  measured window, `window`, from its `/metrics` scraped at the window's
  start and end, where `other_tasks` is read: its `scheduling_delay_s` is
  how long smock waited for a CPU in the window alone, while the one above
  covers the whole load, ramp and tail included; null where smock did not
  answer one of those scrapes, and absent on GKE), what other tasks
  used of smock's CPUs in the measured window (`other_tasks`: the CPUs,
  the window's length, `window_s`, the CPU time other tasks used, `cpu_s`,
  its share of the CPUs' time, `share`, whether that disturbed the step,
  `disturbed`, and the time in interrupts left out of it, `interrupts_s`;
  null on GKE, for a step whose smock was not ready, and where the
  readings could not be taken), the quota,
  memory limit and CPUs read while it ran,
  smock's peak memory and OOM kills (`memory`), whether smock got ready,
  smock's RSS (first, last, max), the TCP connections the machine accepted
  during the load, and the idle connections still open at its end. Then
  the idle RSS under each profile, with peak memory and OOM kills, and
  each target with its architecture and profile, its verdict, what was
  measured and why when that is not plain. `format` numbers the layout.
- `summary.md`: the same for people, a section for each profile. Its
  *Targets* section says which architecture's targets it checked. Each
  step shows how long smock waited for a CPU in its measured window
  (*CPU wait*; for the whole load in a GKE run) and what other tasks used
  of smock's CPUs in the same window (*Other tasks*, in percent of their
  time), and says *disturbed* after the case's name when they disturbed
  it.
- `raw/<profile>/<case>/` (`<case>@<rate>` for a ladder's steps):
  `latency.json`, a histogram of the latencies from the scheduled send
  times in microseconds to three significant digits; `rss.json`, smock's
  RSS over time; smock's log; and oha's own report for each kind of
  request. `raw/<profile>/idle-rss.json` has the RSS samples of the idle
  measurement.

## Comparing runs

```sh
python3 bench/compare.py <older> <newer>   # each a results directory, or its summary.json
```

`bench/compare.py` reads two runs' `summary.json` and prints a report in
Markdown, ready to post. For each step both runs ran, a case under a
profile at a rate, it shows p99 and p99.9 in each and how they changed.
A step is a **regression** when either got worse by more than 20% and by
more than 1 ms: a change within a millisecond is within what oha's 1 ms
timer resolves, whatever its percentage. The rule is the `regression`
entry of `bench/targets.json`, next to the targets.

Only numbers that hold still from run to run count; where they do not, two
runs of the same smock can differ by more than 20%:

- **Only steps at or below the target rate count.** The rate of a
  profile's entry in `bench/targets.json` for the newer run's architecture
  (for `autopilot-min`, 1,250 requests/s on amd64 and 5,000 on arm64; the
  highest, if a profile has several) holds for every case of that profile.
  Above it smock may be past its capacity, and the latencies of a queue
  swing from run to run: those steps are listed under *For reference*, with
  the same columns, and never fail the comparison. A profile with no
  entry counts at every rate, and so does every profile when the file has
  no targets for the newer run's architecture or its `conditions.json` is
  missing.
- **p99.9 counts only on at least 10,000 requests**, measured at the step
  in both runs (`p99_9_min_requests` in the rule). With fewer, it rests on
  the few slowest requests: the 3rd slowest of 2,500, the 5th of 5,000.
  Its change is still shown, marked *for reference*, and p99 still counts.

The line above the table says which steps count.

- A step is not compared where the older run did not measure smock: when
  requests failed in it (past smock's capacity, the latencies measure the
  queue), or the load generator fell behind, or smock was not ready. Nor
  when the newer run's load generator fell behind, or the profile ran under
  other limits.
- Requests the newer run failed at a step the older one measured are a
  regression, and so is a smock that was not ready. Above the target rate
  they are listed for reference.
- Steps only one run has are listed, not compared.
- A step other tasks disturbed in either run (see
  [What a run does](#what-a-run-does)) is named in its verdict, with what
  they used of smock's CPUs and, where both runs recorded it, how long
  smock waited for a CPU in the step's window in each, such as
  `regression (disturbed: other tasks used 7.33% of smock's CPUs in the
  newer run; CPU wait 0.046 s → 0.313 s)`. The wait includes the time the
  CPU limit held smock back. A regression there still
  fails the comparison, and the result line counts those at disturbed
  steps: rerun the profile on a quieter machine before looking for the
  cause in smock. The line above the table says when a step is disturbed.
  A run from before runs recorded other tasks, or a GKE run, has nothing
  to tell: the line says it was not recorded there, and the steps are
  compared as before.
- Where both runs measured smock's CPU time a request at a step, a *CPU
  per request* section shows it and its share of the CPU limit in each,
  and how it changed. It is there for information: it fails nothing, and
  another machine or CPU model gives other numbers.
- A step the older run measured and the newer one did not, because the
  newer run left it out or stopped before it, or its load generator fell
  behind, fails the comparison: nothing says how smock did there. Above
  the target rate it is listed and does not fail it.
- It lists each target the newer run missed, with what it measured and
  what the older run did for the same target (the same id at the same
  load, for the same architecture), and the targets it did not measure.
- From each run's `conditions.json`, it names the runs (smock's version and
  commit, the machine, the plan) and lists the conditions besides smock
  that differ, such as the architecture, the CPU model, the plan or oha.
  The plan differs when what it runs differs: the comparison takes the
  hash of the plan without its `about`, so that a change to the
  description alone is no difference. A run from before runs recorded
  that hash has only the file's, which the comparison then takes, so the
  first comparison with such a run shows the plan as changed if anything
  in its file changed, its `about` included (as that of
  `bench/plan-autopilot.json` did after its first runs).
  Compare runs of the same kind: a GKE run with a GKE run, a run on a
  machine with a run on the same machine. It says so when one run is on
  GKE and the other is not.
- Of two GKE runs, it says under each profile whether smock's node had
  another CPU in the newer run: its model (with its family, model and
  stepping, which tell apart the generations a virtual machine's model
  name may not), microcode, TLS flags or the kernel's mitigations of its
  vulnerabilities, each where it changed; where smock's node had the same
  CPU; and where a run did not record it, as runs before the nodes' CPUs
  were recorded did not. A latency that changed with the node may be the
  node's rather than smock's. It fails nothing.
- Runs on different CPU architectures, such as an arm64 GKE run and an
  amd64 one, are not compared step by step: their latencies differ by more
  than smock, so no step is a regression, nor a step the newer run left
  out. The report says so, and still lists the targets the newer run
  missed, which fail it.

It exits with 1 when it finds a regression, a missed target or a step that
counts and the newer run did not measure, and with 2 when it cannot
compare, such as for a summary of another `format`.

## On GKE Autopilot

`scripts/gke-bench.sh` runs `bench/plan-autopilot.json` on real GKE
Autopilot: smock in a Pod with each profile's limits as its requests, the
load from another node over the Pod network. It is part of the
[checklist before merging into main](../docs/merging-into-main.md), and costs
money: about $0.22 to $0.26 a run on x86 nodes (us-central1 or
asia-northeast1), and about $0.18 on Arm nodes in us-central1, at the
on-demand prices of 2026-10-16, which it estimates before it makes
anything. Both architectures' Pods run on Autopilot's container-optimized
compute platform, Arm ones through the `autopilot-arm` compute class, and
the pricing page bills that platform's Pods at one rate for both.

```sh
export GKE_BENCH_PROJECT=<project ID> GKE_BENCH_REGION=us-central1
scripts/gke-bench.sh --dry-run    # the checks, the estimate, and every command it would run; reads only
scripts/gke-bench.sh              # the checks and the estimate; makes nothing
scripts/gke-bench.sh --yes        # runs it, about 50 minutes
```

It needs gcloud (logged in), docker, kubectl, python3, setsid, curl to
download oha (or `--oha` with a binary), and to build the release binary
the MoonBit toolchain (or `--smock` with a binary). `GCLOUD`, `KUBECTL`,
`DOCKER` and `PYTHON` name other commands
than those on `PATH`. `scripts/gke-bench.sh --help` lists its options: the
nodes' architecture, some profiles or cases only, another plan, the results
directory, the time limit.

A run is on nodes of one architecture, `--arch amd64` or `--arch arm64`,
by default the machine's that runs the script. Autopilot runs x86 (amd64)
Pods in every region, and Arm (arm64) Pods only in us-central1, us-east1,
us-west1, europe-west1, europe-west2, europe-west4 and asia-southeast1
(GKE's documentation, 2026-10-14): an arm64 run needs one of those, and
the script warns when its region is not one. x86 capacity is plentiful,
and an Arm run once failed for want of Arm nodes in its zone. To run on
x86 nodes from an arm64 machine, which cannot build smock for amd64, as
the pre-merge run does in us-central1-a, take the release binary that CI
built for linux/amd64 from the commit checked out, from CI's run on the
push of that commit (CI keeps it for 7 days):

```sh
gh run list -R hirunefu/smock --workflow CI --branch <branch> --event push --limit 1 --json databaseId,headSha
dir=$(mktemp -d)
gh run download <run-id> -R hirunefu/smock -n smock-linux-amd64 --dir "$dir"   # writes $dir/smock
export GKE_BENCH_PROJECT=<project ID> GKE_BENCH_REGION=us-central1 GKE_BENCH_ZONE=us-central1-a
scripts/gke-bench.sh --dry-run --arch amd64 --smock "$dir/smock"
scripts/gke-bench.sh --yes --arch amd64 --smock "$dir/smock"
```

The run's `headSha` must be the commit checked out. A run on a pull request
builds its merge commit instead, so take the run on the push; the script
refuses a binary built from another commit. The artifact is there only if
that run's linux/amd64 build and tests passed.

- **Checks, before anything is made.** It checks that smock and oha, when
  given, are ELF executables of the run's architecture (from their
  headers; they are not run), and that smock is built from the commit
  checked out: as it says (`smock --version`) when the machine can run
  it, else as its build information names it, read from the binary
  without running it; of a smock it cannot run, it also prints the
  SHA-256, which `conditions.json` records too. For
  another architecture than the machine's, it checks that the images'
  Dockerfiles only copy, since a `RUN` would need emulation. It reads the
  project, checks that the Artifact Registry, Compute Engine and
  Kubernetes Engine APIs are enabled (it prints the command that enables
  them; `--enable-apis` runs it), that `GKE_BENCH_ZONE`, when set, is in
  the region, that the quotas the run's nodes draw on have enough free,
  and that no cluster or repository of an earlier run is left. The run
  needs four nodes of 8 vCPUs: Autopilot's first node, its system node,
  smock's and the load generator's. With a quota at the run's minimum,
  such as 24 vCPUs (`GKE_BENCH_NEEDED_CPUS=24`), the load generator's node
  cannot be added at first (`FailedScaleUp ... quota exceeded`), and the
  load generator waits until Autopilot frees a node. That wait invites the
  cluster autoscaler to consolidate the nodes: in the run of 2026-10-19 it
  removed the load generator's node about two minutes after the load
  generator started, and the profile ended after 5 of its 14 steps. A run
  now keeps the load generator's node (see **Profiles**), but a quota of
  32 vCPUs avoids the wait.
  Autopilot's two are x86 nodes on either
  architecture; smock's and the load generator's are of the run's. So it
  needs 32 vCPUs free in `CPUS_ALL_REGIONS` (`GKE_BENCH_NEEDED_CPUS`, from
  which the number of nodes follows); in the region's `CPUS`, 8 for each
  x86 node; 100 GB of boot disk a node, in the region's `SSD_TOTAL_GB` for
  an x86 node (pd-balanced, GKE's default) and in `HDB_TOTAL_GB` for an
  Arm node (hyperdisk-balanced, as the probe's Arm nodes had); and an
  external IP address a node, in `IN_USE_ADDRESSES`. An Arm node's vCPUs
  count in a CPU quota of its machine family, which gcloud does not list:
  an arm64 run says that it is not checked, and the console's Quotas page
  shows it. It names each quota with how much is free and how much the
  run needs, and says which is short or cannot be read. Then it prints how
  long the run takes and what it costs, expected and at most, and stops
  unless `--yes` says to go on.
- **Images.** It builds the release binary, unless given one, and two
  images for the run's architecture (`docker build --platform`): the
  release image with `bench/definitions/` and its Scenario and CRUD
  variants (`bench/gke/smock-definitions.dockerfile`), and the load
  generator's (`bench/gke/generator.Dockerfile`: Python, the pinned oha
  of that architecture, `bench.py`, both request mixes, the plan and
  `bench/gke/`). With `--variant`
  it builds no binary, and in place of the release image one image of
  smock for each distinct binary the variants give (see
  [Comparing smock binaries on one node](#comparing-smock-binaries-on-one-node)).
  The images only copy files onto multi-architecture bases, so a machine
  of the other architecture builds them with no emulation; `python3 -m unittest
  discover -s bench` fails if a `RUN` appears. It pushes them to a new
  Artifact Registry repository, and lets the nodes' service account (the
  project's Compute Engine default one, or
  `GKE_BENCH_NODE_SERVICE_ACCOUNT`, which the nodes then run as) read that
  repository only.
- **Cluster.** A new Autopilot cluster on the Regular channel. The cluster
  and the repository are named `smock-bench-<date>-<time>` and labelled
  `purpose=smock-bench`. kubectl authenticates with a new access token
  from gcloud, taken again before its hour ends, in a kubeconfig of the
  run's own (mode 600, deleted at the end), so gke-gcloud-auth-plugin is
  not needed and `~/.kube/config` is not touched.
- **Profiles.** For each profile: smock in a Pod, with the profile's CPU
  and memory limits as its requests, behind a ClusterIP Service, both
  named for the profile (`smock-<profile>`), so that a lookup of the name
  cannot get the address of the previous profile's Service; then the load
  generator (`bench/gke/generator.py`) in a Job with 6 vCPU and 6 GiB on
  amd64 (an x86 vCPU is a hyperthread, and 4 fell behind at 20,000
  requests a second), 4 vCPU and 4 GiB on arm64, either within an 8-vCPU
  node, and a required anti-affinity that keeps it off smock's node. Both
  have an `activeDeadlineSeconds` that ends them within minutes of the
  time limit at the latest, so that they stop being billed even if nothing
  is left to delete the cluster (smock is a Pod, not a Deployment, to have
  one). Both run on nodes of the run's architecture: the built-in
  `autopilot-arm` compute class on arm64, Autopilot's default
  general-purpose x86 Pods on amd64. Autopilot chooses smock's zone, and a
  required Pod affinity keeps the load generator in it; `GKE_BENCH_ZONE`
  pins both to one zone instead. The cluster autoscaler removes a node
  only when it may evict every Pod on it. A PodDisruptionBudget
  (`minAvailable: 1`) over the load generator's Pod, applied before its
  Job and deleted with it, allows no eviction of that Pod, so its node
  stays while the profile runs. smock's Pods are not managed by a
  controller, which keeps their node already. Neither has the
  `cluster-autoscaler.kubernetes.io/safe-to-evict` annotation: on
  Autopilot it raises a Pod's requests to at least 0.5 vCPU and 0.5 GiB
  and forbids inter-Pod affinity, which the small profiles and the
  placement of the Pods need. Nothing keeps a Pod of a higher priority
  from preempting them. Before smock starts, an init container
  in its Pod, from the load generator's image and with smock's limits so
  that the Pod asks for no more, prints the CPU of smock's node
  (`bench/gke/gke.py node-cpu`): its model name, vendor, family, model and
  stepping (on arm64, its implementer, part, variant and revision), its
  microcode, whether it has the flags that make TLS fast (`aes`, `avx2`,
  `sha_ni` and `vaes` on x86; `aes`, `pmull` and `sha2` on arm64), and
  what the kernel says of each of its vulnerabilities, from
  `/proc/cpuinfo` and `/sys/devices/system/cpu/vulnerabilities`. It
  succeeds whatever it can read, so that smock always starts. The load
  generator says the same of its own node. The load generator sends each
  step the way `bench/bench.py` does, with its functions, and prints one
  JSON line for each step, a case as `summary.json` has it. It looks up the
  Service's address once smock answers by name. Before any load, once
  smock has idled for the plan's settle time after it was ready, it reads
  smock's idle RSS from smock's `/metrics`. Before the first step it
  sends the first request of the mix to the plain and the TLS port there,
  for up to 60 s each until it gets a response; after a step that got no
  response at all, it checks again, since an overloaded smock can answer
  none of a step's measured requests and still be there. When a port does
  not answer, it runs no further step of the profile: the summary marks
  the steps it did not run as not measured, with the reason, and the run
  goes on to the next profile once the load generator's Job and smock's
  Pod and Service are deleted (it waits for that), and exits 1, as it does
  whenever a step of the plan was not measured.
  The namespace's quota allows no LoadBalancer, NodePort or volume claim,
  and the run makes no static IP.
- **Always deleted.** When the run ends, fails or is stopped (Ctrl-C,
  SIGTERM, a closed terminal), it deletes the cluster and the repository;
  after a closed terminal it logs that to `after-hangup.log` in the results
  directory. A watchdog in its own session deletes them at the time limit
  (`--time-limit` with its unit, 80m by default and at most 240m) even if
  the script was killed; nothing is made until the watchdog has started.
  At the end it lists the project's clusters, repositories, VM instances,
  disks, addresses and forwarding rules, and fails, naming them, if any is
  new since the start.
- **When the machine goes away.** The watchdog runs on the machine that
  runs the script: if that machine sleeps, loses its network or shuts down,
  nothing deletes the cluster until it is back. Keep it awake and on power
  for the run (on Linux, for example, under `systemd-inhibit`). The Pods
  still end soon after the time limit, so a cluster left this way costs
  its fee, $0.10 an hour, until deleted (the free tier covers one
  cluster); a later `scripts/gke-bench.sh --dry-run` names it.
- **Architectures.** The images are for `--arch`, whatever the machine
  that runs the script: smock's binary for another architecture comes from
  CI (`--smock`, above), and oha's is the pinned release of that
  architecture (`scripts/install-oha.sh <directory> <arch>`). The run
  records the architecture, the region, the zone and the nodes' machine
  types in `conditions.json`; `bench/compare.py` says when two runs differ
  in architecture, and does not compare their latencies as regressions.

It writes to `bench/results/gke-<date>-<time>/` unless `--out` says
otherwise: `raw/<profile>/generator.log`, the load generator's lines;
`raw/<profile>/pods.json`, the nodes the Pods ran on (with each one's
boot disk type, `boot_disk`), smock's restarts and the load generator's
CPU request, kept as soon as each Pod has a node, with smock's restarts
unknown (null), and again at the profile's end, with them (a run that
stops before then, or cannot read them then, leaves them unknown, and
smock's OOM kills under the profile unmeasured);
`raw/<profile>/smock-node-cpu.log`, what smock's init container printed
of the CPU of its node, kept once smock has started;
`raw/<profile>/smock.log`, smock's log (and the log of its container
before its last restart, when it restarted or that is not known, with
kubectl's errors in their place); and `raw/<profile>/service.json`, its
Service with the Service's EndpointSlices, both kept before smock's Pod
is deleted; when the load generator's Job failed,
`raw/<profile>/events.json` and `raw/<profile>/node-events.json`, the
events of the namespace and of the load generator's node, and
`raw/<profile>/job-failure.json`, why it failed as `gke.py job-failure`
reads them;
`summary.json` in the layout of a run on a machine, which
`bench/compare.py` reads; `summary.md`; `conditions.json`; and
`watchdog.log`. The summary and the conditions record, for each profile,
whether the traffic ports answered, whether the profile ended early and
why, and the load generator's CPU request; the conditions also record,
for each node of each profile, its CPU (`cpu`, as `gke.py node-cpu`
prints it, or null when it is unknown), whose model `summary.md` shows
beside each node; `machine.cpu_model` names only the node type, as in a
run from before the nodes' CPUs were recorded, so that comparing with one
does not show another machine. A run that stops
once a profile has started, because something fails or it is stopped
(Ctrl-C, SIGTERM, a closed terminal, or the watchdog at the time limit,
which it names as the reason), still writes `summary.json`,
`summary.md` and `conditions.json` from what it measured; `summary.md`
then says, right below the line that says when the run started and what
ran, under which profile and after which step it stopped, and why
(`gke.stopped` in `summary.json`). So it does when the run leaves out
the profiles after one whose Pods were not deleted in time, or from one
that no longer fits in the time limit.
When the load generator's Job fails before the load generator can say
why, as when its node goes, the run says why from the events: the
cluster autoscaler scaled down its node, its Pod was preempted or
evicted, the kernel killed a process on its node for memory, or the
Job's deadline passed, with the event that shows it. Otherwise it says
that its events name no known reason, and where they and the load
generator's log are. The run's output and `summary.md` say it as why the
profile ended early, with the steps it did not measure, and the next
profile runs.
The summary checks the targets of the run's architecture (`--arch`).
Nothing outside smock's Pod can read its cgroup on Autopilot, so what
smock used comes from its own
`/metrics`, its [process and cgroup metrics](../README.md#run), which the load
generator scrapes right before and right after each step, and a second
into it: its CPU time and throttling during the step and in its first
second, from its container's cgroup, with the CPU time a request and
against the CPU limit; how long it waited for a CPU, the time the CFS
quota held it back included, and its node's steal time; its RSS at the
step's start and end,
the larger as its max; and the most memory its container had used by the
step's end (`memory.peak`), since smock started under the profile, so
earlier steps count too. A smock without those metrics leaves them, idle
RSS and the targets on them unmeasured. OOM kills come from smock's
restarts at the profile's end. Nothing it writes names the account or
the project, and what it prints shows the project as `$GKE_BENCH_PROJECT`
and gcloud's account as `<account>`.

`python3 -m unittest discover -s bench` tests the helper, the load
generator against smock on this machine, and the script against fake
gcloud, kubectl and docker commands, including that every way a run ends
deletes what it made.

### Comparing smock binaries on one node

One binary used 15 to 25% more or less CPU a request from one node to
another in the GKE runs of 52ee405, and close to twice as much on one
ek-standard-8 node as on another with the same CPU in a later run: more
than the difference between binaries those runs were to measure.
`--variant` compares 2 to 4 smock binaries,
or one binary with other options, on one node instead. Under each
profile, each variant runs in a Pod of its own with the profile's
limits, all on the first one's node (a required Pod affinity on the
node's hostname; Autopilot refuses anti-affinity below 0.5 vCPU), and one
load generator measures them one at a time over `--rounds` rounds (4 by
default): each round runs every step, and each step every variant, their
order turned by one for each round and step, so that a variant's run and
the baseline's in the same round and step are close in time: next to
each other, about 30 seconds apart, with two variants; with four, one to
three runs apart (each run is the step's 25 s, its analysis and its 2 s
cool-down, about 32 s, so about 30 to 100 seconds), and a variant two
places after the baseline, like newb below, is always two runs from it.
`bench/plan-same-node.json`
is the plan for it: HTTP keep-alive at the two lowest rates of
`bench/plan-autopilot.json`'s ladders under 50m and 250m, where the
binary of 52ee405 used more CPU a request than that of 0d984c8, and at
half the lowest, since the newer binary came near its CPU limit from the
second step and a pair in which a run saturated does not count; and two
rates under 1 CPU as a control.

```sh
old=$(mktemp -d) new=$(mktemp -d)
gh run download <run-id> -R hirunefu/smock -n smock-linux-amd64 --dir "$old"   # CI's run on the push of the older commit
gh run download <run-id> -R hirunefu/smock -n smock-linux-amd64 --dir "$new"   # and of the newer one
export GKE_BENCH_PROJECT=<project ID> GKE_BENCH_REGION=us-central1 GKE_BENCH_ZONE=us-central1-a
scripts/gke-bench.sh --yes --arch amd64 --plan bench/plan-same-node.json \
  --profiles autopilot-burst-min,autopilot-min --time-limit 120m \
  --variant old="$old/smock" --variant new="$new/smock" --variant newb="$new/smock" \
  --variant newh="$new/smock",no-init,no-first-second
```

Each `--variant` is `LABEL=FILE`, the first the baseline; the label (1 to
16 lowercase letters, digits and hyphens, starting with a letter and
ending with a letter or digit) names the variant's Pod and Service,
`smock-<profile>-<label>`. `no-init` leaves out the init
container that prints the node's CPU, and `no-first-second` the load
generator's scrape of smock's `/metrics` a second into each step: the two
changes the harness got between 0d984c8 and 52ee405. `scenarios` serves
the Scenario variant of the definitions, `bench/definitions-scenarios/`,
in place of `bench/definitions/`
([Scenarios in the benchmark](#scenarios-in-the-benchmark)). `crud`
serves their CRUD variant, `bench/definitions-crud/`, and the load
generator sends that variant the CRUD variant's mix,
`bench/requests-crud.json`, and the others the benchmark's
([CRUD Stubs in the benchmark](#crud-stubs-in-the-benchmark)). A variant
takes one of the two.
Variants of one binary (one SHA-256) are also compared with the first
variant that has it: with the same options,
such as newb against new, an A/A pair, whose paired changes show how far
runs of one binary differ on the node, the A/A spread; with other
options, such as newh against new, what those options cost. A binary
must be for the run's architecture, but may be built from any commit:
the harness is the commit checked out, and the binaries are what the run
compares. The script prints each one's SHA-256, and the commit it says
when the machine can run it; each distinct binary gets one image, which
the variants with it share. CI keeps a binary for 7 days; for an older
commit, push a branch at it, and CI builds it again. The run starts each
variant once the one before is ready, and before the load generator
starts, checks (`gke.py placement`) that every variant is on one node,
admitted with the profile's limits as its requests and limits. When not,
or when a variant cannot join the first one's node in 15 minutes, it
stops there, with the Pods, their events and their logs kept.

Besides `raw/<profile>/`, with each variant's log and Service in
`raw/<profile>/<label>/`, it writes a sample of each variant in each
round, `samples/<round>-<label>/`: the variant's steps in that round,
summarized as a run of that binary alone, which `bench/compare.py`
compares with any other run. smock's idle RSS is read once, before any
load, so only round 1's samples have it, and a later one shows its
target as not measured; a sample of a `no-first-second` variant says
that its runs had no scrape a second in. Its `summary.md` is
`same-node.md`, the comparison (`same-node.json` holds it too). That
names each variant's commit, version, SHA-256 and options, and says
whether the samples' conditions besides smock were the same; then, for
each profile, the node and its CPU, whether every variant was on it with
the plan's limits, the order the variants ran in, the most CPU an idle
variant used beside another's run, and a row for each variant at each
step: its CPU a request, as the median of its runs with the lowest, the
highest and how many; the change from the baseline's; the range of the
changes of its runs from the baseline's in the same round, and how many
were higher; the throttled periods; the CPU wait; the node's steal time;
p99; and the runs that saturated, at 90% of the CPU limit or more. Each
variant's verdict takes the pairs of runs, over every step, in which
neither saturated: their median change and range, how many were higher,
and the p of an exact sign test, whose smallest with 8 pairs is 0.008.
Fewer than 6 pairs that differ cannot give a p of 0.05 or less, so with
5 or fewer it says there are too few pairs to decide; above 0.05, it
says no clear difference, and so it does, whatever the p, when the
median change lies inside the profile's A/A spread. Below the verdicts,
each variant of one binary has its own against the first with it, the
A/A pair's and the other options'. A drift line compares each variant's
first round with the later ones. The run exits 1 when the variants
cannot be compared: on more than one node, under other limits than the
plan's, or with a sample incomplete.

To see what Scenarios cost on one node, run one binary without the
`scenarios` option and with it twice, an A/A pair to read the cost
against. A `scenarios` variant's samples record the definitions they
served, and the comparison does not count their other definition set as
a condition besides smock. It takes as long and costs as much as the
pre-merge run of three variants
([docs/merging-into-main.md](../docs/merging-into-main.md)):

```sh
scripts/gke-bench.sh --yes --arch amd64 --plan bench/plan-same-node.json \
  --profiles autopilot-burst-min,autopilot-min --time-limit 100m \
  --variant plain="$dir/smock" --variant sc="$dir/smock",scenarios --variant scb="$dir/smock",scenarios
```

To see what CRUD Stubs cost on one node, do the same with the `crud`
option. A `crud` variant's samples record the definitions they served and
the mix they were sent, and the comparison counts neither as a condition
besides smock:

```sh
scripts/gke-bench.sh --yes --arch amd64 --plan bench/plan-same-node.json \
  --profiles autopilot-burst-min,autopilot-min --time-limit 100m \
  --variant plain="$dir/smock" --variant cr="$dir/smock",crud --variant crb="$dir/smock",crud
```

To read the variants against another baseline, such as each against
new, run `gke.py same-node` again on the run's results with
`--baseline new --report same-node-new` and the `--sha256 LABEL=HEX` and
`--no-init LABEL` the run gave it (same-node.json names each variant's
SHA-256 and options; the samples say which served the Scenario or the
CRUD variant):
it writes `same-node-new.json` and
`same-node-new.md`, and leaves the run's own comparison as it is.

```sh
python3 bench/gke/gke.py same-node --baseline new --report same-node-new \
  --sha256 old=<SHA-256 of old> --sha256 new=<SHA-256 of new> --sha256 newb=<SHA-256 of new> \
  --sha256 newh=<SHA-256 of new> --no-init newh <results directory>
```

The run of four variants above, two profiles of 48 runs each, costs
about $0.43 in
us-central1 at the prices of 2026-10-16, or $0.30 while the free tier
covers the cluster's fee: the cluster lives about 77 minutes, and the
load generator about 54. A profile starts only when its Job's deadline,
48 minutes there, and 10 minutes more fit before the time limit, so the
second needs a limit of about 100 minutes, which the estimate checks
before anything is made, and more when the images take long to push or
the cluster to make; 110 leaves about 10 minutes, at most $0.86, and
120 leaves room, at most $0.94.

## In CI

`.github/workflows/benchmark.yml` runs the benchmark on linux/amd64 and
linux/arm64 when started by hand from the Actions tab, optionally for some
cases or CPU limits only. It builds the release binary, installs oha, lets
the runner's systemd user manager set CPU quotas, runs the harness's tests
and then the whole of `bench/plan.json`, whose profiles have no memory
limits, so it reports the [targets](#targets) as not measured. The output
of each architecture is a workflow artifact, `benchmark-linux-amd64` and
`benchmark-linux-arm64`, and the run's page shows the summaries. It never
runs on a schedule, on pull requests or on pushes:
`scripts/check-benchmark-workflow.sh` checks in CI that it has no trigger
but `workflow_dispatch`. GitHub's shared runners vary from run to run, so a
single run is a rough measure.
