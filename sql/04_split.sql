USE ROLE ACCOUNTADMIN;
USE WAREHOUSE SKYPOINTS_WH;
USE DATABASE SKYPOINTS;

-- =====================================================================
-- Procedure 1: split one feed date into per-country tables
--              (latest record wins)
-- =====================================================================
-- Assumptions:
--   IND -> TABLE_INDIA
--   USA -> TABLE_USA
--   AUS -> TABLE_AUSTRALIA
--   CAN -> TABLE_CANADA
--   PHL -> TABLE_PHILIPPINES
--
-- MEMBER_LATEST, MEMBER_TEMPLATE and all country tables have the same
-- 16-column structure, as confirmed during schema validation.
--
-- Country-table DDL is kept outside the transaction because Snowflake DDL
-- can implicitly commit an active transaction.

CREATE TABLE IF NOT EXISTS skypoints.core.table_india
    LIKE skypoints.core.member_template;

CREATE TABLE IF NOT EXISTS skypoints.core.table_usa
    LIKE skypoints.core.member_template;

CREATE TABLE IF NOT EXISTS skypoints.core.table_australia
    LIKE skypoints.core.member_template;

CREATE TABLE IF NOT EXISTS skypoints.core.table_canada
    LIKE skypoints.core.member_template;

CREATE TABLE IF NOT EXISTS skypoints.core.table_philippines
    LIKE skypoints.core.member_template;


CREATE OR REPLACE PROCEDURE skypoints.core.sp_split_members(P_FEED_DATE DATE)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
  n_members NUMBER DEFAULT 0;
  n_moved NUMBER DEFAULT 0;
  n_unmapped NUMBER DEFAULT 0;
  n_duplicates NUMBER DEFAULT 0;
  v_txn_started BOOLEAN DEFAULT FALSE;
  e_validation EXCEPTION (-20001, 'SP_SPLIT_MEMBERS validation failed');
