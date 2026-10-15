# Base R only. Run after SQL output and tests succeed.
options(stringsAsFactors = FALSE, scipen = 99)
set.seed(271828)
p <- read.csv("reports/tables/policy_fact.csv")
s <- read.csv("reports/tables/group_summary.csv")
claims <- read.csv("data/synthetic/claims.csv")
public <- read.csv("data/public/dfw_county_crashes_2024.csv")
age_levels <- c("18-24", "25-39", "40-64", "65+")
vehicle_levels <- c("Sedan", "SUV", "Pickup")
for (col in c("driver_age_group", "vehicle_type", "vehicle_age_group")) {
  lev <- switch(col, driver_age_group=age_levels, vehicle_type=vehicle_levels,
                vehicle_age_group=c("0-4","5-9","10+"))
  p[[col]] <- factor(p[[col]], levels = lev)
}
p$driver_age_group <- relevel(p$driver_age_group, "40-64")
p$vehicle_age_group <- relevel(p$vehicle_age_group, "5-9")
stopifnot(!anyNA(p), nrow(p)==30000L, all(p$data_status=="SYNTHETIC"),
          all(p$county %in% public$county), all(p$exposure_years > 0),
          sum(p$claim_count)==nrow(claims))

# Policy bootstrap preserves claim clustering and ratio denominators.
# These intervals quantify simulation sampling variation, not uncertainty about real DFW.
metric <- function(d) {
  nc <- sum(d$claim_count); ex <- sum(d$exposure_years); paid <- sum(d$total_paid_usd)
  c(frequency=nc/ex, severity=if(nc>0) paid/nc else NA_real_, annual_cost=paid/ex)
}
ci_rows <- list()
for (dim in c("driver_age", "vehicle_type", "driver_vehicle")) {
  rr <- s[s$dimension==dim,]
  for (g in rr$group_name) {
    selector <- switch(dim,
      driver_age=as.character(p$driver_age_group),
      vehicle_type=as.character(p$vehicle_type),
      driver_vehicle=paste(p$driver_age_group, p$vehicle_type, sep=" / "))
    d <- p[selector==g,]
    b <- replicate(400L, metric(d[sample.int(nrow(d), nrow(d), replace=TRUE),]))
    q <- t(apply(b, 1L, quantile, probs=c(.025,.975), na.rm=TRUE))
    ci_rows[[length(ci_rows)+1L]] <- data.frame(
      dimension=dim, group_name=g, frequency_low=q[1,1], frequency_high=q[1,2],
      severity_low=q[2,1], severity_high=q[2,2], cost_low=q[3,1], cost_high=q[3,2])
  }
}
ci <- do.call(rbind, ci_rows)
write.csv(ci, "reports/tables/bootstrap_intervals.csv", row.names=FALSE)

# Basic analysis is now validated. Model training uses training policy outcomes only.
train <- p[p$split=="train",]; test <- p[p$split=="test",]
freq <- glm(claim_count ~ driver_age_group + vehicle_type + vehicle_age_group +
              offset(log(exposure_years)), family=poisson(link="log"), data=train)
# One row per claim, rather than an unweighted average of policy average severities.
sev_data <- merge(claims, train[c("policy_id","driver_age_group","vehicle_type","vehicle_age_group")],
                  by="policy_id", all=FALSE, sort=FALSE)
sev <- glm(paid_amount_usd ~ driver_age_group + vehicle_type + vehicle_age_group,
           family=Gamma(link="log"), data=sev_data)
stopifnot(freq$converged, sev$converged, length(intersect(train$policy_id,test$policy_id))==0L,
          all(sev_data$policy_id %in% train$policy_id))
