USE ROLE ACCOUNTADMIN;
USE WAREHOUSE skypoints_wh;
USE DATABASE skypoints;

CREATE OR REPLACE VIEW skypoints.stg.v_member_typed AS
WITH cfg AS (
  SELECT as_of_date, feed_date FROM skypoints.ref.run_config
),
cleaned AS (
  SELECT
    NULLIF(TRIM(r.member_id), '')              AS member_id,
    NULLIF(TRIM(r.member_name), '')            AS member_name,
    NULLIF(TRIM(r.enrollment_date), '')        AS enr_raw,
    NULLIF(TRIM(r.last_flight_date), '')       AS flt_raw,
    NULLIF(UPPER(TRIM(r.tier_code)), '')       AS tier_code,
    NULLIF(TRIM(r.agent_name), '')             AS agent_name,
    NULLIF(TRIM(r.state), '')                  AS state,
    COALESCE(a.iso3, NULLIF(UPPER(TRIM(r.country)), '')) AS country_code,
    NULLIF(TRIM(r.post_code), '')              AS post_code,
    NULLIF(TRIM(r.dob), '')                    AS dob_raw,
    NULLIF(UPPER(TRIM(r.is_active)), '')       AS is_active,
    r._source_file, r._file_row_number, r._feed_date,
    OBJECT_CONSTRUCT_KEEP_NULL(
      'member_name', r.member_name, 'member_id', r.member_id,
      'enrollment_date', r.enrollment_date, 'last_flight_date', r.last_flight_date,
      'tier_code', r.tier_code, 'agent_name', r.agent_name, 'state', r.state,
      'country', r.country, 'dob', r.dob, 'is_active', r.is_active
    ) AS raw_record
  FROM skypoints.raw.member_feed_raw r
  LEFT JOIN skypoints.ref.country_alias a ON a.alias = UPPER(TRIM(r.country))
  WHERE r.record_type = 'D'
),
typed AS (
  SELECT c.*, cfg.as_of_date, rc.iso3 AS known_country, tr.tier_code AS known_tier,
    TRY_TO_DATE(c.enr_raw, 'YYYYMMDD') AS enrollment_date,
    TRY_TO_DATE(c.flt_raw, 'YYYYMMDD') AS last_flight_date,
    IFF(rc.dob_format = 'MMDDYYYY',
        TRY_TO_DATE(LPAD(c.dob_raw, 8, '0'), 'MMDDYYYY'),
        TRY_TO_DATE(LPAD(c.dob_raw, 8, '0'), 'DDMMYYYY')) AS dob
  FROM cleaned c
  CROSS JOIN cfg
  LEFT JOIN skypoints.ref.country rc ON rc.iso3 = c.country_code
  LEFT JOIN skypoints.ref.tier tr ON tr.tier_code = c.tier_code
),
derived AS (
  SELECT t.*,
    IFF(dob IS NULL, NULL,
        DATEDIFF('year', dob, as_of_date)
        - IFF(DATEADD('year', DATEDIFF('year', dob, as_of_date), dob) > as_of_date, 1, 0)) AS age,
    DATEDIFF('day', last_flight_date, as_of_date) > 90 AS stale_member,
    ROW_NUMBER() OVER (
      PARTITION BY member_id, _feed_date
      ORDER BY last_flight_date DESC NULLS LAST, _file_row_number DESC) AS rn_in_batch
  FROM typed t
)
SELECT d.*,
  ARRAY_COMPACT(ARRAY_CONSTRUCT(
    IFF(member_name IS NULL, 'E01_MISSING_NAME', NULL),
    IFF(member_id IS NULL, 'E02_MISSING_MEMBER_ID',
        IFF(NOT REGEXP_LIKE(member_id, '[A-Za-z0-9-]{1,18}'), 'E03_BAD_MEMBER_ID', NULL)),
    IFF(enr_raw IS NULL, 'E04_MISSING_ENROLLMENT_DATE',
        IFF(enrollment_date IS NULL, 'E05_INVALID_ENROLLMENT_DATE', NULL)),
    IFF(flt_raw IS NOT NULL AND last_flight_date IS NULL, 'E06_INVALID_FLIGHT_DATE', NULL),
    IFF(dob_raw IS NOT NULL AND dob IS NULL, 'E07_INVALID_DOB', NULL),
    IFF(known_country IS NULL, 'E08_UNMAPPED_COUNTRY', NULL),
    IFF(last_flight_date < enrollment_date, 'E09_FLIGHT_BEFORE_ENROLLMENT', NULL),
    IFF(last_flight_date > as_of_date OR enrollment_date > as_of_date, 'E10_FUTURE_DATE', NULL),
    IFF(dob >= enrollment_date, 'E11_DOB_NOT_BEFORE_ENROLLMENT', NULL),
    IFF(member_id IS NOT NULL AND rn_in_batch > 1, 'E12_DUPLICATE_KEY_SUPERSEDED', NULL)
  )) AS dq_errors,
  ARRAY_COMPACT(ARRAY_CONSTRUCT(
    IFF(REGEXP_LIKE(member_id, '[0-9]{1,5}'), 'W01_SHORT_NUMERIC_MEMBER_ID', NULL),
    IFF(tier_code IS NOT NULL AND known_tier IS NULL, 'W02_UNKNOWN_TIER', NULL),
    IFF(is_active IS NOT NULL AND is_active NOT IN ('A', 'I'), 'W03_BAD_ACTIVE_FLAG', NULL),
    IFF(agent_name IS NULL, 'W04_MISSING_AGENT', NULL),
    IFF(post_code IS NOT NULL AND NOT REGEXP_LIKE(post_code, '[A-Za-z0-9 -]{3,10}'), 'W05_BAD_POST_CODE', NULL),
    IFF(age IS NOT NULL AND age NOT BETWEEN 0 AND 120, 'W06_IMPLAUSIBLE_AGE', NULL)
  )) AS dq_warnings
FROM derived d;

-- Run config: edit these two dates for each feed day (as_of_date, feed_date)
TRUNCATE TABLE skypoints.ref.run_config;
INSERT INTO skypoints.ref.run_config VALUES ('2024-01-15', '2024-01-15');

-- Idempotent reload of this feed date
DELETE FROM skypoints.stg.member_stg
  WHERE _feed_date = (SELECT feed_date FROM skypoints.ref.run_config);
DELETE FROM skypoints.dq.member_reject
  WHERE _feed_date = (SELECT feed_date FROM skypoints.ref.run_config);

INSERT INTO skypoints.stg.member_stg
SELECT member_id, member_name, enrollment_date, last_flight_date, tier_code, agent_name, state,
       country_code, post_code, dob, is_active, age, stale_member,
       _feed_date, _source_file, _file_row_number, dq_warnings, as_of_date
FROM skypoints.stg.v_member_typed
WHERE ARRAY_SIZE(dq_errors) = 0
  AND _feed_date = (SELECT feed_date FROM skypoints.ref.run_config);

INSERT INTO skypoints.dq.member_reject (raw_record, dq_errors, _source_file, _feed_date)
SELECT raw_record, dq_errors, _source_file, _feed_date
FROM skypoints.stg.v_member_typed
WHERE ARRAY_SIZE(dq_errors) > 0
  AND _feed_date = (SELECT feed_date FROM skypoints.ref.run_config);

-- Verification
SELECT COUNT(*) AS staged_rows FROM skypoints.stg.member_stg;
SELECT * FROM skypoints.dq.member_reject;
SELECT member_id, member_name, country_code, dob, age, stale_member, dq_warnings
FROM skypoints.stg.member_stg ORDER BY member_id;