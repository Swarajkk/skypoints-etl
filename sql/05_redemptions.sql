USE ROLE ACCOUNTADMIN;
USE WAREHOUSE SKYPOINTS_WH;
USE DATABASE SKYPOINTS;

-- =====================================================================
-- File: sql/05_redemptions.sql
-- Deliverable 4: Parse the JSON redemption feed and join it back to members
-- =====================================================================
-- Source format: NDJSON (one JSON document per line).
--
-- Expected document structure:
-- {
--   "member_id": "223457",
--   "feed_date": "20240115",
--   "redemptions": [
--     {
--       "txn_id": "RX10091",
--       "txn_date": "20240110",
--       "partner": "AeroLink",
--       "miles_redeemed": 12000,
--       "status": "COMPLETED"
--     }
--   ]
-- }
--
-- Prerequisites from 01_ddl.sql:
--   RAW.REDEMPTION_STAGE
--   RAW.REDEMPTION_FEED_RAW
--   CORE.REDEMPTION_TXN
--   CORE.V_MEMBER_ALL (created by 04_split.sql)
--
-- Processing approach:
--   1. Ensure raw and core redemption tables exist.
--   2. Copy NDJSON documents from the internal stage into RAW as VARIANT.
--   3. FLATTEN the nested redemptions array into transaction-level rows.
--   4. Deduplicate by TXN_ID and MERGE into CORE.REDEMPTION_TXN.
--   5. Enrich transactions with member attributes.
--   6. Run transaction, duplicate, date and orphan-member validations.
--
-- Important:
--   The supplied sample contains member_id "223457" and an orphan "999999".
--   Do not automatically add a country prefix to redemption member IDs.
--   Confirm that the redemption feed uses the same member-ID convention as
--   CORE.MEMBER_CURRENT / CORE.V_MEMBER_ALL. If member IDs are namespaced in
--   the member pipeline (for example, IND-223457), document and implement an
--   explicit, approved crosswalk before joining. Do not guess the country.


-- =====================================================================
-- 1. ENSURE REQUIRED TABLES EXIST
-- =====================================================================

CREATE TABLE IF NOT EXISTS skypoints.raw.redemption_feed_raw (
  payload VARIANT,
  _source_file VARCHAR,
  _loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS skypoints.core.redemption_txn (
  txn_id VARCHAR NOT NULL,
  member_id VARCHAR(18),
  feed_date DATE,
  txn_date DATE,
  partner VARCHAR,
  miles_redeemed NUMBER(12,0),
  status VARCHAR(20),
  _source_file VARCHAR,
  CONSTRAINT pk_redemption_txn PRIMARY KEY (txn_id)
)
CLUSTER BY (txn_date);


-- =====================================================================
-- 2. VERIFY THE STAGE BEFORE LOADING
-- =====================================================================
-- Upload redemptions_20240115.ndjson to @SKYPOINTS.RAW.REDEMPTION_STAGE
-- using Snowsight's stage upload option or SnowSQL PUT.
--
-- Example SnowSQL command (run in SnowSQL, not a Snowsight worksheet):
-- PUT file://C:/path/to/redemptions_20240115.ndjson
--   @skypoints.raw.redemption_stage AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
--
-- Check that the file is present:
LIST @skypoints.raw.redemption_stage;


-- =====================================================================
-- 3. LOAD NDJSON INTO THE RAW VARIANT TABLE
-- =====================================================================
-- COPY is file-load-tracked by Snowflake. Re-running this statement does not
-- normally reload files already recorded as loaded. Do not use FORCE=TRUE
-- unless you intentionally want to reload the same staged file.

COPY INTO skypoints.raw.redemption_feed_raw (payload, _source_file)
FROM (
  SELECT
    $1,
    METADATA$FILENAME
  FROM @skypoints.raw.redemption_stage
)
FILE_FORMAT = (TYPE = JSON)
ON_ERROR = CONTINUE;


-- Verify raw documents and their source files.
SELECT
  _source_file,
  COUNT(*) AS document_count,
  MIN(_loaded_at) AS first_loaded_at,
  MAX(_loaded_at) AS last_loaded_at
FROM skypoints.raw.redemption_feed_raw
GROUP BY _source_file
ORDER BY _source_file;

-- Inspect the raw JSON payloads.
SELECT
  _source_file,
  payload
FROM skypoints.raw.redemption_feed_raw
ORDER BY _loaded_at DESC;


-- =====================================================================
-- 4. FLATTEN JSON AND MERGE TRANSACTIONS INTO CORE
-- =====================================================================
-- LATERAL FLATTEN converts each object in payload:redemptions into one row.
-- TRY_TO_DATE / TRY_TO_NUMBER prevent malformed values from causing a cast
-- failure. Invalid values remain NULL and are visible to validation queries.
--
-- ROW_NUMBER chooses the latest copy of a transaction when a txn_id appears
-- in more than one raw document. Feed date is the primary ordering column;
-- raw load time is the tie-breaker.
--
-- MERGE makes reruns idempotent and allows a later feed to update a
-- PENDING transaction to COMPLETED.

MERGE INTO skypoints.core.redemption_txn t
USING (
  SELECT
    txn_id,
    member_id,
    feed_date,
    txn_date,
    partner,
    miles_redeemed,
    status,
    _source_file
  FROM (
    SELECT
      f.value:txn_id::STRING AS txn_id,
      r.payload:member_id::STRING AS member_id,
      TRY_TO_DATE(
        r.payload:feed_date::STRING,
        'YYYYMMDD'
      ) AS feed_date,
      TRY_TO_DATE(
        f.value:txn_date::STRING,
        'YYYYMMDD'
      ) AS txn_date,
      f.value:partner::STRING AS partner,
      TRY_TO_NUMBER(
        f.value:miles_redeemed::STRING
      ) AS miles_redeemed,
      UPPER(f.value:status::STRING) AS status,
      r._source_file AS _source_file,
      r._loaded_at AS _loaded_at
    FROM skypoints.raw.redemption_feed_raw r,
         LATERAL FLATTEN(
           INPUT => r.payload:redemptions
         ) f
  ) parsed
  WHERE txn_id IS NOT NULL
    AND feed_date IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY txn_id
    ORDER BY feed_date DESC NULLS LAST, _loaded_at DESC
  ) = 1
) s
ON t.txn_id = s.txn_id

