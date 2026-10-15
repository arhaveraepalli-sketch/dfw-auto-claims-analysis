# Educational synthetic collision book. No row is an actual insured or claim.
# Public DFW counts set county sample weights only, never insurance risk rates.
set.seed(20261015)
dir.create("data/synthetic", recursive = TRUE, showWarnings = FALSE)
public <- read.csv("data/public/dfw_county_crashes_2024.csv")
n <- 30000L
age_levels <- c("18-24", "25-39", "40-64", "65+")
vehicle_levels <- c("Sedan", "SUV", "Pickup")
vehicle_age_levels <- c("0-4", "5-9", "10+")
p <- data.frame(
  policy_id = sprintf("SYN%06d", seq_len(n)),
  year = 2024L,
  county = sample(public$county, n, replace = TRUE, prob = public$total_crashes),
  driver_age_group = sample(age_levels, n, replace = TRUE, prob = c(.12,.31,.43,.14)),
  vehicle_type = sample(vehicle_levels, n, replace = TRUE, prob = c(.40,.40,.20)),
  vehicle_age_group = sample(vehicle_age_levels, n, replace = TRUE, prob = c(.35,.35,.30)),
  exposure_years = sample(c(.25,.5,.75,1), n, replace = TRUE, prob = c(.08,.12,.10,.70)),
  coverage = "collision", data_status = "SYNTHETIC",
  split = "train", stringsAsFactors = FALSE
)
# Exact 75/25 policy split. A claim inherits its policy's split.
p$split[sample.int(n, n/4)] <- "test"
# Arbitrary teaching assumptions, uncalibrated to DFW insurance experience.
freq_age <- c("18-24"=1.8, "25-39"=1.15, "40-64"=1, "65+"=1.2)
freq_type <- c(Sedan=1, SUV=.92, Pickup=1.08)
freq_vage <- c("0-4"=1, "5-9"=1.05, "10+"=1.12)
sev_age <- c("18-24"=1.12, "25-39"=1.02, "40-64"=1, "65+"=1.05)
sev_type <- c(Sedan=1, SUV=1.25, Pickup=1.4)
sev_vage <- c("0-4"=1.25, "5-9"=1, "10+"=.78)
lambda <- .07 * freq_age[p$driver_age_group] * freq_type[p$vehicle_type] * freq_vage[p$vehicle_age_group]
count <- rpois(n, p$exposure_years * lambda)
idx <- rep(seq_len(n), count)
mean_paid <- 6000 * sev_age[p$driver_age_group[idx]] * sev_type[p$vehicle_type[idx]] * sev_vage[p$vehicle_age_group[idx]]
claims <- data.frame(
  claim_id = sprintf("SYNCL%06d", seq_along(idx)), policy_id = p$policy_id[idx],
  paid_amount_usd = round(rgamma(length(idx), shape = 1.5, scale = mean_paid / 1.5), 2),
  data_status = "SYNTHETIC"
)
stopifnot(all(claims$paid_amount_usd > 0))
write.csv(p, "data/synthetic/policies.csv", row.names = FALSE)
write.csv(claims, "data/synthetic/claims.csv", row.names = FALSE)
cat("Generated", nrow(p), "SYNTHETIC policy terms and", nrow(claims), "SYNTHETIC positive paid claims.\n")

