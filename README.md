# SkyPoints ETL Assessment

A Python and Snowflake data-engineering assessment project for standardising country-specific member workbooks, landing pipe-delimited member feeds, applying typed staging and data-quality checks, and preparing a foundation for member and redemption curation.

> **Implementation status:** The repository currently contains the Excel normalizer, country configuration, Snowflake setup/DDL/raw-load/staging scripts, and normalizer unit tests. Country-table routing, latest-record-wins curation, redemption ingestion/flattening, and full end-to-end reconciliation are documented as intended next steps; they are not represented as completed scripts in the current repository.

## 1. Problem statement

Input data arrives from multiple country workbooks with inconsistent column names, date representations, and available attributes. The assessment also includes pipe-delimited member feeds and an NDJSON redemption feed. The objective is a repeatable ingestion and validation approach that preserves source traceability and prevents malformed values from silently becoming trusted curated data.

The current implementation focuses on:
- Normalising IND, USA, and AUS Excel workbooks to a common pipe-delimited member layout.
- Retaining source-specific date interpretation in `config/country_sources.yaml`.
- Landing member files in a raw Snowflake table using permissive string columns.
- Converting raw values to typed staging fields and deriving age/stale-member indicators.
- Separating records with proposed ERROR rules into a DQ reject table and retaining WARN codes on staged rows.

## 2. Architecture

```text
IND.xlsx ─┐
USA.xlsx ─┼─> Python normalizer + country_sources.yaml
AUS.xlsx ─┘                |
                           v
                 Pipe-delimited member files
                           |
                           v
                 Snowflake internal stage
                           |
                           v
                 RAW.member_feed_raw
                           |
                           v
                 STG.v_member_typed
                    /           \
          ERROR records        valid records
               |                   |
               v                   v
        DQ.member_reject     STG.member_stg
                                   |
                                   v
                       [Planned CORE curation]
                        country tables / member
                         routing / latest wins

NDJSON redemption feed --> [Planned RAW VARIANT + FLATTEN]
                         --> [Planned CORE redemption transactions]
```

The SQL setup creates `RAW`, `REF`, `STG`, `CORE`, and `DQ` schemas. Raw member columns are strings so parsing and business validation can happen after landing. The redemption raw table is created with a `VARIANT` payload column, but an ingestion and flattening script is not yet present.

## 3. Repository layout

```text
skypoints-etl/
├── README.md
├── .gitignore
├── config/
│   └── country_sources.yaml
├── data/
│   └── sample/
│       ├── IND.xlsx
│       ├── USA.xlsx
│       ├── AUS.xlsx
│       ├── member_20240115.txt
│       ├── member_20240116.txt
│       └── redemptions_20240115.ndjson
├── docs/
│   ├── assumptions.md
│   └── data-issues.md
├── sql/
│   ├── 00_setup.sql
│   ├── 01_ddl.sql
│   ├── 02_staging.sql
│   └── 03_load_raw.sql
├── src/
│   └── skypoints/
│       ├── __init__.py
│       ├── cli.py
│       └── excel_normalizer.py
├── tests/
│   └── test_normalizer.py
└── requirements.txt
```

## 4. Python setup and execution

Use Python 3.10+ (the code uses modern union type annotations).

```bash
python -m venv .venv
```

Activate the environment, then install dependencies:

```powershell
# Windows PowerShell
.venv\Scripts\Activate.ps1
```

```bash
# macOS / Linux
source .venv/bin/activate
```

Install dependencies and run unit tests:

```bash
pip install -r requirements.txt
pytest -q
```

Run the Excel normalizer from the repository root:

```bash
python -m skypoints.cli data/sample data/out 20240115
```

The CLI reads `IND.xlsx`, `USA.xlsx`, and `AUS.xlsx` from the supplied source directory and writes one output file per country under the output directory. The output directory is ignored by Git via `.gitignore`.

The normalizer:
- Maps source workbook columns using `config/country_sources.yaml`.
- Applies an `IND-`, `USA-`, or `AUS-` prefix to workbook member IDs to avoid collisions between repeated numeric IDs in different workbooks.
- Converts recognised Excel serial and source-specific compact dates to `YYYYMMDD` for date fields.
- Emits DOB in the configured country format.
- Passes unparseable non-null date strings through for downstream DQ handling rather than silently replacing them with a valid-looking date.
- Leaves agent, state, and active status empty because those fields are not supplied by these workbook layouts.

## 5. Snowflake setup and execution

Run the SQL scripts in order in a Snowflake worksheet or equivalent SQL client:

1. Run `sql/00_setup.sql` to create the assessment warehouse, database, and schemas. The script uses `ACCOUNTADMIN`; use an appropriately authorised role and a least-privilege deployment role outside the assessment.
2. Run `sql/01_ddl.sql` to create raw, reference, staging, core-template, and DQ objects and seed country aliases and tier reference values.
3. Upload generated member text files to `@SKYPOINTS.RAW.MEMBER_STAGE`.
4. Run `sql/03_load_raw.sql` to copy staged files into `RAW.MEMBER_FEED_RAW`.
5. Set the intended `as_of_date` and `feed_date` in the run-config section of `sql/02_staging.sql`, then run it to create the typed view and populate staging/reject tables for that feed date.

