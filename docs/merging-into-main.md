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
  worse at a profile, case and rate, or when a target was missed
  ([Comparing runs](../README.md#comparing-runs)). Its first lines say
  whether the machine, the plan or anything else besides smock differed.
- [ ] **Run the benchmark on GKE Autopilot** with `scripts/gke-bench.sh`
  ([On GKE Autopilot](../README.md#on-gke-autopilot)). It needs gcloud
  logged in (`gcloud auth login`), docker, kubectl and the MoonBit
  toolchain, and the project and region in the environment. First a dry
  run, which only reads:

  ```sh
  export GKE_BENCH_PROJECT=<project ID> GKE_BENCH_REGION=us-central1
  scripts/gke-bench.sh --dry-run
  ```

  It checks the APIs, the CPU quota (32 vCPUs free in `CPUS_ALL_REGIONS`
  and in the region's `CPUS`; ask for more on the console's Quotas page if
  not), and that nothing is left from an earlier run, and prints every
  command it would run and the cost estimate. A full run is expected to
  cost about $0.20, and at most about $0.50 if it ran until its time limit
  of 80 minutes, before tax; the free tier usually covers the cluster's
  management fee. When the checks pass and the estimate is acceptable, run
  it (about 50 minutes):

  ```sh
  scripts/gke-bench.sh --yes
  ```

  Only the maintainer starts a run with `--yes`, since it costs money. It
  must end with `nothing is left`. If it says what is left instead, or
  was killed, delete what it names (it prints the commands), and check
  `watchdog.log` in the results directory: the watchdog deletes the
  cluster and the repository at the time limit even when the script was
  killed. The billing report shows the actual cost a day or so later.
- [ ] **Compare the GKE run with the previous pre-merge GKE run**:

  ```sh
  python3 bench/compare.py <previous GKE results> bench/results/gke-<date>-<time>
  ```

  Compare GKE runs with GKE runs and local runs with local runs: the
  numbers of the two kinds differ by design (about half the throughput on
  GKE), and the comparison says so when they are mixed.
- [ ] **Post the summary on the pull request or the merge record**: both
  runs' `summary.md` and both comparisons. They name the machine, the
  region, zone and node types, never the account or the project; check
  before posting that nothing does:

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
