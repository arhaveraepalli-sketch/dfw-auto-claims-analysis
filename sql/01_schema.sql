PRAGMA foreign_keys = ON;
CREATE TABLE policies (
    policy_id TEXT PRIMARY KEY,
    year INTEGER NOT NULL CHECK(year = 2024),
    county TEXT NOT NULL REFERENCES dfw_counties(county),
    driver_age_group TEXT NOT NULL CHECK(driver_age_group IN ('18-24','25-39','40-64','65+')),
    vehicle_type TEXT NOT NULL CHECK(vehicle_type IN ('Sedan','SUV','Pickup')),
    vehicle_age_group TEXT NOT NULL CHECK(vehicle_age_group IN ('0-4','5-9','10+')),
    exposure_years REAL NOT NULL CHECK(exposure_years > 0 AND exposure_years <= 1),
    coverage TEXT NOT NULL CHECK(coverage = 'collision'),
    data_status TEXT NOT NULL CHECK(data_status = 'SYNTHETIC'),
    split TEXT NOT NULL CHECK(split IN ('train','test'))
);
CREATE TABLE dfw_counties (county TEXT PRIMARY KEY);
CREATE TABLE claims (
    claim_id TEXT PRIMARY KEY,
    policy_id TEXT NOT NULL REFERENCES policies(policy_id),
    paid_amount_usd REAL NOT NULL CHECK(paid_amount_usd > 0),
    data_status TEXT NOT NULL CHECK(data_status = 'SYNTHETIC')
);