test$predicted_claims <- as.numeric(predict(freq,newdata=test,type="response"))
test$predicted_severity <- as.numeric(predict(sev,newdata=test,type="response"))
test$predicted_term_cost <- test$predicted_claims * test$predicted_severity
test$predicted_annual_cost <- test$predicted_term_cost / test$exposure_years
baseline_freq <- sum(train$claim_count)/sum(train$exposure_years)
baseline_sev <- sum(train$total_paid_usd)/sum(train$claim_count)
test$baseline_term_cost <- test$exposure_years * baseline_freq * baseline_sev
test$baseline_claims <- test$exposure_years * baseline_freq
stopifnot(all(is.finite(test$predicted_term_cost)), all(test$predicted_term_cost>0))
poisson_deviance <- function(y,mu) {
  z <- -y+mu; positive <- y>0
  z[positive] <- y[positive]*log(y[positive]/mu[positive])-y[positive]+mu[positive]
  mean(2*z)
}
metrics <- data.frame(
  model=c("Training overall baseline","Poisson frequency x Gamma severity"),
  test_policy_terms=nrow(test), test_policy_years=sum(test$exposure_years),
  observed_claims=sum(test$claim_count),
  predicted_claims=c(sum(test$baseline_claims),sum(test$predicted_claims)),
  mean_poisson_deviance=c(poisson_deviance(test$claim_count,test$baseline_claims),
                          poisson_deviance(test$claim_count,test$predicted_claims)),
  term_cost_MAE=c(mean(abs(test$total_paid_usd-test$baseline_term_cost)),
                  mean(abs(test$total_paid_usd-test$predicted_term_cost))),
  term_cost_RMSE=c(sqrt(mean((test$total_paid_usd-test$baseline_term_cost)^2)),
                   sqrt(mean((test$total_paid_usd-test$predicted_term_cost)^2))),
  observed_annual_cost=sum(test$total_paid_usd)/sum(test$exposure_years),
  predicted_annual_cost=c(sum(test$baseline_term_cost),sum(test$predicted_term_cost))/sum(test$exposure_years)
)
metrics$aggregate_actual_to_expected <- metrics$observed_annual_cost/metrics$predicted_annual_cost
write.csv(metrics,"reports/tables/model_metrics.csv",row.names=FALSE)
write.csv(test,"reports/tables/test_predictions.csv",row.names=FALSE)
phi <- sum(residuals(freq,type="pearson")^2)/df.residual(freq)
coefficients <- function(fit,model) {
  z <- coef(summary(fit)); se <- z[,2]
  data.frame(model=model,term=rownames(z),log_coefficient=z[,1],standard_error=se,
             multiplier=exp(z[,1]),wald_95_low=exp(z[,1]-1.96*se),wald_95_high=exp(z[,1]+1.96*se))
}
write.csv(rbind(coefficients(freq,"Poisson frequency"),coefficients(sev,"Gamma severity")),
          "reports/tables/model_coefficients.csv",row.names=FALSE)
# Rank ties deterministically by policy_id, balanced bins, no response information.
ord <- order(test$predicted_annual_cost, test$policy_id)
test$decile <- integer(nrow(test)); test$decile[ord] <- ceiling(seq_len(nrow(test))*10/nrow(test))
cal <- do.call(rbind,lapply(1:10,function(k) {
  d <- test[test$decile==k,]
  data.frame(decile=k,policy_terms=nrow(d),policy_years=sum(d$exposure_years),claims=sum(d$claim_count),
             observed_annual_cost=sum(d$total_paid_usd)/sum(d$exposure_years),
             predicted_annual_cost=sum(d$predicted_term_cost)/sum(d$exposure_years))
}))
write.csv(cal,"reports/tables/model_calibration.csv",row.names=FALSE)
saveRDS(list(frequency=freq,severity=sev),"work/models.Rds")
session <- gsub(normalizePath(R.home()), "<R_HOME>", capture.output(sessionInfo()), fixed=TRUE)
writeLines(session,"reports/sessionInfo.txt")
writeLines(capture.output({cat("Frequency model\n");print(summary(freq));cat("\nSeverity model\n");print(summary(sev));cat("\nPoisson Pearson dispersion:",phi,"\n")}),"reports/model_summary.txt")

