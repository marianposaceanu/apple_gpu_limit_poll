# Apple GPU Wired Limit Poll

This repository contains Ruby scripts to test and interpret `iogpu.wired_limit_mb` behavior on Apple Silicon macOS machines.

## What is included

- `gpu_limit_report_local.rb`: Runs a local sweep over multiple wired-limit values, samples memory metrics, and writes reports.
- `interpret_gpu_limit_report.rb`: Re-ranks and explains an existing JSON or summary CSV report.

## Requirements

- macOS with `sysctl`, `vm_stat`, and `memory_pressure`
- Ruby 3.x
- `sudo` access (required to change `iogpu.wired_limit_mb`)

## Run a local sweep

```bash
ruby gpu_limit_report_local.rb \
  --limits-mb 5632,6144,7168,8192 \
  --hog-gb 6 \
  --duration 120 \
  --interval 1 \
  --warmup 8 \
  --report-prefix 16gb-test
```

The script writes timestamped outputs to the current directory (or `--output-dir`):

- `*-samples.csv`
- `*-summary.csv`
- `*.json`
- `*.md`

## Interpret an existing report

```bash
ruby interpret_gpu_limit_report.rb --input 16gb-test-YYYYMMDD-HHMMSS.json
```

You can also pass a `*-summary.csv` file.

## Notes

- The sweep script restores the original `iogpu.wired_limit_mb` value by default (`--[no-]restore`).
- Recommendations are heuristic. Validate the chosen value using your real workload.
