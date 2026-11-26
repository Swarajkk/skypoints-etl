# Architecture

## 1. Goals

1. Land two daily feeds (pipe-delimited member profiles and a nested JSON redemption feed) without losing any record.
2. Split members into per-country tables; a member who moves country ends up in exactly one table (latest record wins).
3. Catch bad data explicitly and keep an audit trail.
4. Make the pattern work on a daily delta at billions of records, not just on the sample.

## 2. Layers

| Schema | Purpose | Tables and views |
|---|---|---|
| `raw` | Landing. Everything `VARCHAR` (or `VARIANT` for JSON), plus file name, row number, feed date, load time. A bad value can never fail a load. | `member_feed_raw`, `redemption_feed_raw`, stages `member_stage` and `redemption_stage`, file format `ff_member_pipe` |
| `ref` | Reference and run configuration. | `country`, `country_alias`, `tier`, `run_config` |
| `stg` | Typed, derived and validated member rows. | `v_member_typed` (view), `member_stg`, `member_latest` |
| `core` | Business tables. | `table_<country>` (x5), `member_template`, `member_current`, `redemption_txn`, views `v_member_all` and `v_redemption_enriched`, procedures `sp_split_members` and `sp_refresh_member_all` |
| `dq` | Data quality outputs. | `member_reject`, views `v_redemption_violations`, `v_member_reject_summary`, `v_member_warning_summary`, `v_check_results` |

## 3. Data flow

### Members

1. **Normalize (Python, only for the legacy Excel extracts).** `src/skypoints/excel_normalizer.py` maps each workbook to the canonical pipe layout using `config/country_sources.yaml`: Excel serials, lost leading zeros and `NULL` text are converted, IDs are namespaced, and impossible dates pass through unchanged.
2. **Land.** `COPY INTO raw.member_feed_raw` reads the stage. The feed date is taken from the file name, and file name and row number are stored for lineage.
3. **Type, derive, validate.** `stg.v_member_typed` trims and nulls blanks, maps country aliases, parses dates (DOB format by country), computes `age` and `stale_member`, and builds two arrays: `dq_errors` and `dq_warnings`.
4. **Stage and reject.** Rows with no errors go to `stg.member_stg`; the rest go to `dq.member_reject` with their reason codes and the raw record as a `VARIANT`. Both loads first delete the same feed date, so a rerun is safe.
5. **Split.** `core.sp_split_members(feed_date)`:
   1. picks one winner per member for the feed;
   2. drops winners that lose to a newer feed already in `core.member_current`;
   3. validates country mappings and uniqueness **before** touching CORE;
   4. in one transaction, deletes each incoming member from all country tables, inserts into the right country table, and updates the routing table;
   5. rolls back on any error.
6. **Serve.** `core.v_member_all` unions the country tables for analytics; `core.member_current` is the one-row-per-member router.

### Redemptions

1. `COPY INTO raw.redemption_feed_raw` stores each JSON document as a `VARIANT`.
2. A `MERGE` flattens `redemptions[]` with `LATERAL FLATTEN` and upserts into `core.redemption_txn` on `txn_id`. The latest feed wins, so `PENDING` can become `COMPLETED`.
3. `core.v_redemption_enriched` left-joins to `core.v_member_all` on `member_id`.
4. `dq.v_redemption_violations` reports rule breaches without removing rows.

## 4. Why these design choices

| Choice | Why |
|---|---|
| Everything lands as text | Loads never fail on bad data; every defect is a named rule later |
| Errors reject and warnings flag | Structural defects stay out of CORE; softer issues remain visible |
| `member_current` routing table | "Which country holds this member?" is a primary-key lookup, not a scan of every country table |
| Delete-then-insert per member inside a transaction | One pattern covers updates and moves, and is idempotent |
| Feed-date scoping everywhere | A rerun of one day cannot disturb another day |
| `as_of_date` in `ref.run_config` | Reproducible age and stale values |
| Validation as a view | One definition drives both the staging load and the reject load |
| Physical per-country tables plus a unified view | Meets the brief, allows per-country access control, and still gives analysts one object |
| Nested JSON kept as `VARIANT` in raw | Schema changes in the feed do not break ingestion |

## 5. Idempotency and failure handling

- Rerunning the same feed date changes nothing: staging and reject loads delete the date first, the split deletes and reinserts the same members, and the redemption `MERGE` is keyed on `txn_id`.
- Out-of-order delivery is handled by comparing the feed date against `member_current` before applying.
- The split validates before it writes and rolls back on error.
- Rejected rows keep their raw record, so a corrected reference mapping can be followed by a replay.
- `COPY INTO` skips files it has already loaded.

## 6. Verification built into the repository

| Where | What it proves |
|---|---|
| `dq.v_check_results` | Raw rows equal staged plus rejected; no member is in two countries; the routing table matches the country tables; transaction IDs are unique |
| `tests/sql/01_age_boundary.sql` | Age on, before and after a birthday, including leap days, and stored age matches recomputed age |
| `tests/sql/02_stale_boundary.sql` | 90 days is not stale, 91 is; NULL flight date gives NULL |
| `tests/sql/03_no_cross_country_duplicates.sql` | One country per member |
| `tests/sql/04_country_move.sql` | The day-2 move of Ravi from India to Australia, including routing |
| `tests/sql/05_reconciliation.sql` | Raw equals staged plus rejected for every feed date |
| `tests/sql/06_idempotent_rerun.sql` | A rerun leaves counts unchanged |
| `tests/test_normalizer.py` | Date parsing and DOB formatting in the Python normalizer |

## 7. Scaling to billions of records per day

The demo uses small files and a manual `COPY`. What is **implemented** and what is **proposed** are kept separate here.

**Implemented**
- Raw table clustered on feed date; redemption table clustered on transaction date.
- All processing scoped to one feed date, never full history.
- A routing table instead of scanning country tables.
- Set-based SQL with no row-by-row logic.

**Proposed for production**
1. **Ingestion:** cloud-storage landing with Snowpipe auto-ingest, files of roughly 100 to 250 MB compressed, so loads parallelize and file overhead stays small. For redemptions, one JSON document per line (NDJSON) so files split cleanly.
2. **Incremental processing:** Streams on the raw tables and Tasks chaining load, stage, split and checks, so each run touches only the new delta.
3. **Redemption `MERGE`:** restrict the source to new rows (stream or watermark) instead of reading all raw rows as the demo does.
4. **Compute:** a separate warehouse per stage, sized to the stage; multi-cluster scaling for backfills; auto-suspend to control cost.
5. **Clustering and pruning:** keep clustering keys aligned with the filters actually used (feed date, transaction date, and `member_id` for point lookups in the large tables).
6. **Routing table growth:** at hundreds of millions of members, keep `member_current` keyed and clustered on `member_id`; it is the only table the split must probe.
7. **Large moves:** for a very high rate of country moves, replace per-table deletes with a single set-based pass driven by the routing table's old target.
8. **Governance:** grants per country table for regional access, masking policies on DOB, and retention on raw.
9. **Observability:** persist `dq.v_check_results` per run, alert on any `INTEGRITY` failure, and track reject rates by rule code.

## 8. Known trade-offs

- The split procedure lists the five country tables explicitly. This is easy to audit but needs a code change per new country; a config-driven version would use dynamic SQL, at the cost of readability.
- `age` and `stale_member` are stored at load time against `as_of_date`. They are right for the run date and will drift; consumers wanting today's value should compute it.
- Redemption violations are reported, not enforced, which is a business decision recorded in `docs/assumptions.md`.
- Excel member IDs are namespaced by file because the extracts reuse IDs. In production a real, globally unique member ID is required.