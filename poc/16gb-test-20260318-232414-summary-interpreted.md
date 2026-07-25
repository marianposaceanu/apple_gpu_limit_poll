# Interpreted GPU wired limit report

Source: `16gb-test-20260318-232414-summary.csv`

## Recommendation

No recommendation produced. The report must contain complete pressure metrics from a successful repeatable GPU workload.

## Limits ranked

| limit_mb | score | assessment | swap_growth_mb | compression_growth_mb | available_min_pct | swapouts_delta | workload |
|---:|---:|---|---:|---:|---:|---:|---|
| 5632 | 75.0 | compression-growing, metrics-incomplete | 0.0 | 1988.9 | n/a | n/a | not-recorded |
| 6144 | 77.3 | compression-growing, metrics-incomplete | 0.0 | 362.5 | n/a | n/a | not-recorded |
| 7168 | 83.3 | compression-growing, metrics-incomplete | 0.0 | 266.5 | n/a | n/a | not-recorded |
| 8192 | 76.9 | compression-growing, metrics-incomplete | 0.0 | 369.0 | n/a | n/a | not-recorded |

## Reading the result

Use the highest value that stays boring: no new swapouts, modest compression growth, and healthy available memory while completing the same Metal workload. `iogpu.wired_limit_mb` only moves a GPU working-set ceiling; changing it does not allocate memory or create load.