# Four shareable PNG figures, also used in the standalone HTML report.
ink <- "#163044"; teal <- "#087F8C"; orange <- "#C56926"; muted <- "#526776"
open_chart <- function(name) {
  args <- list(filename=paste0("reports/figures/",name,".png"),width=1800,height=1000,res=180)
  if (Sys.info()[["sysname"]]=="Darwin") args$type <- "quartz"
  do.call(png,args)
  par(family="sans",col=ink,col.axis=muted,col.lab=ink,col.main=ink,bg="#FFFFFF",
      cex=1,las=1,mgp=c(3.6,.7,0),tcl=-.25,bty="n")
}
group_plot <- function(dim,levels,metric_name,lo,hi,label) {
  d <- s[s$dimension==dim,]; d <- d[match(levels,d$group_name),]
  b <- ci[ci$dimension==dim,]; b <- b[match(levels,b$group_name),]
  mult <- if(metric_name=="frequency_per_policy_year") 100 else 1
  y <- d[[metric_name]]*mult; low <- b[[lo]]*mult; high <- b[[hi]]*mult
  x <- seq_along(y)
  plot(x,y,type="n",xaxt="n",yaxt="n",xlab="",ylab=label,
       xlim=c(.6,length(x)+.4),ylim=c(0,max(high)*1.20),main=if(dim=="driver_age") "Driver age" else "Vehicle type")
  yt <- pretty(c(0,max(high)*1.2)); abline(h=yt,col="#E6EDF0",lwd=.8)
  axis(2,at=yt,labels=format(yt,big.mark=",",trim=TRUE)); axis(1,at=x,labels=levels,tick=FALSE)
  segments(x,low,x,high,col=teal,lwd=2); segments(x-.07,low,x+.07,low,col=teal)
  segments(x-.07,high,x+.07,high,col=teal); points(x,y,pch=19,col=teal,cex=1.4)
  text(x,high+max(high)*.07,labels=if(mult==100) sprintf("%.1f",y) else paste0("$",format(round(y),big.mark=",",trim=TRUE)),cex=.85,col=ink)
  mtext(paste0("Claims: ",paste(format(d$claims,big.mark=",",trim=TRUE),collapse=" / ")),side=1,line=2.2,cex=.7,col=muted)
}
open_chart("01_claim_frequency")
par(mfrow=c(1,2),mar=c(5,6.3,3,1),oma=c(2,0,3,0))
group_plot("driver_age",age_levels,"frequency_per_policy_year","frequency_low","frequency_high","Claims per 100 policy-years")
group_plot("vehicle_type",vehicle_levels,"frequency_per_policy_year","frequency_low","frequency_high","Claims per 100 policy-years")
mtext("Claim frequency across driver and vehicle groups",outer=TRUE,side=3,line=1,font=2,cex=1.2)
mtext("SYNTHETIC DFW collision policies, 2024. Bars: 95% policy-bootstrap intervals (400 resamples).",outer=TRUE,side=1,line=.3,cex=.75,col=muted)
dev.off()
open_chart("02_average_claim_size")
par(mfrow=c(1,2),mar=c(5,6.3,3,1),oma=c(2,0,3,0))
group_plot("driver_age",age_levels,"average_paid_per_claim_usd","severity_low","severity_high","Average paid claim (USD)")
group_plot("vehicle_type",vehicle_levels,"average_paid_per_claim_usd","severity_low","severity_high","Average paid claim (USD)")
mtext("Average claim size across driver and vehicle groups",outer=TRUE,side=3,line=1,font=2,cex=1.2)
mtext("SYNTHETIC positive paid collision claims, 2024. Bars: 95% policy-bootstrap intervals (400 resamples).",outer=TRUE,side=1,line=.3,cex=.75,col=muted)
dev.off()
open_chart("03_annual_expected_cost")
par(mar=c(5.3,6.3,4.5,1),oma=c(1.5,0,0,0))
d <- s[s$dimension=="driver_vehicle",]
z <- outer(age_levels,vehicle_levels,Vectorize(function(a,v) d$annual_expected_cost_usd[d$group_name==paste(a,v,sep=" / ")]))
plot(NA,xlim=c(.5,3.5),ylim=c(.5,4.5),xaxt="n",yaxt="n",xlab="Vehicle type",ylab="Driver age",main="Annual expected claim cost per full-year policy")
palette <- colorRampPalette(c("#E3F2F1","#75BFBB","#087F8C"))(100)
for(i in 1:4) for(j in 1:3) {
  yy <- 5-i; zz <- z[i,j]
  col <- palette[1+round(99*(zz-min(z))/(max(z)-min(z)))]
  rect(j-.48,yy-.48,j+.48,yy+.48,col=col,border="white")
  row <- d[d$group_name==paste(age_levels[i],vehicle_levels[j],sep=" / "),]
  fg <- if(zz>min(z)+.6*diff(range(z))) "white" else ink
  text(j,yy+.1,paste0("$",format(round(zz),big.mark=",")),cex=1.25,font=2,col=fg)
  text(j,yy-.15,paste0(row$claims," claims"),cex=.75,col=fg)
}
axis(1,at=1:3,labels=vehicle_levels,tick=FALSE);axis(2,at=4:1,labels=age_levels,tick=FALSE)
mtext("SYNTHETIC 2024 data. Frequency x average claim size = paid losses / policy-years. Unadjusted group means.",side=1,outer=TRUE,line=.1,cex=.75,col=muted)
dev.off()
open_chart("04_model_calibration")
par(mar=c(5.3,6.3,4,1),oma=c(1.5,0,0,0))
yr <- range(c(0,cal$observed_annual_cost,cal$predicted_annual_cost))*c(1,1.15)
plot(cal$decile,cal$observed_annual_cost,type="n",ylim=yr,xaxt="n",yaxt="n",
     xlab="Test policies ranked by predicted annual cost (low to high)",ylab="Claim cost per policy-year (USD)",
     main="Regression calibration on held-out policies")
