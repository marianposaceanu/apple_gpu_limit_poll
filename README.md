# Apple GPU Wired Limit Poll

This repository contains Ruby scripts to test and interpret `iogpu.wired_limit_mb` behavior on Apple Silicon macOS machines.

`iogpu.wired_limit_mb` changes the ceiling for memory that the GPU may wire. It does **not** reserve that memory or create GPU load. A useful sweep therefore has to launch the same real Metal workload once per tested value.

## What is included

- `gpu_limit_report_local.rb`: Runs a local sweep, launches a workload once per limit, samples memory pressure, and writes reports.
- `poc/interpret_gpu_limit_report.rb`: Re-ranks and explains an existing JSON, summary CSV, or raw samples CSV report.
- `test_gpu_limit_report.rb`: Tests metric parsing, per-window analysis, and safe recommendation behavior.

## Requirements

- macOS with `sysctl`, `vm_stat`, and `memory_pressure`
- Ruby 3.x
- `sudo` access (required to change `iogpu.wired_limit_mb`)
- A repeatable Metal workload that starts a fresh GPU process for every limit

## Establish the default baseline

A sysctl value of `0` means “use the macOS default policy,” not zero GPU memory. Query Metal's corresponding recommended working set with Swift:

```bash
swift -e 'import Metal; if let d = MTLCreateSystemDefaultDevice() { print(Double(d.recommendedMaxWorkingSetSize) / 1048576, "MB") }'
```

Always include `0` in a sweep so an override is compared with the system default. Choose explicit values for the machine being tested and leave deliberate memory headroom for macOS.

## Run a local sweep

```bash
ruby gpu_limit_report_local.rb \
  --limits-mb 0,12288,13312 \
  --duration 120 \
  --interval 1 \
  --warmup 8 \
  --workload-command '/path/to/llama-cli -m /path/to/model.gguf -p "benchmark prompt" -n 512' \
  --report-prefix 16gb-test
```

The example limits are illustrative for a 16 GiB machine, not universal recommendations. The workload must approach the GPU memory footprint you actually intend to run; a tiny Metal task cannot validate a large, unexercised ceiling. It is launched after a pre-workload baseline sample and receives the tested value in `GPU_WIRED_LIMIT_MB`. A workload still running at the end of `--duration` is terminated; one that exits on its own must return status 0 to qualify that limit for recommendation.

`--hog-gb` remains available to simulate additional ordinary application memory, but it is not a GPU workload and cannot validate the GPU ceiling by itself.

The script writes timestamped outputs to the current directory (or `--output-dir`):

- `*-samples.csv`
- `*-summary.csv`
- `*.json`
- `*.md`

## Interpret an existing report

```bash
ruby poc/interpret_gpu_limit_report.rb --input 16gb-test-YYYYMMDD-HHMMSS.json
```

You can also pass a `*-summary.csv` or `*-samples.csv` file. Raw samples are grouped into one row per tested limit; they are never treated as precomputed summaries. Samples CSV interpretation is diagnostic-only because that format does not carry workload completion status; use JSON or summary CSV when re-evaluating a recommendation.

## How recommendations work

The analyzer compares each window with its pre-workload baseline. It looks for:

- no increase in the cumulative swapout counter;
- less than 64 MB growth in swap usage;
- less than 256 MB peak growth in compressed memory;
- at least 20% system-available memory throughout the window;
- a workload that completed successfully or ran until the configured duration.

Only the highest tested value meeting every condition is recommended. If metrics are unavailable, the workload fails, or every value shows pressure, the scripts deliberately produce no recommendation rather than labeling the least-bad value as safe. These thresholds are heuristics; benchmark responsiveness and workload performance as well.

## Existing proof-of-concept report

The checked-in `poc/16gb-test-20260318-232414.*` files predate workload orchestration and the corrected metrics. That run used a 6 GiB Ruby RAM allocation but no Metal workload. It also tested 5,632–8,192 MB, below the roughly 12,124 MB default Metal working set observed on the 16 GiB M1 Pro. It is useful as parser fixture data, but it cannot support a GPU-limit recommendation.

## Notes

- The sweep script verifies every sysctl write and restores the original value by default (`--[no-]restore`).
- Partial reports are written after interruption, sampling failure, or workload failure whenever samples are available.
- The raw CSV stores parsed pressure metrics rather than repeating the full multi-line `memory_pressure` output in every row.
- Run the tests with `ruby test_gpu_limit_report.rb`.
