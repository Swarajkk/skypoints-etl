USE ROLE ACCOUNTADMIN;
USE WAREHOUSE skypoints_wh;
USE DATABASE skypoints;

-- =========================
-- RAW: landing tables (all VARCHAR so a bad value never fails the load)
-- =========================
CREATE TABLE IF NOT EXISTS skypoints.raw.member_feed_raw (
  record_type       VARCHAR(1),
  member_name       VARCHAR,
  member_id         VARCHAR,
  enrollment_date   VARCHAR,
  last_flight_date  VARCHAR,
  tier_code         VARCHAR,
  agent_name        VARCHAR,
  state             VARCHAR,
  country           VARCHAR,
  post_code         VARCHAR,
  dob               VARCHAR,
  is_active         VARCHAR,
  _source_file      VARCHAR,
  _file_row_number  NUMBER,
  _feed_date        DATE,
  _loaded_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) CLUSTER BY (_feed_date);

CREATE TABLE IF NOT EXISTS skypoints.raw.redemption_feed_raw (
  payload       VARIANT,
  _source_file  VARCHAR,
  _loaded_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Stages and file format
CREATE STAGE IF NOT EXISTS skypoints.raw.member_stage
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') DIRECTORY = (ENABLE = TRUE);
CREATE STAGE IF NOT EXISTS skypoints.raw.redemption_stage
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') DIRECTORY = (ENABLE = TRUE);

CREATE FILE FORMAT IF NOT EXISTS skypoints.raw.ff_member_pipe
  TYPE = CSV
  FIELD_DELIMITER = '|'
  TRIM_SPACE = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

-- =========================
-- REF: reference / config data
-- =========================
CREATE TABLE IF NOT EXISTS skypoints.ref.country (
  iso3          VARCHAR(3) PRIMARY KEY,
  country_name  VARCHAR,
  target_table  VARCHAR,
  dob_format    VARCHAR DEFAULT 'DDMMYYYY'
);
CREATE TABLE IF NOT EXISTS skypoints.ref.country_alias (
  alias  VARCHAR PRIMARY KEY,
  iso3   VARCHAR(3)
);
CREATE TABLE IF NOT EXISTS skypoints.ref.tier (
  tier_code VARCHAR(5) PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS skypoints.ref.run_config (
  as_of_date DATE,
  feed_date  DATE
);

-- Re-runnable seed data (Snowflake does not enforce primary keys)
TRUNCATE TABLE skypoints.ref.country;
TRUNCATE TABLE skypoints.ref.country_alias;
TRUNCATE TABLE skypoints.ref.tier;

INSERT INTO skypoints.ref.country VALUES
  ('IND','India','TABLE_INDIA','DDMMYYYY'),
  ('USA','United States','TABLE_USA','MMDDYYYY'),
  ('AUS','Australia','TABLE_AUSTRALIA','DDMMYYYY'),
  ('CAN','Canada','TABLE_CANADA','DDMMYYYY'),
  ('PHL','Philippines','TABLE_PHILIPPINES','DDMMYYYY');

INSERT INTO skypoints.ref.country_alias VALUES
  ('AU','AUS'), ('PHIL','PHL'), ('US','USA');

INSERT INTO skypoints.ref.tier VALUES ('GLD'), ('SLV'), ('PLT');

-- =========================
-- CORE: template for per-country tables, routing table, redemptions
-- =========================
CREATE TABLE IF NOT EXISTS skypoints.core.member_template (
  member_id         VARCHAR(18)  NOT NULL,
  member_name       VARCHAR(255) NOT NULL,
  enrollment_date   DATE         NOT NULL,
  last_flight_date  DATE,
  tier_code         VARCHAR(5),
  agent_name        VARCHAR(255),
  state             VARCHAR(5),
  country_code      VARCHAR(3)   NOT NULL,
  post_code         VARCHAR(10),
  dob               DATE,
  is_active         CHAR(1),
  age               NUMBER(3,0),
  stale_member      BOOLEAN,
  _feed_date        DATE,
  _source_file      VARCHAR,
  _file_row_number  NUMBER
);

CREATE TABLE IF NOT EXISTS skypoints.core.member_current (
  member_id     VARCHAR(18) PRIMARY KEY,
  country_code  VARCHAR(3),
  target_table  VARCHAR,
  _feed_date    DATE,
  updated_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS skypoints.core.redemption_txn (
  txn_id          VARCHAR PRIMARY KEY,
  member_id       VARCHAR(18),
  feed_date       DATE,
  txn_date        DATE,
  partner         VARCHAR,
  miles_redeemed  NUMBER(12,0),
  status          VARCHAR(20),
  _source_file    VARCHAR
) CLUSTER BY (txn_date);

-- =========================
-- STG: typed and validated rows
-- =========================
CREATE TABLE IF NOT EXISTS skypoints.stg.member_stg LIKE skypoints.core.member_template;
ALTER TABLE skypoints.stg.member_stg ADD COLUMN IF NOT EXISTS dq_warnings ARRAY;
ALTER TABLE skypoints.stg.member_stg ADD COLUMN IF NOT EXISTS _as_of_date DATE;

CREATE TABLE IF NOT EXISTS skypoints.stg.member_latest LIKE skypoints.core.member_template;

-- =========================
-- DQ: rejected rows
-- =========================
CREATE TABLE IF NOT EXISTS skypoints.dq.member_reject (
  raw_record   VARIANT,
  dq_errors    ARRAY,
  _source_file VARCHAR,
  _feed_date   DATE,
  rejected_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);