# Source Data and Specification Issues

This document captures inconsistencies identified in the SkyPoints assessment inputs and the handling proposed in the current implementation. It distinguishes observed source characteristics from assumptions that still need confirmation.

## 1. Country workbook inconsistencies

The three workbooks do not share a common schema.

| Country workbook | Observed columns / characteristics | Proposed treatment |
|---|---|---|
| IND | `ID`, `Name`, `DOB`, `TierCode`, `EnrollmentDate`, `Individual or Corporate`, `Flight Date`; dates include Excel serial values; no country column | Map using country-specific config; supply country as IND; normalise dates; do not currently load Individual/Corporate |
| USA | `ID`, `Name`, `TierCode`, `EnrollmentDate`, `FlightDate`; DOB is absent; compact numeric dates lose leading zero | Set country to USA; parse compact dates as MMDDYYYY; leave DOB and age NULL |
| AUS | `Unique ID`, `Member Name`, `Tier Type`, `Date of Birth`, `Date of Enrollment`, `Date of Flight`; DOB can be literal `NULL`; enrollment includes invalid `2021-13-13`; mixed ISO and serial dates | Map alternate column names; treat NULL as missing; preserve invalid date text for DQ; parse supported serial/ISO formats |

### 1.1 Repeated IDs across workbooks

The values 1, 2, and 3 occur in all three workbooks but represent different people.

**Risk:** Treating the raw numeric value as a global member key can merge unrelated people.

**Proposed handling:** The Python normalizer prefixes workbook IDs with the country code (`IND-`, `USA-`, `AUS-`). The relationship to unprefixed IDs in the member flat files and redemption feed remains unresolved and requires a crosswalk or an explicit business rule before joining those sources.

### 1.2 Date representation and ambiguity

- Excel serial dates need conversion using the Excel date epoch.
- USA compact date values can lose a leading zero. For example, `6152022` is interpreted as 2022-06-15, and `1052022` as 2022-01-05, under the MMDDYYYY assumption.
- AUS contains mixed serial and ISO date representations.
- The value `2021-13-13` is not a valid calendar date.
- A DOB such as `03051985` is ambiguous unless the source-country format is specified.

**Impact:** Incorrect parsing can create plausible but wrong enrollment, flight, or DOB dates, affecting age, stale-member status, and chronology checks.

**Proposed handling:** Apply country-specific parsing; pass unparseable non-null date strings through the Python layer for explicit SQL DQ rejection; do not silently coerce a malformed value to a different valid date.

## 2. Specification and sample-layout inconsistencies

| Issue | Observation | Risk / proposed response |
|---|---|---|
| Column count | The specification lists 11 attributes including Post Code, while the sample layout has 10 and does not show Post Code | Confirm the authoritative file contract. Current normalizer/load does not populate Post Code. |
| Primary key | Member_Name is marked as a key, while Member_Id is not clearly marked | Member names are not reliably unique. Treat Member_Id as the proposed key, subject to owner confirmation. |
| Post Code type | Post Code is specified as INT(5) | Numeric typing loses leading zeros and cannot represent alphanumeric postal codes. Use VARCHAR if required; proposed width is VARCHAR(10), subject to country requirements. |
| Identifier length | Sample IDs have inconsistent lengths | Keep IDs as VARCHAR and validate expected shape without truncating or padding until the owner defines the rule. |
| Country values | Examples include `AU` and `PHIL`, while curated data uses canonical country codes | Map documented aliases (AU->AUS, PHIL->PHL, US->USA); reject unknown codes for review. |
| DOB representation | Values such as `03051985` are ambiguous without a country format | Parse under an explicit source-country convention; do not infer from digits alone. |
| Extra workbook field | IND includes `Individual or Corporate`, absent from the current canonical layout | Do not silently discard a required business attribute; confirm whether it must be retained. |

## 3. Flat-file mapping and row-shape concerns

### 3.1 Leading delimiter

The pipe-delimited sample begins with a leading delimiter. This means the first parsed field is empty and the record values begin at the next positional field.

**Risk:** A projection that assumes the first source field contains the record type can shift every mapped value into the wrong target column.

**Proposed handling:** The current `sql/03_load_raw.sql` projection explicitly maps from positional field `$2`. Retain a delimiter-count/row-shape check so malformed records do not silently shift columns.

### 3.2 Missing source attributes

The workbook normalizer currently writes empty values for agent, state, and active status because these columns are not present in the workbook mappings. It also does not populate Post_Code.

**Risk:** Empty target values may be mistaken for a source-system null when the field was never provided by that source.

**Proposed handling:** Distinguish source-not-provided from source-provided-but-null where the downstream contract requires it. Do not fabricate values to make a target row appear complete.

## 4. Staging mapping loss: Agent_Name

The staging sample reportedly has blank `Agent_Name` for four of five rows, while the source sample contains `Sam` for all five.

**Likely issue:** The source-to-target mapping or positional load has dropped the agent value.

**Impact:** Downstream reporting and auditability lose agent attribution. A non-null rule alone can flag the symptom, but cannot identify where the mapping failed.

**Proposed handling:**
- Map `Agent_Name` explicitly in the canonical file layout.
- Add a warning or error rule depending on the source contract.
- Add column-level source-to-target reconciliation for agent, country, member ID, and other critical fields.
- Do not treat a matching row count as proof that every column was mapped correctly.

Note that the current Excel normalizer intentionally writes an empty agent field because the workbook sources do not supply agent data. The staging-sample discrepancy relates to the separate flat-file/staging example and should be traced independently.