Example verification queries:

```sql
SELECT COUNT(*) AS raw_detail_rows
FROM skypoints.raw.member_feed_raw
WHERE record_type = 'D';

SELECT COUNT(*) AS staged_rows
FROM skypoints.stg.member_stg;

SELECT COUNT(*) AS rejected_rows
FROM skypoints.dq.member_reject;

SELECT member_id, member_name, country_code, dob, age, stale_member, dq_warnings
FROM skypoints.stg.member_stg
ORDER BY member_id;
```

**Important:** `sql/03_load_raw.sql` derives the feed date from an eight-digit date in the staged filename. Ensure the uploaded member file name contains the intended `YYYYMMDD` date. The current CLI names output files with country and feed date; validate that the SQL date-extraction convention matches the filenames you upload before executing the load.

## 6. Data-quality approach

The staging view proposes these member checks:

| Code | Severity | Check |
|---|---|---|
| E01–E03 | ERROR | Required member name/ID and member ID shape |
| E04–E05 | ERROR | Enrollment date required and parseable |
| E06 | ERROR | Supplied last-flight date must parse |
| E07 | ERROR | Supplied DOB must parse using the configured country format |
| E08 | ERROR | Country must map to a configured country |
| E09 | ERROR | Last flight must not be before enrollment |
| E10 | ERROR | Enrollment and last-flight dates must not be in the future relative to `as_of_date` |
| E11 | ERROR | DOB must be before enrollment |
| E12 | ERROR | Duplicate member row in a feed is marked as a superseded loser |
| W01 | WARN | Short numeric member ID |
| W02 | WARN | Tier outside the configured tier domain |
| W03 | WARN | Active flag outside the accepted domain |
| W04 | WARN | Missing agent |
| W05 | WARN | Postal-code shape |
| W06 | WARN | Implausible age |

ERROR rows are written to `DQ.MEMBER_REJECT`; valid rows are inserted into `STG.MEMBER_STG` with warning codes retained in `DQ_WARNINGS`. See [docs/assumptions.md](docs/assumptions.md) and [docs/data-issues.md](docs/data-issues.md) for rationale and unresolved source-contract questions.

The currently implemented staging SQL performs typed conversion, age/stale derivation, and staging/reject inserts. Complete batch reconciliation and downstream country-routing assertions remain to be added.

## 7. Assumptions and source-data findings

Key decisions:
- Workbook IDs are namespaced by country because numeric IDs repeat across workbook files for different people.
- USA compact dates are interpreted as MMDDYYYY; IND/AUS DOB values use DDMMYYYY in the proposed country configuration.
- Missing source attributes are not fabricated.
- The USA workbook has no DOB, so DOB and derived age remain NULL for those records.
- Invalid date strings such as `2021-13-13` are passed through for DQ checks.
- ERROR rules reject a row; WARN rules allow it into staging with warning metadata.
- Stale-member logic uses a configurable `as_of_date` and a 90-day threshold in the current staging view.

Detailed decisions: [docs/assumptions.md](docs/assumptions.md).  
Source/specification discrepancies: [docs/data-issues.md](docs/data-issues.md).

## 8. Planned completion items

These are appropriate next increments, but should not be described as implemented until code and tests are added:

1. Add curated country routing with one current country assignment per member.
2. Implement deterministic latest-record-wins across feed dates and a tested country-move scenario.
3. Add NDJSON ingestion, `LATERAL FLATTEN` of nested redemptions, transaction deduplication, and member enrichment.
4. Add redemption DQ handling for non-positive miles, status domain, transaction date, orphan member, and partner-value review.
5. Add batch reconciliation, idempotency, no-duplicate-country-membership, and day-2 country-move tests.
6. Verify all SQL scripts end-to-end in a clean Snowflake database and record actual execution results.

## 9. Scale and production considerations

For a production workload, consider:
- Cloud-storage landing with Snowpipe auto-ingest rather than manual stage uploads.
- Streams and Tasks for incremental processing.
- Deterministic `MERGE` patterns and replay-safe ingestion.
- Retention of raw payloads and source metadata for audit and replay.
- Query-profile-led decisions on clustering, warehouse sizing, and workload isolation.
- Country-level access controls where residency or privacy rules require them.

These are design considerations, not performance claims: the current repository has not established a measured large-volume benchmark.

## 10. Demo walkthrough

1. Explain source inconsistencies and the decisions in the two documentation files.
2. Run the Python normalizer and inspect one generated country feed.
3. Point out a source value that passes through the normalizer for downstream DQ rather than being coerced.
4. Run Snowflake setup, DDL, raw load, and staging scripts in order.
5. Show staged records, warning arrays, and rejected records.
6. Explain the planned next steps for current-member routing, country moves, redemptions, and full reconciliation, clearly separating them from the implemented scope.

## 11. Security and submission notes

- Never commit Snowflake passwords, private keys, access tokens, or `.env` files.
- Confirm the assessment rules before publishing supplied source data. The current repository contains sample workbooks and feed files under `data/sample/`; ensure those files are permitted for public sharing.
- Record AI assistance accurately in any required AI-use disclosure, including what was accepted, changed, rejected, and actually verified.
- Do not claim tests or Snowflake execution passed unless you have run them and retained the result.
