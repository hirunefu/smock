# Before merging into main

Work lands on an integration branch (such as `integration/r1`), and the
integration branch is merged into `main` when it is ready. Benchmarks run on
a developer's machine by default. The full benchmark and a run on real GKE
Autopilot happen only here, before that merge (the decision on #4):

- Nothing runs the benchmark on a schedule. `.github/workflows/benchmark.yml`
  runs only when started by hand from the Actions tab, not on pull
  requests or pushes either, and `scripts/check-benchmark-workflow.sh`
  checks in CI that it has no trigger but `workflow_dispatch`.
- No runner or cluster is kept for benchmarks. A GKE run makes its cluster
  and deletes it again.

Work through the checklist in order. Each run's results go to
`bench/results/`, which git ignores; keep the directories of each
pre-merge run somewhere that lasts (outside the worktree), since the next
pre-merge run compares with them.

## Checklist

- [ ] **CI is green on the integration branch**, and its issues are done.
- [ ] **Run the local Autopilot plan** on the usual machine, the full plan
  (about 20 minutes), as the README's
  [GKE Autopilot profiles](../README.md#gke-autopilot-profiles) section
  says: plugged in, other programs closed, the CPU frequency governor at
  `performance`.

  ```sh
  scripts/build-release.sh
  python3 bench/bench.py run --plan bench/plan-autopilot.json --out bench/results/premerge-local-<date>
  ```

  Read the *Targets* table of its `summary.md`. A missed target is a
  finding to resolve or to record before the merge.
- [ ] **Compare it with the previous pre-merge local run**, from the same
  machine:

  ```sh
  python3 bench/compare.py <previous local results> bench/results/premerge-local-<date>
  ```

  It exits with 1 when p99 or p99.9 got more than 20% (and more than 1 ms)
  worse at a profile, case and rate, when a target was missed, or when the
  newer run did not measure a step the older one measured
  ([Comparing runs](../README.md#comparing-runs)). Its first lines say
  whether the machine, the plan or anything else besides smock differed.
- [ ] **Run the benchmark on GKE Autopilot** with `scripts/gke-bench.sh`
  ([On GKE Autopilot](../README.md#on-gke-autopilot)). It needs gcloud
  logged in (`gcloud auth login`), docker, kubectl, and the MoonBit
  toolchain or a release binary, and the project and region in the
  environment. The pre-merge run is on x86 (amd64) nodes in Tokyo
  (asia-northeast1), whatever machine starts it: Autopilot has x86 Pods in
  every region, and plenty of them. Keep to one architecture from run to
  run, so that each compares with the previous one. From an arm64
  machine, which cannot build smock for amd64, take the release binary CI
  built for linux/amd64 on the push of the commit checked out (check that
  the run's `headSha` is `git rev-parse HEAD`; CI keeps it for 7 days).
  First a dry run, which only reads:

  ```sh
  gh run list -R hirunefu/smock --workflow CI --branch integration/r1 --event push --limit 1 --json databaseId,headSha
  dir=$(mktemp -d)
  gh run download <run-id> -R hirunefu/smock -n smock-linux-amd64 --dir "$dir"
  export GKE_BENCH_PROJECT=<project ID> GKE_BENCH_REGION=asia-northeast1
  scripts/gke-bench.sh --dry-run --arch amd64 --smock "$dir/smock"
  ```

  An Arm (arm64) run needs a region with Arm Pods: us-central1, us-east1,
  us-west1, europe-west1, europe-west2, europe-west4 or asia-southeast1
  (GKE's documentation, 2026-10-14); the script warns of any other. One
  failed when its zone had no Arm nodes left. Unless `GKE_BENCH_ZONE` pins
  one, Autopilot chooses the zone, and the load generator runs in smock's.

  It checks the APIs, the CPU quota (32 vCPUs free in `CPUS_ALL_REGIONS`
  and in the region's `CPUS`; ask for more on the console's Quotas page if
  not), and that nothing is left from an earlier run, and prints every
  command it would run and the cost estimate. A full run is expected to
  cost about $0.20, and at most about $0.50 if it ran until its time limit
  of 80 minutes, before tax (about $0.60 in asia-northeast1); the free
  tier usually covers the cluster's management fee. When the checks pass
  and the estimate is acceptable, run it (about 50 minutes), with the
  machine kept awake, on power and online for the whole run, since the
  watchdog that deletes the cluster at the time limit runs on it:

  ```sh
  systemd-inhibit --what=sleep:idle:handle-lid-switch scripts/gke-bench.sh --yes --arch amd64 --smock "$dir/smock"
  ```

  Only the maintainer starts a run with `--yes`, since it costs money. It
  must end with `nothing is left`. If it says what is left instead, or
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
  the first of its own and the baseline of the next.
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
  gh pr create --base main --head integration/r1 --title "Merge integration/r1" --body-file <summary>
  gh pr merge --merge
  ```

  or locally, with the summary in the merge commit's message:

  ```sh
  git switch main && git merge --no-ff integration/r1 && git push
  ```

- [ ] **Restore the agent skills.** `main` once tracked the skills under
  `.agents/skills/`, which the integration branches leave untracked
  (`.gitignore`), so the merge deletes them from the working tree.
  `skills-lock.json` records them; restore them and link them for Claude
  Code:

  ```sh
  npx skills experimental_install
  mkdir -p .claude/skills && for s in .agents/skills/*; do ln -sfn "../../$s" ".claude/skills/${s##*/}"; done
  ```

- [ ] **Keep the results** of both runs as the baseline of the next
  pre-merge run.
