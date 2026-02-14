# Benchmark Harness (Assessment-Driven)

This benchmark system optimizes prompt variants using internal delegation-assessment signals, not answer-key scoring.

## Layout

- `bench/manifests/`: pull-down source manifests.
- `bench/profiles/`: build/run/AB defaults.
- `bench/templates/`: task query wrappers and family instructions.
- `bench/variants/`: tracked prompt variants (baseline champion).
- `bench_data/` (gitignored): pulled corpora, generated contexts/tasks, run logs, AB reports.

## Typical workflow

1. Pull source corpus:

```bash
mix rlm.bench.pull
```

2. Build benchmark task pool:

```bash
mix rlm.bench.build --profile bench/profiles/optimize_v1.json
```

Easy mode (faster, easier tasks, still delegation-required):

```bash
mix rlm.bench.build \
  --profile bench/profiles/easy_v1.json \
  --output bench_data/tasks/pool_easy_v1.jsonl
```

3. Run benchmark batch in quiet mode (recommended):

```bash
mix rlm.bench.run \
  --tasks bench_data/tasks/pool_v1.jsonl \
  --variant bench/variants/champion_v1.md \
  --limit 12 \
  --quiet
```

Easy-mode smoke run:

```bash
mix rlm.bench.run \
  --tasks bench_data/tasks/pool_easy_v1.jsonl \
  --variant bench/variants/champion_v1.md \
  --limit 8 \
  --quiet
```

Live streaming without context pollution:

```bash
mix rlm.bench.run \
  --tasks bench_data/tasks/pool_easy_v1.jsonl \
  --variant bench/variants/champion_v1.md \
  --limit 8 \
  --stream-logs \
  > /tmp/rlm_bench_stream.log 2>&1

tail -n 120 -f /tmp/rlm_bench_stream.log
```

4. Compare two runs:

```bash
mix rlm.bench.ab --run-a <run_id_a> --run-b <run_id_b>
```

5. Autonomous prompt optimization:

```bash
mix rlm.bench.optimize \
  --tasks bench_data/tasks/pool_v1.jsonl \
  --base-variant bench/variants/champion_v1.md \
  --cycles 10
```

## Quiet-mode logs

Quiet runs suppress per-task subprocess output in terminal and store it at:

- `bench_data/runs/<run_id>/task_logs/<task_id>.log`
- `bench_data/runs/<run_id>/task_logs/<task_id>.meta.json`

Benchmark runs export full debug event logs by default (`--export-debug`) so investigation can use complete event history.

Use:

```bash
mix rlm.bench.logs --run-id <run_id> --task <task_id> --tail 120
```

`mix rlm.bench.optimize` automatically inspects failing/weak cycles and writes:

- `bench_data/runs/<run_id>/inspection.json`
- `bench_data/optimize/<session_id>/cycles/cycle_<n>.json`

Use `--no-inspect-logs` to disable automatic log inspection.

to inspect without polluting interactive context.

For long optimization sessions, stream to a temp log and tail it in small chunks:

```bash
mix rlm.bench.optimize \
  --tasks bench_data/tasks/pool_v1.jsonl \
  --base-variant bench/variants/champion_v1.md \
  --cycles 10 \
  --stream-logs \
  > /tmp/rlm_bench_optimize_stream.log 2>&1

tail -n 120 -f /tmp/rlm_bench_optimize_stream.log
```