yt <- pretty(yr);abline(h=yt,col="#E6EDF0");axis(2,at=yt,labels=format(yt,big.mark=",",trim=TRUE));axis(1,at=1:10)
lines(cal$decile,cal$predicted_annual_cost,col=teal,lwd=2.5,type="b",pch=19)
lines(cal$decile,cal$observed_annual_cost,col=orange,lwd=2.5,type="b",pch=17)
legend("topleft",c("Predicted: frequency x severity","Observed"),col=c(teal,orange),pch=c(19,17),lwd=2,bty="n",cex=.85)
mtext("SYNTHETIC random 25% holdout. Ten equally sized policy bins; values use exposure-weighted totals.",side=1,outer=TRUE,line=.1,cex=.75,col=muted)
dev.off()

# Concise, executable analysis report, with every insurance finding labeled synthetic.
money <- function(x) paste0("$",format(round(x),big.mark=",",trim=TRUE))
num <- function(x,digits=0) format(round(x,digits),big.mark=",",trim=TRUE,nsmall=digits)
tab <- function(d,headers=names(d)) {
  c(paste0("| ",paste(headers,collapse=" | ")," |"),paste0("| ",paste(rep("---",ncol(d)),collapse=" | ")," |"),
    apply(d,1,function(r) paste0("| ",paste(r,collapse=" | ")," |")))
}
out <- character(); add <- function(...) out <<- c(out,...,"")
o <- s[s$dimension=="overall",]
add("# DFW auto claims: frequency, severity, and expected cost",
    "**All policy, claim, and regression results below are SYNTHETIC educational examples.** Actual public data is restricted to the DFW county crash table. No real insurer data was supplied.")
add("## 1. Local public data and scope",
    "DFW is defined as NCTCOG's 12-county Metropolitan Planning Area: Collin, Dallas, Denton, Ellis, Hood, Hunt, Johnson, Kaufman, Parker, Rockwall, Tarrant, and Wise. This differs from other metro-area definitions.",
    paste0("The retained TxDOT 2024 extract contains **",num(sum(public$total_crashes))," reported crashes**. The source was processed as of April 9, 2025. Every retained public observation is within these 12 counties."))
add(tab(data.frame(County=public$county,Reported_crashes=num(public$total_crashes),Fatal_crashes=num(public$fatal_crashes))))
add("Source: [TxDOT 2024 county crash table](https://www.txdot.gov/content/dam/docs/division/trf/crash-records/2024/13.pdf). Scope: [NCTCOG Mobility 2050 introduction](https://www.nctcog.org/getmedia/650c132b-7fd9-478a-bafd-2d995ccc0c8c/1-0-Introduction.pdf).",
    "Crash counts supply county sampling weights for the demonstration. They do not calibrate insurance frequency, severity, or exposure. Raw count differences reflect traffic volume and reporting as well as risk. No outside-region insurance sample is used.")
add("## 2. Definitions and SQL analysis",
    "One policy term covers one vehicle and one rated driver in the simulation. A policy may have multiple positive paid collision claims. Earned exposure ranges from 0.25 to 1 policy-year. All claims are assumed fully settled at the same valuation basis.",
    "- Claim frequency = number of positive paid claims / earned policy-years.",
    "- Average claim size (severity) = total paid claim amount / number of positive paid claims.",
    "- Estimated annual expected cost per full-year policy (pure premium) = frequency x severity = total paid / policy-years.",
    "- Observed average cost per policy term = total paid / number of policy terms. This reflects the actual mix of term lengths.",
    "Frequency is a count rate, not the probability of at least one claim. Claims with no payment are absent by design. SQL aggregates claims first and left-joins to policies so zero-claim policies remain in the denominator. Every group uses ratios of totals.")
add(paste0("The synthetic book contains **",num(o$policy_terms)," policy terms**, **",num(o$policy_years,2)," policy-years**, and **",num(o$claims)," paid claims**. Total simulated losses are **",money(o$total_paid_usd),"**."),
    paste0("Overall: **",num(100*o$frequency_per_policy_year,2)," claims per 100 policy-years**, **",money(o$average_paid_per_claim_usd)," per paid claim**, and **",money(o$annual_expected_cost_usd)," expected annual claim cost**. Cost per observed policy term is **",money(o$observed_term_cost_usd),"**. These are simulated results, not DFW market estimates."))
