# Interpreted GPU wired limit report

Source: `16gb-test-20260318-232414-summary.csv`

## Recommendation

Recommended default: **5632 MB**  
Reason: best score among tested values  
Assessment: swap-heavy, compression-heavy, low-free-memory, pageouts-rising  
Stability score: 5.0

## Limits ranked

| limit_mb | score | assessment | swap_max_mb | compressed_max_mb | free_min_mb | pageouts_delta |
|---:|---:|---|---:|---:|---:|---:|
| 5632 | 5.0 | swap-heavy, compression-heavy, low-free-memory, pageouts-rising | 3421.7 | 6636.0 | 58.2 | 287 |
| 6144 | 5.0 | swap-heavy, compression-heavy, low-free-memory, pageouts-rising | 3421.7 | 5043.5 | 61.0 | 374 |
| 7168 | 5.0 | swap-heavy, compression-heavy, low-free-memory, pageouts-rising | 3421.7 | 4888.0 | 58.3 | 290 |
| 8192 | 5.0 | swap-heavy, compression-heavy, low-free-memory, pageouts-rising | 3421.7 | 5046.9 | 58.7 | 428 |

## Reading the result

Use the highest value that stays boring: low swap, moderate compression, no pageout growth, and enough free memory that the machine still feels responsive. For your workload, this is more useful than maximizing GPU headroom.
