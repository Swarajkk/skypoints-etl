# Assumptions and Design Decisions

Where the brief was silent or ambiguous, these are the decisions I made, why, and where each one is implemented. Each one is easy to change.

## Identity and ordering

| # | Decision | Rationale | Implemented in |
|---|---|---|---|
| A1 | **Member ID is the business key**, not Member Name | The spec marks Member Name as the key, which is almost certainly a mistake: names are not unique | `sql/04_split.sql`, `core.member_current` |
| A2 | **Excel member IDs are namespaced** by source file (`IND-1`, `USA-1`, `AUS-1`) | The three extracts reuse IDs 1 to 3 for different people. Without a prefix, "latest record wins" would move people between countries | `config/country_sources.yaml` (`id_prefix`) |
| A3 | **"Latest record wins"** = highest feed date; within one feed, latest `last_flight_date`, then highest file row number | The brief does not define "latest". Feed date is the only ordering that reflects when the source said it | `sql/04_split.sql` |
| A4 | **Late-arriving older data never overwrites newer data** | Replays and out-of-order delivery must be safe | Step 2 of `core.sp_split_members` |
| A5 | **Duplicate IDs within one batch**: keep the latest; reject the older rows as superseded | Keeps an audit trail instead of dropping silently | `E12_DUPLICATE_KEY_SUPERSEDED` |

## Dates and derived columns

| # | Decision | Rationale | Implemented in |
|---|---|---|---|
| A6 | **DOB format depends on the country**: `MMDDYYYY` for USA, `DDMMYYYY` otherwise | The spec shows `03051985` without a format. The US convention differs from the rest of the sample countries | `ref.country.dob_format` |
| A7 | **Seven-digit numeric dates are `MDDYYYY`** with the leading zero lost | The USA file stores dates as numbers; eight-digit values such as `12282021` confirm the `MMDDYYYY` layout | `excel_normalizer.py` (`compact_fmt`) |
| A8 | **Excel serial dates** use the 1899-12-30 epoch | Standard for Excel on both Windows and macOS (post-1900) | `excel_normalizer.py` |
| A9 | **`as_of_date` is a parameter**, not `CURRENT_DATE()` | Makes results reproducible for the demo and for tests | `ref.run_config` |
| A10 | **Stale** means `as_of_date - last_flight_date > 90` days; exactly 90 is not stale | Matches "greater than 90" in the brief | `stg.v_member_typed`, test `02_stale_boundary.sql` |
| A11 | **A NULL flight date gives a NULL stale flag** | "Never flown" is unknown, not "not stale". A silent FALSE would hide it | `stg.v_member_typed` |
| A12 | **Age** is whole years completed at `as_of_date`; a leap-day birthday turns a year older on 1 March in non-leap years | Snowflake's `DATEADD` clamps Feb 29 to Feb 28, which is covered by a boundary test | `stg.v_member_typed`, test `01_age_boundary.sql` |
| A13 | **Unparseable dates are not "fixed"**: they pass through and are rejected | Guessing a date would hide a data defect | `to_yyyymmdd`, `E05` to `E07` |

## Countries and schema

| # | Decision | Rationale | Implemented in |
|---|---|---|---|
| A14 | Countries are normalized to ISO-3 codes through an alias table (`AU` to `AUS`, `PHIL` to `PHL`) | Source codes are inconsistent | `ref.country_alias` |
| A15 | **Unmapped countries are rejected**, not routed to an "Other" table | A steward should add the mapping and replay the file | `E08_UNMAPPED_COUNTRY` |
| A16 | **Post Code is stored as `VARCHAR(10)`**, not `INT(5)` | Leading zeros and alphanumeric postal codes | `core.member_template` |
| A17 | **Post Code is not in the sample layout**, so it is loaded as NULL | The spec has 11 columns; the sample has 10 | `sql/03_load_raw.sql` |
| A18 | **Per-country tables are physical tables** created `LIKE core.member_template`, plus a unified view | Meets the "load into country tables" requirement and allows per-country access control; the view serves analytics | `sql/04_split.sql` |
| A19 | The split procedure **names the five country tables explicitly** | Simple and auditable for this scope; the trade-off is documented in the README | `sql/04_split.sql` |

## Quality policy

| # | Decision | Rationale | Implemented in |
|---|---|---|---|
| A20 | **Errors reject the row; warnings load and flag it** | Mandatory and structural defects must not reach CORE; softer issues should stay visible without blocking the feed | `dq_errors`, `dq_warnings` |
| A21 | **Short numeric member IDs are a warning**, not an error | The spec sets a maximum length (18) but no minimum | `W01` |
| A22 | **Valid statuses are `COMPLETED` and `PENDING`** | Only these appear in the sample | `R02_UNKNOWN_STATUS` |
| A23 | **Redemption violations are report-only** | Rejecting a transaction can lose a customer's redemption; the business should decide | `dq.v_redemption_violations` |
| A24 | **Partner `SkyPoints` is flagged**, not rejected | It is the programme itself; needs business confirmation | `R05` |
| A25 | **Orphan redemptions stay in `core.redemption_txn`** and show NULL member columns in the enriched view | Members can arrive later than their transactions | `R04`, `v_redemption_enriched` |

## Scope

- The Excel column "Individual or Corporate" (IND file) is outside the canonical layout and is not loaded.
- Agent, State and Is_Active are not present in the Excel extracts and stay empty for those members.
- Scheduling, streaming ingestion and access-control design are described in `docs/architecture.md` but are not implemented.
