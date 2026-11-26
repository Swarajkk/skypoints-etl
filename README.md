# SkyPoints Member and Redemption Pipeline

Solution to the Incubyte Data Engineer technical assessment, built on **Snowflake** (SQL, stored procedures) with a small **Python** normalizer for the legacy Excel extracts.

Repository: https://github.com/Swarajkk/skypoints-etl

## The problem in one paragraph

SkyPoints is a global airline loyalty programme. A source system sends two daily feeds: a pipe-delimited flat file of member profiles and a semi-structured JSON feed of mileage redemptions. Members must be split into per-country tables (`Table_India`, and so on), a member who moves country must end up in exactly one table (latest record wins), and the design must hold up at billions of records per day. Bad data must be caught, not silently loaded.

## Deliverables and where to find them

| # | Deliverable | Where |
|---|---|---|
| 1 | DDL for raw/landing, staging and country tables | `sql/01_ddl.sql` (country tables are created `LIKE core.member_template` by `sql/04_split.sql`) |
| 2 | Staging load with derived `Age` and `Stale_Member` | `sql/02_staging.sql` (view `stg.v_member_typed`, then load) |
| 3 | Split into country tables, latest record wins | `sql/04_split.sql` (`core.sp_split_members`) |
| 4 | Flatten JSON redemptions and join to members | `sql/05_redemptions.sql` (`core.redemption_txn`, `core.v_redemption_enriched`) |
| 5 | Validations | Member rules inside `stg.v_member_typed`; redemption rules and integrity checks in `sql/06_dq.sql` |
| 6 | Live demo | See "Demo script" below |

## Architecture

```
 Excel extracts (IND/USA/AUS)         Flat file (pipe)          JSON feed (NDJSON)
        |                                   |                          |
  Python normalizer  ------------->  @raw.member_stage          @raw.redemption_stage
  (src/skypoints)                           |                          |
                                      COPY INTO                   COPY INTO
                                            v                          v
                              raw.member_feed_raw       raw.redemption_feed_raw (VARIANT)
                                            |                          |
                          stg.v_member_typed (parse, derive,           |
                          validate: errors + warnings)                 |
                              |                      |                 |
                    stg.member_stg        dq.member_reject             |
                              |                                        |
                    core.sp_split_members                         MERGE (flatten)
                       |         |                                     |
        core.table_<country>   core.member_current  <---- join ----  core.redemption_txn
                       \_____ core.v_member_all  ____/        core.v_redemption_enriched
                                            |
                                 dq.v_check_results and friends
```

More detail, trade-offs and scale notes are in [`docs/architecture.md`](docs/architecture.md).

## Repository layout

```
README.md
requirements.txt
config/country_sources.yaml       per-country Excel mapping (columns, ID prefix, date formats)
data/sample/                      the 3 Excel files, 2 flat-file fixtures, 1 NDJSON fixture
src/skypoints/                    excel_normalizer.py, cli.py
tests/test_normalizer.py          Python unit tests
tests/sql/                        6 SQL assertion files (no rows returned = pass)
sql/00_setup.sql ... 06_dq.sql    Snowflake scripts, run in numeric order
docs/                             assumptions, data issues, architecture, AI usage log
```

## Prerequisites

- Python 3.10+ (developed on 3.12)
- A Snowflake account (a trial account is enough) and a role that can create a warehouse and database (`ACCOUNTADMIN` was used)
- Git

## How to run

### A. Convert the Excel extracts (local machine)

Run from the repository root.

```powershell
python -m venv .venv
.venv\Scripts\activate            # macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
$env:PYTHONPATH="src"             # macOS/Linux: export PYTHONPATH=src
pytest -q
python -m skypoints.cli data/sample data/out 20240115
```

This writes `member_IND_20240115.txt`, `member_USA_20240115.txt` and `member_AUS_20240115.txt` to `data/out/` (not committed).

### B. Snowflake, day 1

1. Run `sql/00_setup.sql`, then `sql/01_ddl.sql` (use **Run All**).
2. Upload to `RAW.MEMBER_STAGE`: `data/sample/member_20240115.txt` and the three files from `data/out/`.
3. Run `sql/03_load_raw.sql`, then `sql/02_staging.sql` (its `run_config` insert is set to `2024-01-15`).
4. Run `sql/04_split.sql`.
5. Upload `data/sample/redemptions_20240115.ndjson` to `RAW.REDEMPTION_STAGE`, then run `sql/05_redemptions.sql`.
6. Run `sql/06_dq.sql`.

