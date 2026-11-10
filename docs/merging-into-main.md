# Before merging into main

This page is for the maintainer. Work lands on an integration branch (`integration/<name>`), and the
integration branch is merged into `main` when it is ready. Benchmarks run on
a developer's machine by default. The full benchmark and a run on real GKE
Autopilot happen only here, before that merge (the decision on #4):

- Nothing runs the benchmark on a schedule. `.github/workflows/benchmark.yml`
  runs only when started by hand from the Actions tab, not on pull
  requests or pushes either, and `scripts/check-benchmark-workflow.sh`
  checks in CI that it has no trigger but `workflow_dispatch`.
- No runner or cluster is kept for benchmarks. A GKE run makes its cluster
  and deletes it again.

Dependabot's pull requests are the exception. They move only the GitHub
Actions and the image's base, and go into `main` on green CI, without
this checklist ([Dependency updates](releasing.md#dependency-updates)).

Work through the checklist in order. Each run's results go to
`bench/results/`, which git ignores; keep the directories of each
pre-merge run somewhere that lasts (outside the worktree), since the next
pre-merge run compares with them.

## Checklist

- [ ] **CI is green on the integration branch**, and its issues are done.
  CI also runs h2spec, the HTTP/2 conformance tool, against the plain
  port and the TLS port, on linux/amd64
  ([Build and test](../README.md#build-and-test)). Before the merge, its
  lists of the cases that do not pass, `scripts/h2spec/plain.txt` and
  `scripts/h2spec/tls.txt`, name no case that waits for an issue, and each
  listed case that the run reports as passing has come off them. On a branch that raises moonhttp, this run is
  part of the checks the upgrade needs.
- [ ] **If the branch raises moonhttp**, it has passed the gate of
  [Upgrading moonhttp](releasing.md#upgrading-moonhttp): h2spec against
  both traffic ports, the e2e tests, and the interop check by hand with
  curl, Go, the JVM and a browser, with the results in the merge record.
  The runs below follow, as for any branch. Any change that raises the
  moonhttp version the build resolves is such an upgrade, and CI fails on
  it until `moon.mod` names the new version.
- [ ] **Run the local Autopilot plan** on the usual machine, the full plan
  (about 54 minutes), as the benchmark's
  [GKE Autopilot profiles](../bench/README.md#gke-autopilot-profiles) section
  says: plugged in, other programs closed, the CPU frequency governor at
  `performance`.

  ```sh
  scripts/build-release.sh
  python3 bench/bench.py run --plan bench/plan-autopilot.json --out bench/results/premerge-local-<date>
  ```

  Read the *Targets* table of its `summary.md`. Targets are checked per
  CPU architecture: `bench/targets.json` has a set for arm64 and one for
  amd64, a run checks the set of the architecture it ran on (arm64 on the
  M1), and the line above the table says which. A missed target is a
  finding to resolve or to record before the merge. The targets of
  `http-keep-alive` hold for the two HTTP/2 cases too, so a miss on one of
  them is such a finding as well
  ([Targets for several cases](../bench/README.md#targets-for-several-cases)).
- [ ] **Compare it with the previous pre-merge local run**, from the same
  machine:

  ```sh
  python3 bench/compare.py <previous local results> bench/results/premerge-local-<date>
  ```

  It exits with 1 when p99 or p99.9 got more than 20% (and more than 1 ms)
  worse at a profile, case and rate, when a target was missed, or when the
  newer run did not measure a step the older one measured. Only steps at
  or below their profile's target rate in `bench/targets.json`, for the
  newer run's architecture, count, and
  p99.9 only where both runs measured at least 10,000 requests at the
  step: the rest swing from run to run, and the report shows them for
  reference without failing
  ([Comparing runs](../bench/README.md#comparing-runs)). A previous run from
  before the [HTTP/2 cases](../bench/README.md#http2-cases) has no steps
  for them: they are listed as only in the newer run, and the HTTP/1.1
  cases are compared as usual. `h2c-multiplexed`, which runs only here and
  has no target, is likewise listed against a run from before it, and
  compared like any case against a run that has it. Its first lines say
  whether the machine, the plan or anything else besides smock differed,
  and which steps count. A change to the plan's `about` alone is no
  difference, but a run from before runs recorded the plan's hash without
  it, such as the pre-merge run of 0d984c8, has only its file's hash: the
  first comparison with one may show the plan as changed when only its
  description did. A verdict that says *disturbed* means other tasks used
  at least 1% of smock's CPUs in that step, in either run: rerun that
  profile with other programs closed before looking for the cause in
  smock. A run from before runs recorded other tasks, such as the
  pre-merge run of 0.3.0, has no record of them, and the report says so.
- [ ] **Run the local Autopilot plan with the `mockoon` log format**, right
  after, with the same binary, and compare it with the run above
  ([In the merge checklist](../bench/README.md#in-the-merge-checklist)):

  ```sh
  python3 bench/bench.py run --plan bench/plan-autopilot.json --log-format mockoon --out bench/results/premerge-local-<date>-mockoon
  python3 bench/compare.py bench/results/premerge-local-<date> bench/results/premerge-local-<date>-mockoon
  ```

  The mode on stalls when the comparison fails by the rule at a step
  that counts. Then take the numbers to the maintainer before the merge,
  who decides what to do: request lines are written by an async write
  that their own request awaits, so a stall shows there. Its missed
  targets are for reference only. The run itself exits with 1 when a
  step's `Transaction recorded` lines differ from the requests smock
  answered: a bug to fix before the merge.
- [ ] **Run the benchmark on GKE Autopilot** with `scripts/gke-bench.sh`
  ([On GKE Autopilot](../bench/README.md#on-gke-autopilot)). It needs gcloud
  logged in (`gcloud auth login`), docker, kubectl, python3, setsid, curl,
  and the MoonBit toolchain or a release binary, and the project and
  region in the
  environment. The pre-merge run is on x86 (amd64) nodes, in zone
  us-central1-a, whatever machine starts it: Autopilot has x86 Pods in
  every region, and plenty of them, and us-central1 costs less than
  Tokyo. Keep to one architecture and one zone from run to run, so that
  each compares with the previous one; its summary checks the targets of
  that architecture, the amd64 ones on x86 nodes. From an
  arm64 machine, which cannot build smock for amd64, take the release
  binary CI built for linux/amd64 on the push of the commit checked out
  (check that the run's `headSha` is `git rev-parse HEAD`; CI keeps it for
  7 days; the script refuses a binary whose build information names
  another commit).
  First a dry run, which only reads:

  ```sh
  gh run list -R hirunefu/smock --workflow CI --branch integration/<name> --event push --limit 1 --json databaseId,headSha
  dir=$(mktemp -d)
  gh run download <run-id> -R hirunefu/smock -n smock-linux-amd64 --dir "$dir"
  export GKE_BENCH_PROJECT=<project ID> GKE_BENCH_REGION=us-central1 GKE_BENCH_ZONE=us-central1-a
  scripts/gke-bench.sh --dry-run --arch amd64 --smock "$dir/smock"
  ```

  An Arm (arm64) run needs a region with Arm Pods: us-central1, us-east1,
  us-west1, europe-west1, europe-west2, europe-west4 or asia-southeast1
  (GKE's documentation, 2026-10-14); the script warns of any other. One
  failed when its zone had no Arm nodes left. Unless `GKE_BENCH_ZONE` pins
  one, Autopilot chooses the zone, and the load generator runs in smock's.

  It checks the APIs, the quotas the run's four nodes draw on (on amd64,
  32 vCPUs free in `CPUS_ALL_REGIONS` and in the region's `CPUS`, 400 GB
  of boot disk in `SSD_TOTAL_GB`, and 4 addresses in `IN_USE_ADDRESSES`;
  on arm64, where only Autopilot's two nodes are x86, 16 of the vCPUs in
  `CPUS` and 200 GB in each of `SSD_TOTAL_GB` and `HDB_TOTAL_GB`, and the
  Arm nodes' own CPU quota is not checked; it names the one that is short,
  and more can be asked for on the console's Quotas page), and that nothing is
  left from an earlier run, and prints every
  command it would run and the cost estimate. A full amd64 run is
  expected to cost about $0.40, and at most about $0.78 if it ran until
  its time limit of 100 minutes, before tax (about $0.48 and $0.95 in
  asia-northeast1); the free tier usually covers the cluster's management
  fee. When the checks pass
  and the estimate is acceptable, run it (about 75 minutes), with the
  machine kept awake, on power and online for the whole run, since the
  watchdog that deletes the cluster at the time limit runs on it:

  ```sh
  systemd-inhibit --what=sleep:idle:handle-lid-switch scripts/gke-bench.sh --yes --arch amd64 --smock "$dir/smock"
  ```

  Only the maintainer starts a run with `--yes`, since it costs money. It
  must end with `nothing is left`. A profile whose traffic ports did not
  answer, before its first step or after a step that got no response at
  all, ends early: the run says `profile <name> ended early` and why, goes
  on to the next profile, and exits 1. Look at `raw/<profile>/smock.log`
  and `raw/<profile>/service.json` in the results directory, and at the
  address the load generator checked in `raw/<profile>/generator.log`, to
  find out why, and run again once it is understood. If it says what is left instead, or
  was killed, delete what it names (it prints the commands), and check
  `watchdog.log` in the results directory: the watchdog deletes the
  cluster and the repository at the time limit even when the script was
  killed. If the machine slept, lost its network or shut down during the
  run, the watchdog may not have run: run `scripts/gke-bench.sh --dry-run`,
  which names any cluster or repository left by an earlier run, and delete
  them. The billing report shows the actual cost a day or so later.
- [ ] **Compare the GKE run with the previous pre-merge GKE run**:

  ```sh
  python3 bench/compare.py <previous GKE results> bench/results/gke-<date>-<time>
  ```

  Compare GKE runs with GKE runs and local runs with local runs: the
  numbers of the two kinds differ by design (about half the throughput on
  GKE), and the comparison says so when they are mixed. Runs on different
  architectures are not compared as regressions: the comparison says that
  they differ, compares no step, and still fails on a missed target. When
  the previous pre-merge GKE run was on the other architecture, this run is
  the first of its own and the baseline of the next. When smock's node had
  another CPU under a profile, the comparison names how: a latency that
  changed with it may be the node's rather than smock's. Each step's
  `per_second` and `smock_cpu` in `summary.json` (its first second, how
  long smock waited for a CPU beside how long its CPU limit held it back,
  `throttled_s`, which that wait includes, the node's steal time) help
  tell them apart. When the targets have changed since a run,
  `python3 bench/bench.py check-targets <results>` checks it against them
  as they are now, without running anything or changing its directory.

  Under the small CPU limits (autopilot-burst-min and autopilot-min), a
  regression of smock's CPU a request, or a step that now saturates, may
  be the node's. In the GKE runs that compared the binaries of 0d984c8
  and 52ee405, smock's CPU a request differed by close to 2× between
  ek-standard-8 nodes with the same CPU, far more than between the two
  binaries on one node. Before you treat such a regression as
  smock's, settle it on one node
  ([Comparing smock binaries on one node](../bench/README.md#comparing-smock-binaries-on-one-node)).
  Run `main`'s binary and the integration branch's as variants, the
  latter twice as an A/A pair. It is expected to cost about $0.33 in
  us-central1, and at most $0.77:

  ```sh
  scripts/gke-bench.sh --yes --arch amd64 --plan bench/plan-same-node.json \
    --profiles autopilot-burst-min,autopilot-min --time-limit 100m \
    --variant main="$main/smock" --variant new="$dir/smock" --variant newb="$dir/smock"
  ```

  `$main/smock` is the release binary CI built for linux/amd64 on the
  push of `main`'s commit. Its `summary.md` says, step by step and over
  each profile, whether `new` costs more than `main` on the same node,
  read against how far `new` and `newb` differ. A difference inside that
  spread is not a regression.
- [ ] **Post the summary on the pull request or the merge record**: both
  runs' `summary.md` and both comparisons. They name the machine, the
  architecture, region, zone and node types, never the account or the
  project; check before posting that nothing does:

  ```sh
  grep -rl "$GKE_BENCH_PROJECT" bench/results/premerge-local-<date> bench/results/gke-<date>-<time> || echo clean
  ```

  The raw data (`raw/`, `conditions.json`) stays with the maintainer.
- [ ] **Merge** the integration branch into `main` with a merge commit:
  through a pull request, which holds the summary,

  ```sh
  gh pr create --base main --head integration/<name> --title "Merge integration/<name>" --body-file <summary>
  gh pr merge --merge
  ```

  or locally, with the summary in the merge commit's message:

  ```sh
  git switch main && git merge --no-ff integration/<name> && git push
  ```

- [ ] **Keep the results** of both runs as the baseline of the next
  pre-merge run.