## 5. County, FLAG, and active-status naming

The staging specification reportedly uses `County`, while the expected business attribute appears to be `Country`. The source has a `FLAG` field, while the target names an `Is_Active` field.

**Risk:** A positional or guessed mapping can place unrelated values into country or active status.

**Proposed handling:** Correct the apparent County typo only after confirming the intended field; do not equate FLAG and Is_Active without an approved mapping and accepted-value domain.

## 6. Redemption feed concerns

The working sample describes NDJSON documents with a nested `redemptions` array. The sample includes:
- A normal member with two transactions, one `COMPLETED` and one `PENDING`.
- A member ID (`999999`) that does not appear in the member sample.
- A transaction with `miles_redeemed = -50`.
- A transaction whose partner is `SkyPoints`.

| Issue | Proposed rule / response |
|---|---|
| Null or duplicate transaction ID | Require non-null `txn_id`; deduplicate deterministically before transaction upsert. |
| Non-positive miles | Flag null, zero, and negative miles as DQ violations. |
| Unknown status | Validate against an approved status domain; COMPLETED and PENDING are sample accepted values, not necessarily the complete domain. |
| Invalid transaction date or date later than feed date | Flag as a transaction-date violation. |
| Member ID absent from current member data | Flag as an orphan and retain for investigation rather than silently dropping it. |
| Partner equals SkyPoints | Flag as a warning pending confirmation; it may be a programme label rather than an external partner. |
| Member identifier format mismatch | Confirm whether redemption IDs are expected to match unprefixed flat-file IDs or namespaced workbook IDs, and define a crosswalk if necessary. |

The repository currently creates a raw redemption VARIANT table and a core transaction table in DDL, but does not yet include a redemption file-format/load/FLATTEN script or transaction DQ implementation.

## 7. Proposed validation catalogue

The following catalogue captures intended checks. Confirm severity and accepted domains with the assessment owner.

### 7.1 Member feed

| Code | Severity | Validation | Issue exposed |
|---|---|---|---|
| E01 | ERROR | Member name is present | Missing name |
| E02 | ERROR | Member ID is present | Missing ID |
| E03 | ERROR | Member ID contains only allowed characters and is within maximum length | Malformed ID |
| E04 | ERROR | Enrollment date is present | Missing enrollment date |
| E05 | ERROR | Enrollment date parses | Invalid enrollment date |
| E06 | ERROR | Supplied last-flight date parses | Invalid flight date |
| E07 | ERROR | Supplied DOB parses using configured country format | Invalid DOB |
| E08 | ERROR | Country maps to a configured canonical country | Unknown/unmapped country |
| E09 | ERROR | Last flight is not before enrollment | Chronologically inconsistent dates |
| E10 | ERROR | Enrollment and last-flight dates are not in the future relative to as_of_date | Future-dated record |
| E11 | ERROR | DOB is before enrollment | Impossible chronology |
| E12 | ERROR | Duplicate row is not a superseded loser within the feed | Duplicate key |
| W01 | WARN | Numeric member ID meets expected length convention | Short legacy ID |
| W02 | WARN | Tier belongs to configured tier domain | Unknown tier |
| W03 | WARN | Active flag is in accepted domain | Invalid active flag |
| W04 | WARN | Agent name is present where required | Agent mapping loss |
| W05 | WARN | Postal code has acceptable country-aware shape | Invalid postal code |
| W06 | WARN | Age is between 0 and 120 when DOB is supplied | Implausible age |

### 7.2 Redemption feed

| Code | Severity | Validation |
|---|---|---|
| R01 | ERROR | miles_redeemed is not null and greater than zero |
| R02 | ERROR | Status belongs to the approved status domain |
| R03 | ERROR | Transaction date parses and is not later than feed date |
| R04 | ERROR | Member exists in current member routing/profile data |
| R05 | WARN | Partner is not the special SkyPoints value, pending business confirmation |

Assessment notes do not fully define whether redemption violations must be rejected into a dedicated table or retained in a violations view. Choose and document one consistent disposition before implementation.

## 8. Batch-level controls recommended

1. **Row reconciliation:** raw detail rows = accepted staging rows + rejected rows.
2. **Row-shape validation:** check field/delimiter count before positional parsing.
3. **Column-level reconciliation:** compare key source and target values, especially agent, country, and member ID.
4. **Duplicate control:** one winning member row per member per feed; no member present in multiple country tables.
5. **Country-move test:** verify the day-2 Ravi fixture moves from India to Australia and is no longer present in India's current table.
6. **Idempotency test:** rerun the same feed and confirm curated state does not change.
7. **Boundary tests:** stale-member checks at 90 and 91 days; age calculation around the birthday boundary.
8. **Redemption reconciliation:** compare flattened transaction count with the expected count of elements in all redemptions arrays, accounting for rejected transactions.

## 9. Open questions for the data owner

- Confirm Member_Id as the business key and define its relationship across workbook, flat-file, and redemption feeds.
- Confirm per-country DOB conventions, particularly ambiguous compact values.
- Confirm whether Post_Code is part of the final feed and define country-specific accepted formats.
- Confirm the source meaning and mapping of County, FLAG, and Is_Active.
- Confirm whether Agent_Name is mandatory and from which source it should be populated.
- Confirm the complete tier and redemption status domains.
- Confirm whether SkyPoints is a valid redemption partner value.
- Confirm treatment of duplicate member records and transaction corrections.
- Confirm whether source data can be committed to a public GitHub repository.