for(dim in c("driver_age","vehicle_type","vehicle_age")) {
  d <- s[s$dimension==dim,]
  if(dim=="driver_age") d<-d[match(age_levels,d$group_name),]
  if(dim=="vehicle_type") d<-d[match(vehicle_levels,d$group_name),]
  if(dim=="vehicle_age") d<-d[match(c("0-4","5-9","10+"),d$group_name),]
  add(paste0("### ",switch(dim,driver_age="Driver groups",vehicle_type="Vehicle types",vehicle_age="Vehicle age groups")," (synthetic)"),
      tab(data.frame(Group=d$group_name,Policy_years=num(d$policy_years,1),Claims=num(d$claims),
         Frequency=num(100*d$frequency_per_policy_year,2),Severity=money(d$average_paid_per_claim_usd),Annual_cost=money(d$annual_expected_cost_usd)),
          c("Group","Policy-years","Claims","Claims / 100 policy-years","Average paid claim","Annual expected cost")))
}
young <- s[s$dimension=="driver_age" & s$group_name=="18-24",]
middle <- s[s$dimension=="driver_age" & s$group_name=="40-64",]
pickup <- s[s$dimension=="vehicle_type" & s$group_name=="Pickup",]
sedan <- s[s$dimension=="vehicle_type" & s$group_name=="Sedan",]
add(paste0("In the synthetic book, drivers aged 18-24 have ",num(young$frequency_per_policy_year/middle$frequency_per_policy_year,2),
    " times the claim frequency of ages 40-64. Pickups have ",num(pickup$average_paid_per_claim_usd/sedan$average_paid_per_claim_usd,2),
    " times sedan severity. These patterns largely reflect the assumptions coded in the simulator; they are not discoveries about DFW drivers."))
add("![Synthetic claim frequency across groups](figures/01_claim_frequency.png)",
    "![Synthetic average claim size across groups](figures/02_average_claim_size.png)",
    "![Synthetic expected annual cost by driver and vehicle](figures/03_annual_expected_cost.png)",
    "The frequency and severity figures include 95% percentile intervals from 400 policy-level bootstrap resamples. Resampling policies retains multiple claims together. Cross-group intervals are descriptive and have no multiple-comparison adjustment. Complete interval values, including annual-cost intervals, are in reports/tables/bootstrap_intervals.csv.")
add("## 3. Regression added after the basic analysis",
    "The runner executes the SQL summaries and denominator/join tests before running this model. An exact 75%/25% random policy split keeps all claims from a policy together. Model fitting uses only training outcomes; no model is selected or tuned on test outcomes. Full-book descriptive tables include both partitions.",
    "The simple two-part model uses driver age group, vehicle type, and vehicle age group:",
    "```text",
    "Claim count ~ Poisson(exposure_years x exp(X beta))",
    "log(E[claim_count]) = X beta + log(exposure_years)",
    "Paid claim amount | positive paid claim ~ Gamma(mean = exp(X gamma), log link)",
    "Expected term cost = predicted claim count x predicted mean claim amount",
    "Expected annual cost = expected term cost / exposure_years",
    "```",
    "The exposure offset fixes proportionality to time insured. Severity is fitted at individual-claim level. Model assumptions include stable paid-claim definitions, conditionally Poisson counts, positive Gamma costs, multiplicative group effects, and no residual frequency/severity dependence after conditioning. No county effect is imposed or estimated from public crash counts.",
    "Reference categories: driver 40-64, Sedan, vehicle age 5-9. Exponentiated coefficients are conditional multiplicative factors; the intercept is the corresponding baseline rate or average cost. Coefficients and approximate model-based Wald intervals are exported. Their intervals do not account for real-world misspecification or clustering beyond the simulation assumptions.")
add(paste0("Training has ",num(nrow(train))," policies and ",num(nrow(sev_data))," claims. Testing has ",num(nrow(test))," policies. Training Poisson Pearson dispersion is ",num(phi,3),"; values well above 1 would motivate a negative-binomial or quasi-Poisson assessment with real data."))
add(tab(data.frame(Model=metrics$model,Poisson_deviance=num(metrics$mean_poisson_deviance,4),
                  MAE=money(metrics$term_cost_MAE),RMSE=money(metrics$term_cost_RMSE),
                  Predicted_annual=money(metrics$predicted_annual_cost),AE=num(metrics$aggregate_actual_to_expected,3)),
        c("Model","Mean count deviance","Term cost MAE","Term cost RMSE","Predicted annual cost","Actual / expected")))
