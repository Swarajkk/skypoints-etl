USE ROLE ACCOUNTADMIN;
USE WAREHOUSE skypoints_wh;
USE DATABASE skypoints;

WITH cases AS (
  SELECT '2024-01-15'::DATE AS as_of_date, '2023-10-17'::DATE AS last_flight_date, FALSE AS expected  -- 90 days
  UNION ALL SELECT '2024-01-15'::DATE, '2023-10-16'::DATE, TRUE                                       -- 91 days
  UNION ALL SELECT '2024-01-15'::DATE, '2024-01-14'::DATE, FALSE                                      -- 1 day
  UNION ALL SELECT '2024-01-15'::DATE, NULL::DATE, NULL::BOOLEAN                                      -- never flown
),
calc AS (
  SELECT as_of_date, last_flight_date, expected,
         DATEDIFF('day', last_flight_date, as_of_date) > 90 AS actual
  FROM cases
),
stored AS (
  SELECT member_id, stale_member AS actual,
         DATEDIFF('day', last_flight_date, _as_of_date) > 90 AS expected
  FROM skypoints.stg.member_stg
)
SELECT 'boundary_case' AS test_case,
       COALESCE(last_flight_date::STRING, 'NULL') || ' as of ' || as_of_date::STRING AS detail,
       expected, actual
FROM calc WHERE actual IS DISTINCT FROM expected
UNION ALL
SELECT 'stored_stale_matches_recompute', member_id, expected, actual
FROM stored WHERE actual IS DISTINCT FROM expected;