WHEN MATCHED
 AND (t.feed_date IS NULL OR s.feed_date >= t.feed_date)
THEN UPDATE SET
  t.member_id = s.member_id,
  t.feed_date = s.feed_date,
  t.txn_date = s.txn_date,
  t.partner = s.partner,
  t.miles_redeemed = s.miles_redeemed,
  t.status = s.status,
  t._source_file = s._source_file

WHEN NOT MATCHED THEN INSERT (
  txn_id,
  member_id,
  feed_date,
  txn_date,
  partner,
  miles_redeemed,
  status,
  _source_file
)
VALUES (
  s.txn_id,
  s.member_id,
  s.feed_date,
  s.txn_date,
  s.partner,
  s.miles_redeemed,
  s.status,
  s._source_file
);


-- =====================================================================
-- 5. VERIFY THE FLATTENED TRANSACTION DATA
-- =====================================================================

-- Expected from the supplied two-document example: 3 transactions.
SELECT COUNT(*) AS total_redemption_transactions
FROM skypoints.core.redemption_txn;

-- Inspect transaction-level records.
SELECT
  txn_id,
  member_id,
  feed_date,
  txn_date,
  partner,
  miles_redeemed,
  status,
  _source_file
FROM skypoints.core.redemption_txn
ORDER BY txn_id;


-- =====================================================================
-- 6. JOIN REDEMPTIONS BACK TO THE MEMBER PROFILE
-- =====================================================================
-- LEFT JOIN intentionally retains orphan transactions so they can be
-- identified and reported instead of silently dropping them.

CREATE OR REPLACE VIEW skypoints.core.v_redemption_enriched AS
SELECT
  t.txn_id,
  t.member_id,
  t.feed_date,
  t.txn_date,
  t.partner,
  t.miles_redeemed,
  t.status,
  t._source_file,
  m.member_name,
  m.tier_code,
  m.country_code,
  m.stale_member
FROM skypoints.core.redemption_txn t
LEFT JOIN skypoints.core.v_member_all m
  ON m.member_id = t.member_id;


-- Review enriched records, including any orphan member transactions.
SELECT *
FROM skypoints.core.v_redemption_enriched
ORDER BY txn_id;


-- Example: completed miles redeemed by country and tier.
SELECT
  country_code,
  tier_code,
  COUNT(*) AS txns,
  SUM(miles_redeemed) AS miles
FROM skypoints.core.v_redemption_enriched
WHERE status = 'COMPLETED'
GROUP BY country_code, tier_code
ORDER BY miles DESC;


-- =====================================================================
-- 7. VALIDATION 1: DUPLICATE TRANSACTION IDS
-- Expected: zero rows.
-- Note: Snowflake standard-table primary-key constraints are informational;
-- this query explicitly checks uniqueness.
-- =====================================================================