BEGIN

  -- 1. One winner per member in this feed
  -- DELETE is used instead of TRUNCATE to avoid an implicit transaction commit.
  DELETE FROM skypoints.stg.member_latest;

  INSERT INTO skypoints.stg.member_latest
    SELECT member_id, member_name, enrollment_date, last_flight_date, tier_code,
           agent_name, state, country_code, post_code, dob, is_active, age,
           stale_member, _feed_date, _source_file, _file_row_number
    FROM skypoints.stg.member_stg
    WHERE _feed_date = :P_FEED_DATE
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY member_id
      ORDER BY last_flight_date DESC NULLS LAST, _file_row_number DESC
    ) = 1;

  SELECT COUNT(*) INTO :n_members
  FROM skypoints.stg.member_latest;

  IF (n_members = 0) THEN
    RETURN 'No records found for feed date: ' || TO_VARCHAR(P_FEED_DATE);
  END IF;

  -- 2. Late-arriving older data never overwrites newer data
  DELETE FROM skypoints.stg.member_latest s
  USING skypoints.core.member_current cur
  WHERE cur.member_id = s.member_id
    AND cur._feed_date > s._feed_date;

  SELECT COUNT(*) INTO :n_members
  FROM skypoints.stg.member_latest;

  -- 3. Validate country mappings before modifying CORE tables
  SELECT COUNT(*) INTO :n_unmapped
  FROM skypoints.stg.member_latest s
  LEFT JOIN skypoints.ref.country r
    ON r.iso3 = s.country_code
  WHERE r.iso3 IS NULL
     OR r.target_table IS NULL;

  IF (n_unmapped > 0) THEN
    RETURN 'ERROR: ' || n_unmapped ||
           ' member record(s) have no valid country mapping. CORE tables were not changed.';
  END IF;

  -- 4. Confirm that mappings point to supported destination tables
  SELECT COUNT(*) INTO :n_unmapped
  FROM skypoints.stg.member_latest s
  JOIN skypoints.ref.country r
    ON r.iso3 = s.country_code
  WHERE r.target_table NOT IN (
    'TABLE_INDIA',
    'TABLE_USA',
    'TABLE_AUSTRALIA',
    'TABLE_CANADA',
    'TABLE_PHILIPPINES'
  );

  IF (n_unmapped > 0) THEN
    RETURN 'ERROR: REF.COUNTRY contains an unsupported target table. CORE tables were not changed.';
  END IF;

  -- 5. Capture country movements before updating the routing table
  SELECT COUNT(*) INTO :n_moved
  FROM skypoints.stg.member_latest s
  JOIN skypoints.core.member_current cur
    ON cur.member_id = s.member_id
  WHERE cur.country_code <> s.country_code;

  -- 6. Check that latest staging has one row per member
  SELECT COUNT(*) INTO :n_duplicates
  FROM (
    SELECT member_id
    FROM skypoints.stg.member_latest
    GROUP BY member_id
    HAVING COUNT(*) > 1
  );

  IF (n_duplicates > 0) THEN
    RAISE e_validation;
  END IF;

  -- 7. Apply country-table changes and routing updates in one transaction
  BEGIN TRANSACTION;
  v_txn_started := TRUE;

  -- Remove each incoming member from every country table.
  -- This handles same-country updates and members moving between countries.
  DELETE FROM skypoints.core.table_india t
  USING skypoints.stg.member_latest s
  WHERE t.member_id = s.member_id;

  DELETE FROM skypoints.core.table_usa t
  USING skypoints.stg.member_latest s
  WHERE t.member_id = s.member_id;

  DELETE FROM skypoints.core.table_australia t
  USING skypoints.stg.member_latest s
  WHERE t.member_id = s.member_id;

  DELETE FROM skypoints.core.table_canada t
  USING skypoints.stg.member_latest s
  WHERE t.member_id = s.member_id;

  DELETE FROM skypoints.core.table_philippines t
  USING skypoints.stg.member_latest s
  WHERE t.member_id = s.member_id;

  -- 8. Insert into the correct country table
  INSERT INTO skypoints.core.table_india
    SELECT *
    FROM skypoints.stg.member_latest
    WHERE country_code = 'IND';

  INSERT INTO skypoints.core.table_usa
    SELECT *
    FROM skypoints.stg.member_latest
    WHERE country_code = 'USA';

  INSERT INTO skypoints.core.table_australia
    SELECT *
    FROM skypoints.stg.member_latest
    WHERE country_code = 'AUS';

  INSERT INTO skypoints.core.table_canada
    SELECT *
    FROM skypoints.stg.member_latest
    WHERE country_code = 'CAN';

  INSERT INTO skypoints.core.table_philippines
    SELECT *
    FROM skypoints.stg.member_latest
    WHERE country_code = 'PHL';

  -- 9. Update the central routing table
  MERGE INTO skypoints.core.member_current t
  USING (
    SELECT s.member_id, s.country_code, rc.target_table, s._feed_date
    FROM skypoints.stg.member_latest s
    JOIN skypoints.ref.country rc
      ON rc.iso3 = s.country_code
  ) s
  ON t.member_id = s.member_id
  WHEN MATCHED THEN UPDATE SET
    country_code = s.country_code,
    target_table = s.target_table,
    _feed_date   = s._feed_date,
    updated_at   = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (
    member_id, country_code, target_table, _feed_date
  )
  VALUES (
    s.member_id, s.country_code, s.target_table, s._feed_date
  );

  COMMIT;
  v_txn_started := FALSE;

  RETURN 'members processed: ' || n_members ||
         ', country moves: ' || n_moved ||
         ', unmapped records: 0, duplicate IDs in batch: 0';

EXCEPTION
  WHEN OTHER THEN
    IF (v_txn_started) THEN
      ROLLBACK;
      v_txn_started := FALSE;
    END IF;
    RAISE;
END;
$$;


-- =====================================================================
-- Procedure 2: rebuild a unified view across all country tables
-- =====================================================================
CREATE OR REPLACE PROCEDURE skypoints.core.sp_refresh_member_all()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
  stmt VARCHAR;
BEGIN
  SELECT
    'CREATE OR REPLACE VIEW skypoints.core.v_member_all AS ' ||
    LISTAGG(
      'SELECT * FROM skypoints.core.' || table_name,
      ' UNION ALL '
    ) WITHIN GROUP (ORDER BY table_name)
  INTO :stmt
  FROM skypoints.information_schema.tables
  WHERE table_schema = 'CORE'
    AND STARTSWITH(table_name, 'TABLE_')
    AND table_name IN (
      'TABLE_INDIA',
      'TABLE_USA',
      'TABLE_AUSTRALIA',
      'TABLE_CANADA',
      'TABLE_PHILIPPINES'
    );

  IF (stmt IS NULL) THEN
    RETURN 'ERROR: No country tables found; unified view was not refreshed.';
  END IF;

  EXECUTE IMMEDIATE :stmt;
  RETURN 'view refreshed';