### C. Snowflake, day 2 (the country move)

1. Upload `data/sample/member_20240116.txt` to `RAW.MEMBER_STAGE`.
2. Rerun `sql/03_load_raw.sql` (Snowflake skips files it already loaded).
3. In `sql/02_staging.sql` change the `run_config` insert to `('2024-01-16', '2024-01-16')` and run it.
4. `CALL skypoints.core.sp_split_members('2024-01-16'::DATE);` then `CALL skypoints.core.sp_refresh_member_all();`

Ravi (`223458`) moves from `TABLE_INDIA` to `TABLE_AUSTRALIA`.

### D. Tests

Run each file in `tests/sql/`. Each returns **no rows** when the check passes. Python tests: `pytest -q`.

## Expected results (sample data)

| Checkpoint | Expected |
|---|---|
| Day 1 raw load | 4 header rows, 14 detail rows |
| Day 1 staging | 13 staged rows, 1 rejected (`AUS-2`, `E05_INVALID_ENROLLMENT_DATE`) |
| Day 1 per-country counts | AUS 3, CAN 1, IND 4, PHL 1, USA 4 (13 members) |
| Redemptions | 3 transactions, 3 rule violations (`RX10092` R05, `RX10093` R01 and R04) |
| Day 2 raw load | 5 header rows, 16 detail rows |
| Day 2 staging | 1 staged row (Ravi), 1 rejected (`Bad Row`, `E02_MISSING_MEMBER_ID`) |
| Day 2 per-country counts | AUS 4, CAN 1, IND 3, PHL 1, USA 4 (still 13 members) |

## Data quality at a glance

- **Errors** (row rejected to `dq.member_reject`, with reason codes `E01` to `E12`): missing mandatory fields, malformed IDs, unparseable or impossible dates, unmapped country, flight before enrollment, future dates, DOB not before enrollment, superseded duplicate key within a batch.
- **Warnings** (row loaded and flagged in `dq_warnings`, codes `W01` to `W06`): short numeric member ID, unknown tier, bad active flag, missing agent, malformed post code, implausible age.
- **Redemption rules** (report-only view `dq.v_redemption_violations`, codes `R01` to `R05`).
- **Integrity checks** (`dq.v_check_results`): reconciliation of raw to staged plus rejected, no member in two countries, routing table matches country tables, unique transaction IDs.

The full catalogue of what was found in the supplied data and how each issue is handled is in [`docs/data-issues.md`](docs/data-issues.md). Decisions I had to make where the brief was silent are in [`docs/assumptions.md`](docs/assumptions.md).

## Scale

The pattern is built to work on the daily delta, not the full history: files land by feed date, staging and the split are scoped to one feed date, and the routing table `core.member_current` gives a primary-key lookup of where a member lives instead of scanning every country table. The demo uses a plain `COPY` and a re-runnable `MERGE`; the production path (Snowpipe, Streams and Tasks, clustering, warehouse sizing) is described in `docs/architecture.md`.

## Known limitations

- The split procedure names the five country tables explicitly. Adding a country needs a `ref.country` row, a `CREATE TABLE`, and one delete and one insert statement in the procedure.
- `Age` and `Stale_Member` are frozen at load time against `as_of_date`; consumers needing today's value should compute it in a view.
- Redemption rule violations are reported, not rejected.
- The member Excel extracts carry no Agent, State or Is_Active, so those columns are empty for those members (flagged by warning `W04`).
- No streaming or scheduling is wired up; scripts are run manually for the demo.

## Demo script

1. Walk through `docs/data-issues.md` and `docs/assumptions.md` (2 minutes).
2. Run the Python converter and show one output file, including the `2021-13-13` value passing through unchanged.
3. Day 1: load, stage, show `dq.member_reject` and `dq.v_member_warning_summary`, run the split, show per-country counts.
4. Show `Age` and `Stale_Member` for a few members at `as_of_date = 2024-01-15`.
5. Redemptions: load, show the flattened table, the enriched join, and `dq.v_redemption_violations`.
6. Day 2: load the second file, run the split, show Ravi leave India and arrive in Australia, then `dq.v_check_results`.
7. Run the SQL tests and explain what each proves.
8. Close with scale (`docs/architecture.md`) and how AI was used (`docs/ai-usage.md`).

## AI usage

AI tools were used throughout; see [`docs/ai-usage.md`](docs/ai-usage.md) for what was generated, what was verified, and what was changed.