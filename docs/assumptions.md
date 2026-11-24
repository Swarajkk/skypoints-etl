# Assumptions and Design Decisions

This document records the working assumptions used to build the SkyPoints assessment. They make the implementation deterministic where the input files or specification are ambiguous. They are not a substitute for confirmation from the source-system or business owner.

## 1. Member identity and keys

1. **Workbook IDs are namespaced by source country.** IND, USA, and AUS workbooks contain repeated numeric IDs that identify different people. The Python normalizer therefore prefixes workbook IDs with `IND-`, `USA-`, or `AUS-`.
2. **The canonical member identifier is treated as a string.** It must preserve leading zeros and may contain a country prefix. Numeric data types are not appropriate for identifiers.
3. **Namespaced workbook IDs are not assumed to equal IDs in the pipe-delimited member or redemption feeds.** A source-to-target crosswalk or a confirmed common identifier convention is required before joining these datasets.
4. **The proposed member business key is `Member_Id`.** The assessment specification's use of `Member_Name` as a key is treated as a specification defect because names are not reliably unique or immutable.
5. **Country changes do not create a new person.** The planned curated model maintains one current country assignment for a member, while raw history is retained.

## 2. Country and source mappings

6. **Canonical country values use three-character codes** in the curated model: IND, USA, AUS, CAN, and PHL are seeded in the reference country table.
7. **Known source aliases are mapped explicitly:** `AU -> AUS`, `US -> USA`, and `PHIL -> PHL`.
8. **Unknown country codes are not guessed.** They fail the proposed country validation and should be rejected or quarantined for mapping review.
9. **Workbook configuration is externalised** in `config/country_sources.yaml`, including worksheet name, ID prefix, source-column mapping, compact-date format, and DOB output format.
10. **Workbook columns absent from a source are not fabricated.** For example, USA has no DOB. Missing DOB and derived age remain NULL. Agent, state, and active status remain blank because the workbook normalizer has no source columns for them.

## 3. Date interpretation and derived attributes

11. **Excel serial dates use the Excel 1900-system epoch adjustment** represented by 1899-12-30 in the Python normalizer.
12. **USA compact dates are interpreted as MMDDYYYY.** The configuration handles lost leading zeros by padding seven-digit values to eight digits before parsing; for example, `6152022` means 2022-06-15 and `1052022` means 2022-01-05.
13. **IND and AUS DOB values are emitted as DDMMYYYY** in the current country configuration.
14. **ISO-formatted dates are parsed as year-month-day.** Impossible dates such as `2021-13-13` are passed through unchanged by the normalizer so that the SQL layer can flag them.
15. **Unparseable non-null date strings are not silently converted to NULL or a fabricated date.** They should remain visible for DQ handling.
16. **Age is calculated relative to the configured `as_of_date`,** with the birthday boundary accounted for. It is not calculated from the machine's current date.
17. **A member is stale when the last flight is more than 90 calendar days before `as_of_date`.** The current staging view uses a strict greater-than-90 comparison; exactly 90 days is not stale.
18. **A missing last-flight date produces an unknown/NULL stale result,** not a false assertion that the member is active or stale.

## 4. Canonical layout and fields

19. **The canonical pipe-delimited detail record follows the field order in the Python normalizer header:** record type, member name, member ID, enrollment date, last-flight date, tier code, agent name, state, country, DOB, and active flag.
20. **Fields absent from a workbook are left empty.** No agent, state, active flag, or postcode is invented.
21. **The assessment sample layout has 10 data attributes after the record-type marker and does not include Post_Code,** although the broader specification lists it. The current load does not populate Post_Code from the workbook.
22. **The `Individual or Corporate` workbook field is not included in the current canonical member model.** Add it only after confirming that it is required downstream.
23. **The staging typo `County` is interpreted as a likely reference to `Country`,** but the mapping should be explicit rather than silently treating arbitrary similarly named fields as equivalent.
24. **`FLAG` is not assumed to mean `Is_Active`.** That mapping requires confirmation from the source owner.

## 5. Data-quality severity and disposition

25. **ERROR rules reject the member row.** Raw values, source file, feed date, and error codes should be retained for investigation and replay.
26. **WARNING rules do not block staging.** Warning codes are retained alongside accepted rows.
27. **Proposed member errors include:** missing name or ID, missing/unparseable enrollment date, unparseable supplied flight date or DOB, unmapped country, invalid date chronology, future dates, and duplicate/superseded member rows.
28. **Proposed member warnings include:** short numeric IDs, unknown tier, invalid active flag, missing agent, malformed postal code, and implausible age. The business owner should confirm which are truly non-blocking.
29. **Every raw detail row should be accounted for as either accepted staging data or a rejected record.** A reconciliation gap is a pipeline failure, not a record to ignore.
30. **Duplicates within a feed are resolved deterministically.** The current staging view ranks same-member/same-feed rows by last-flight date and file row number. The full cross-feed latest-record-wins policy still needs to be implemented and tested.

## 6. Redemptions

31. **The redemption feed is NDJSON.** Each line is an independent JSON document with a member identifier and a nested `redemptions` array.
32. **`txn_id` is treated as the transaction key.** Duplicate transactions should be resolved by newest feed date and then load timestamp; replay should not create duplicate transactions.
33. **Equal or newer feed dates may update an existing transaction.** Older feed versions must not overwrite newer transaction state.
34. **The sample statuses `COMPLETED` and `PENDING` are treated as examples of accepted values.** The complete status domain must be confirmed.
35. **Miles redeemed must be positive.** Null, zero, and negative values should be treated as DQ violations.
36. **Transaction date must parse and must not be later than feed date.**
37. **Orphan member references are not silently dropped.** A redemption member ID not found in the current member profile should be retained for investigation and flagged.
38. **Partner value `SkyPoints` is a warning pending business confirmation.** It may refer to the loyalty programme itself rather than an external partner; it should not be declared invalid without clarification.

## 7. Processing and operations

39. **Run dates are explicit inputs.** The assessment SQL uses `ref.run_config` for `as_of_date` and `feed_date`; views should not depend on implicit session dates.
40. **Raw data is retained for traceability and replay.** Preserve source filename, source row number, feed date, and load timestamp wherever available.
41. **Loads and transformations should be idempotent.** Re-running the same feed should not duplicate members or transactions or change the final result unexpectedly.
42. **DDL should be completed before a DML transaction for member movement.** Snowflake DDL can implicitly commit, so create required country-specific tables before beginning a transactional move.
43. **The assessment-scale implementation is a functional demonstration, not a measured high-volume benchmark.** Snowpipe, Streams, Tasks, clustering, file sizing, and warehouse isolation are production design options that require workload testing.
44. **The current code status must be stated accurately.** Normalization, raw landing setup, and typed member staging are present in the repository; country routing, full latest-record-wins curation, and redemption flattening remain planned until implemented and tested.

## 8. Items requiring confirmation

- Is `Member_Id` the formally approved unique member key?
- What is the authoritative relationship between workbook IDs and flat-file/redemption IDs?
- Are DOB formats by country correct for all source systems and records?
- Should duplicate member rows be rejected, or should only the losing duplicate be ignored with an audit warning?
- Is `SkyPoints` a valid redemption partner value?
- What are all permitted redemption statuses and tier codes?
- Should `Post_Code` be included in a revised source-file contract, and what formats are valid?
- Should `Individual or Corporate` be retained in the canonical model?
- What is the authoritative mapping for `County`, `FLAG`, and `Is_Active`?
- Are the supplied sample datasets permitted in a public GitHub repository?

Revisit these assumptions when the data owner or assessor clarifies the source contract.