END;
$$;


-- =====================================================================
-- Run for day 1 (change the date for each feed day)
-- =====================================================================
CALL skypoints.core.sp_split_members('2024-01-15'::DATE);
CALL skypoints.core.sp_refresh_member_all();


-- =====================================================================
-- Verification 1: country-wise member counts
-- Expected sample distribution: IND 4, USA 4, AUS 3, CAN 1, PHL 1.
-- =====================================================================
SELECT country_code, COUNT(*) AS members
FROM skypoints.core.v_member_all
GROUP BY country_code
ORDER BY country_code;


-- =====================================================================
-- Verification 2: total rows in the consolidated view
-- Expected for the sample feed: 13.
-- =====================================================================
SELECT COUNT(*) AS total_members
FROM skypoints.core.v_member_all;


-- =====================================================================
-- Verification 3: duplicate member IDs in the consolidated view
-- Expected: zero rows.
-- =====================================================================
SELECT member_id, COUNT(*) AS record_count
FROM skypoints.core.v_member_all
GROUP BY member_id
HAVING COUNT(*) > 1
ORDER BY member_id;


-- =====================================================================
-- Verification 4: routing-to-country-table consistency
-- Expected: zero rows.
-- =====================================================================
SELECT
  mc.member_id,
  mc.country_code AS routing_country,
  v.country_code AS table_country,
  mc.target_table
FROM skypoints.core.member_current mc
LEFT JOIN skypoints.core.v_member_all v
  ON mc.member_id = v.member_id
WHERE v.member_id IS NULL
   OR mc.country_code <> v.country_code
ORDER BY mc.member_id;


-- =====================================================================
-- Verification 5: country-table-to-routing consistency
-- Expected: zero rows.
-- =====================================================================
SELECT
  v.member_id,
  v.country_code,
  mc.target_table
FROM skypoints.core.v_member_all v
LEFT JOIN skypoints.core.member_current mc
  ON v.member_id = mc.member_id
WHERE mc.member_id IS NULL
   OR mc.country_code <> v.country_code
ORDER BY v.member_id;


-- =====================================================================
-- Verification 6: duplicate IDs inside each individual country table
-- Expected: zero rows.
-- =====================================================================
SELECT 'TABLE_INDIA' AS source_table, member_id, COUNT(*) AS record_count
FROM skypoints.core.table_india
GROUP BY member_id
HAVING COUNT(*) > 1

UNION ALL

SELECT 'TABLE_USA', member_id, COUNT(*)
FROM skypoints.core.table_usa
GROUP BY member_id
HAVING COUNT(*) > 1

UNION ALL

SELECT 'TABLE_AUSTRALIA', member_id, COUNT(*)
FROM skypoints.core.table_australia
GROUP BY member_id
HAVING COUNT(*) > 1

UNION ALL

SELECT 'TABLE_CANADA', member_id, COUNT(*)
FROM skypoints.core.table_canada
GROUP BY member_id
HAVING COUNT(*) > 1

UNION ALL

SELECT 'TABLE_PHILIPPINES', member_id, COUNT(*)
FROM skypoints.core.table_philippines
GROUP BY member_id
HAVING COUNT(*) > 1
ORDER BY source_table, member_id;


-- =====================================================================
-- Verification 7: routing distribution
-- Expected sample distribution: IND 4, USA 4, AUS 3, CAN 1, PHL 1.
-- =====================================================================
SELECT country_code, target_table, COUNT(*) AS members
FROM skypoints.core.member_current
GROUP BY country_code, target_table
ORDER BY country_code;


-- =====================================================================
-- Verification 8: total-count reconciliation
-- Expected: routing_count = consolidated_count = 13 for day 1.
-- =====================================================================
SELECT
  (SELECT COUNT(*) FROM skypoints.core.member_current) AS routing_count,
  (SELECT COUNT(*) FROM skypoints.core.v_member_all) AS consolidated_count;
