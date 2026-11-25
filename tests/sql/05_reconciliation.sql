USE ROLE ACCOUNTADMIN;
USE WAREHOUSE skypoints_wh;
USE DATABASE skypoints;

WITH raw_cnt AS (
  SELECT _feed_date, COUNT(*) AS n
  FROM skypoints.raw.member_feed_raw
  WHERE record_type = 'D'
  GROUP BY _feed_date
),
stg_cnt AS (
  SELECT _feed_date, COUNT(*) AS n
  FROM skypoints.stg.member_stg
  GROUP BY _feed_date
),
rej_cnt AS (
  SELECT _feed_date, COUNT(*) AS n
  FROM skypoints.dq.member_reject
  GROUP BY _feed_date
)
SELECT r._feed_date,
       r.n                AS raw_rows,
       COALESCE(s.n, 0)   AS staged_rows,
       COALESCE(j.n, 0)   AS rejected_rows
FROM raw_cnt r
LEFT JOIN stg_cnt s ON s._feed_date = r._feed_date
LEFT JOIN rej_cnt j ON j._feed_date = r._feed_date
WHERE r.n <> COALESCE(s.n, 0) + COALESCE(j.n, 0);