add(paste0("Held-out observed annual cost is **",money(metrics$observed_annual_cost[1]),"**. Compare both models against that same outcome. Count deviance evaluates frequency; MAE and RMSE evaluate realized term costs, including zeros. Calibration compares aggregate observed and predicted losses using the same exposure denominator. Lower deviance, MAE, and RMSE are preferable, but an individual metric can favor the baseline because most policy outcomes are zero."),
    paste0("Relative to the baseline, the regression reduces mean count deviance by ",num(100*(1-metrics$mean_poisson_deviance[2]/metrics$mean_poisson_deviance[1]),2),
    "% and term-cost RMSE by ",num(100*(1-metrics$term_cost_RMSE[2]/metrics$term_cost_RMSE[1]),2),
    "%. This is a small improvement in one synthetic holdout; no statistical significance or real-world predictive improvement is established."),
    "![Synthetic held-out model calibration](figures/04_model_calibration.png)",
    "The deciles are formed from predicted annual cost only. Ties are broken by policy ID, so adjacent bins can share the same predicted risk. Lines show aggregate rates, not individual prediction accuracy. The random holdout tests recovery of a known simulator and does not establish performance on future DFW insurance claims.")
add("## 4. Limitations",
    "1. Insurance data is synthetic. Driver/vehicle mixes, exposure, count rates, severity levels, and group effects are teaching assumptions. Geographic labels do not turn simulated losses into observed DFW evidence.",
    "2. Public crashes lack earned insured exposure, paid losses, coverage, policy limits, and deductibles. A crash can create zero, one, or multiple insurance claims; hail, theft, and other non-crash losses are outside this collision-only example. Crash location also differs from the county where a policy is garaged.",
    "3. The extract includes every county in the chosen DFW boundary for one source/year. It does not include every local dataset or every crash, and it is not the latest available reporting year. Police-reported crashes are subject to reporting and processing rules.",
    "4. The synthetic county mix follows crash-count shares, not population, registered vehicles, insured policies, or miles driven. Driver age and vehicle type are sampled independently; no realistic joint DFW distribution is claimed.",
    "5. Fully settled positive paid collision claims are assumed. Real paid data is affected by open claims, development, recoveries, zero-paid claims, policy changes, large losses, inflation, and limits/deductibles. No loss-development or inflation adjustment is possible here.",
    "6. Unadjusted group comparisons are associations affected by group mix. Annualization assumes claims scale with earned time. It does not account for miles, seasonality, commuting, driver history, or selection effects.",
    "7. The Gamma simulation has a much simpler tail than real catastrophic or mixed-coverage losses. Poisson counts omit shared weather events, heterogeneity, and dependence. Bootstrap intervals and coefficient intervals quantify assumptions within this toy book, not actual DFW uncertainty.",
    "8. The regression omits interactions and many possible predictors. The random test split is not a time-based validation. Good recovery of simulated effects is expected and cannot justify real insurance pricing. Pure premium excludes expenses, profit, taxes, reinsurance, and risk margins.")
add("## 5. Replacing the demo with real DFW data",
    "Use de-identified policy-term and claim tables with a stable join key, DFW garaging county, earned exposure, dates, driver/vehicle attributes, coverage, deductibles/limits, and consistent paid or ultimate loss valuation. Include zero-claim policies and explicitly choose whether zero-paid claims count toward frequency. Validate development and inflation treatment, cluster renewals by policy/household, and reserve a later period for testing. Update the schema's SYNTHETIC-only constraints and labels intentionally before running real records; do not publish private insurer data to this repository.")
# Separate paragraphs and headings while preserving Markdown tables, lists, and code.
clean <- character(); in_code <- FALSE
for (line in out) {
  prev <- if(length(clean)) tail(clean,1) else ""
  list_line <- function(x) grepl("^(- |[0-9]+\\. )",x)
  same_table <- startsWith(line,"|") && startsWith(prev,"|")
  same_list <- list_line(line) && list_line(prev)
  if(nzchar(line) && nzchar(prev) && !in_code && !same_table && !same_list) clean<-c(clean,"")
  clean <- c(clean,line)
  if(startsWith(line,"```")) in_code <- !in_code
}
writeLines(clean,"reports/analysis.md")
cat("Four charts, bootstrap intervals, regression diagnostics, and report created.\n")
