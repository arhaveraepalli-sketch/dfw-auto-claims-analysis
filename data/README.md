# Data dictionary and provenance

Every retained public observation and every synthetic geographic label is within the NCTCOG 12-county DFW planning area. No statewide insurance statistics or non-DFW insurance dataset is used.

## Observed public data

`public/dfw_county_crashes_2024.csv`: one county row, 2024 police-reported motor vehicle crashes. Columns retain the [TxDOT source table's](https://www.txdot.gov/content/dam/docs/division/trf/crash-records/2024/13.pdf) counts for fatal, suspected serious, suspected minor, possible injury, non-injury, and unknown severity crashes; corresponding person counts; total crashes; and original 1-based PDF page. Crash severity is not dollar severity. Fatalities and injuries count people; crashes count events. The six crash-severity categories sum to total crashes. Only 12 DFW rows are stored.

`public/source_manifest.json` records the source URL, SHA-256 of the downloaded original, dates, boundary, and county list. The original statewide PDF is not redistributed. `scripts/refresh_public.py` optionally downloads and extracts the source, requiring pdfplumber. Refreshing can change a revised source snapshot, so inspect the manifest and rerun the full pipeline afterward.

The source is attributed to the Texas Department of Transportation; no endorsement is implied. Consult [TxDOT's disclaimer](https://www.txdot.gov/about/disclaimer.html) and source terms for reuse. The code's MIT license does not relicense third-party data.

## Synthetic policy terms

`synthetic/policies.csv`: 30,000 rows, one rated driver and vehicle per policy term, calendar 2024.

| Field | Meaning |
| --- | --- |
| policy_id | Invented unique ID beginning SYN |
| year | 2024 scenario year |
| county | DFW garaging label sampled using public county crash-count shares |
| driver_age_group | 18-24, 25-39, 40-64, 65+ |
| vehicle_type | Sedan, SUV, Pickup |
| vehicle_age_group | 0-4, 5-9, 10+ years |
| exposure_years | Earned exposure: 0.25, 0.5, 0.75, 1 |
| coverage | Collision only, assumed comparable contracts |
| data_status | Always SYNTHETIC |
| split | Exactly 22,500 training policies and 7,500 test policies |

## Synthetic claims

`synthetic/claims.csv`: one positive paid claim per row. `claim_id` begins SYNCL; `policy_id` references policies; `paid_amount_usd` is simulated settled payment in nominal scenario USD, rounded to cents; `data_status` is SYNTHETIC. A policy can have multiple claims. No-payment claims and open claims do not exist in this demonstration. Payments are simulated directly; deductible and limit mechanics are not modeled, and no claim-level dates are manufactured.

## Author-chosen simulation assumptions

Fixed seed: 20261015. Age shares: 12%, 31%, 43%, 14%. Vehicle shares: Sedan 40%, SUV 40%, Pickup 20%. Vehicle-age shares: 35%, 35%, 30%. Exposure probabilities: 8%, 12%, 10%, 70%. These variables are sampled independently. Public county weights do not affect frequency or severity.

Expected annual frequency = 0.07 x driver-age factor x vehicle-type factor x vehicle-age factor. Claim count is Poisson(exposure x expected annual frequency).

| Factor | Age 18-24 | Age 25-39 | Age 40-64 | Age 65+ |
| --- | --- | --- | --- | --- |
| Frequency | 1.80 | 1.15 | 1.00 | 1.20 |
| Severity | 1.12 | 1.02 | 1.00 | 1.05 |

| Factor | Sedan | SUV | Pickup |
| --- | --- | --- | --- |
| Frequency | 1.00 | 0.92 | 1.08 |
| Severity | 1.00 | 1.25 | 1.40 |

| Factor | Vehicle 0-4 | Vehicle 5-9 | Vehicle 10+ |
| --- | --- | --- | --- |
| Frequency | 1.00 | 1.05 | 1.12 |
| Severity | 1.25 | 1.00 | 0.78 |

Expected claim amount = USD 6,000 x the three severity factors. Payments follow a Gamma distribution with shape 1.5 and scale equal to expected claim amount / 1.5. Frequency and payment randomness are independent conditional on predictors. There are no shared weather shocks. These are teaching assumptions, not values estimated from DFW claims. The fitted model intentionally resembles the generating process, making validation substantially easier than real insurance modeling.

## Generated results

`reports/tables/group_summary.csv` includes policy counts, earned exposure, claims, policies with a claim, paid loss, claim frequency, severity, annualized cost, actual-term cost, and actual-term probability of at least one paid claim. `policy_fact.csv` retains one policy row after the claim aggregation. `bootstrap_intervals.csv` contains policy-bootstrap 95% intervals (400 draws) for driver age, vehicle type, and their joint groups. `model_metrics.csv`, `model_coefficients.csv`, `model_calibration.csv`, and `test_predictions.csv` document the model outputs. All insurance-related tables are synthetic, even when their filenames omit the word.

