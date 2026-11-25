USE ROLE ACCOUNTADMIN;
USE WAREHOUSE skypoints_wh;
USE DATABASE skypoints;

WITH cases AS (
  SELECT '1985-05-03'::DATE AS dob, '2024-05-02'::DATE AS as_of_date, 38 AS expected  -- day before birthday
  UNION ALL SELECT '1985-05-03'::DATE, '2024-05-03'::DATE, 39                         -- on birthday
  UNION ALL SELECT '1985-05-03'::DATE, '2024-05-04'::DATE, 39                         -- day after
  UNION ALL SELECT '2000-02-29'::DATE, '2023-02-27'::DATE, 22                         -- leap-day birthday, before
  UNION ALL SELECT '2000-02-29'::DATE, '2023-03-01'::DATE, 23                         -- leap-day birthday, after
),
calc AS (
  SELECT dob, as_of_date, expected,
         DATEDIFF('year', dob, as_of_date)
         - IFF(DATEADD('year', DATEDIFF('year', dob, as_of_date), dob) > as_of_date, 1, 0) AS actual
  FROM cases
),
stored AS (
  SELECT member_id, age AS actual,
         DATEDIFF('year', dob, _as_of_date)
         - IFF(DATEADD('year', DATEDIFF('year', dob, _as_of_date), dob) > _as_of_date, 1, 0) AS expected
  FROM skypoints.stg.member_stg
  WHERE dob IS NOT NULL
)
SELECT 'boundary_case' AS test_case,
       dob::STRING || ' as of ' || as_of_date::STRING AS detail,
       expected, actual
FROM calc WHERE actual <> expected
UNION ALL
SELECT 'stored_age_matches_recompute', member_id, expected, actual
FROM stored WHERE actual <> expected;