SELECT
  txn_id,
  COUNT(*) AS record_count
FROM skypoints.core.redemption_txn
GROUP BY txn_id
HAVING COUNT(*) > 1
ORDER BY txn_id;


-- =====================================================================
-- 8. VALIDATION 2: INVALID OR NON-POSITIVE REDEEMED MILES
-- Expected from the supplied sample: RX10093 is flagged (-50 miles).
-- =====================================================================

SELECT
  txn_id,
  member_id,
  miles_redeemed,
  'R01_NON_POSITIVE_MILES' AS rule
FROM skypoints.core.redemption_txn
WHERE miles_redeemed IS NULL
   OR miles_redeemed <= 0
ORDER BY txn_id;


-- =====================================================================
-- 9. VALIDATION 3: UNKNOWN OR MISSING TRANSACTION STATUS
-- Allowed statuses in the assessment example: COMPLETED, PENDING.
-- Expected: zero rows for the supplied sample.
-- =====================================================================

SELECT
  txn_id,
  status,
  'R02_UNKNOWN_STATUS' AS rule
FROM skypoints.core.redemption_txn
WHERE status IS NULL
   OR status NOT IN ('COMPLETED', 'PENDING')
ORDER BY txn_id;


-- =====================================================================
-- 10. VALIDATION 4: TRANSACTION DATE CHECK
-- txn_date must be present and must not be later than feed_date.
-- Expected: zero rows for the supplied sample.
-- =====================================================================

SELECT
  txn_id,
  txn_date,
  feed_date,
  'R03_TXN_DATE_INVALID_OR_AFTER_FEED' AS rule
FROM skypoints.core.redemption_txn
WHERE txn_date IS NULL
   OR feed_date IS NULL
   OR txn_date > feed_date
ORDER BY txn_id;


-- =====================================================================
-- 11. VALIDATION 5: ORPHAN MEMBER CHECK
-- Expected from the supplied sample: member_id 999999 is an orphan unless
-- it has subsequently been added to MEMBER_CURRENT.
-- =====================================================================

SELECT
  t.txn_id,
  t.member_id,
  'R04_ORPHAN_MEMBER' AS rule
FROM skypoints.core.redemption_txn t
LEFT JOIN skypoints.core.member_current c
  ON c.member_id = t.member_id
WHERE c.member_id IS NULL
ORDER BY t.txn_id;


-- =====================================================================
-- 12. VALIDATION 6: SKYPOINTS AS REDEMPTION PARTNER
-- The source notes this as a business-rule question, not a confirmed error.
-- Treat it as a review/WARN until the business confirms whether it is valid.
-- Expected from the supplied sample: RX10092 is returned for review.
-- =====================================================================

SELECT
  txn_id,
  member_id,
  partner,
  'W01_PARTNER_IS_PROGRAM_ITSELF_REVIEW' AS rule
FROM skypoints.core.redemption_txn
WHERE UPPER(partner) = 'SKYPOINTS'
ORDER BY txn_id;


-- =====================================================================
-- 13. VALIDATION 7: SOURCE-TO-CORE TRANSACTION COUNT
-- For the supplied example, raw flattened count and unique transaction count
-- should both be 3. If raw files are intentionally reloaded, raw count can be
-- higher because the same transaction may appear in more than one document.
-- =====================================================================

SELECT
  (
    SELECT COUNT(*)
    FROM skypoints.raw.redemption_feed_raw r,
         LATERAL FLATTEN(INPUT => r.payload:redemptions) f
    WHERE f.value:txn_id IS NOT NULL
  ) AS raw_flattened_rows,
  (
    SELECT COUNT(DISTINCT txn_id)
    FROM skypoints.raw.redemption_feed_raw r,
         LATERAL FLATTEN(INPUT => r.payload:redemptions) f
    WHERE f.value:txn_id IS NOT NULL
  ) AS raw_distinct_txn_ids,
  (
    SELECT COUNT(*)
    FROM skypoints.core.redemption_txn
  ) AS core_transaction_rows;


-- =====================================================================
-- 14. VALIDATION 8: COMPLETED / PENDING BUSINESS SUMMARY
-- =====================================================================

SELECT
  status,
  COUNT(*) AS transaction_count,
  SUM(miles_redeemed) AS total_miles_redeemed
FROM skypoints.core.redemption_txn
GROUP BY status
ORDER BY status;


-- =====================================================================
-- END OF 05_REDEMPTIONS.SQL
-- =====================================================================
