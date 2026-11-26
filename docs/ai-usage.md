# AI Usage Log

The assessment asks for intentional use of AI tools. This log records how I used an AI assistant (Claude) on this project: what I asked for, what I did not accept as-is, and how I checked the result. The rule I followed throughout: **nothing is committed until I have run it and checked the output against an expectation.**

## Workflow

1. Gave the assistant the assessment PDF and the three Excel files and asked for a data-profiling pass before any design.
2. Agreed the design and assumptions in prose first (`docs/assumptions.md`).
3. Built one script at a time, ran it in Snowflake, and compared the output with an expected value written down beforehand (for example 13 staged rows, one reject, per-country counts).
4. Committed after each step passed, so the Git history follows the real build order.

## Where AI helped

| Area | What the AI produced | How I verified it |
|---|---|---|
| Data profiling | A list of issues in the PDF sample and the three workbooks (serial dates, lost leading zeros, `NULL` text, an impossible date, mixed formats, repeated member IDs) | Opened every workbook and checked each finding; for example confirmed that IDs 1 to 3 repeat in all three files |
| Design | Layered RAW, STG, CORE and DQ approach; routing table for the "moved country" rule | Walked the day-2 scenario by hand before building it, then proved it in Snowflake |
| Python normalizer | Date parsing and Excel conversion, plus unit tests | Ran `pytest`; inspected the generated flat files line by line |
| SQL | Staging view with derived columns and rule arrays; split procedure; JSON flatten `MERGE`; quality views | Ran each file and checked counts and sample rows; added SQL assertion tests |
| Documentation and Git workflow | Drafts of the docs and the commit plan | Edited the docs to match what actually ran |

## Where I corrected or rejected AI output

| # | What went wrong or was changed | How it was found | Outcome |
|---|---|---|---|
| 1 | A staging view referred to session variables (`$as_of_date`). Snowflake views cannot read session variables | Caught in review before running | Replaced by a one-row `ref.run_config` table that the view joins |
| 2 | The normalizer first wrote DOB as `YYYYMMDD`, but the staging logic expects the country's source format | Traced a sample row end to end | The normalizer now writes DOB in `DDMMYYYY` or `MMDDYYYY` per country |
| 3 | The warning count for missing agents was stated as 9 | Counted the rows: one of the nine Excel members is rejected before staging | Corrected to 8 |
| 4 | The first split procedure used cursors and dynamic SQL, which was hard to read and hard to verify | Empty results from the unified view while debugging | Procedure rewritten with explicit statements, validation before any write, and rollback on error; verified with eight consistency queries |
| 5 | A `.gitignore` left empty and compiled `.pyc` files committed | `git status` and `git ls-files` | Ignore rules fixed and files untracked |
| 6 | Several multi-statement runs showed only the last result, which made correct runs look empty | Compared single-query results against the combined run | Verified one query at a time; documented that "no rows" is a pass for the SQL tests |

## Decisions I made myself

- Treating Member ID, not Member Name, as the key despite the specification (see `docs/assumptions.md`, A1).
- Namespacing the Excel member IDs so the three files do not collide (A2).
- Rejecting versus flagging: which problems block a row and which only warn (A20 to A24).
- Keeping the country tables explicit in the split procedure for auditability, and recording the trade-off (A19).

## What I would not delegate

- The expected results. I wrote down the numbers I expected before running each step, so the output was a test, not a demonstration.
- Business-rule calls with real consequences (rejecting redemptions, treating `SkyPoints` as a partner). These are flagged for confirmation, not decided silently.

## What's my take on this.

- A step where I disagreed with a suggestion and why: The first split procedure used cursors and dynamic SQL, and I found it hard to read and hard to verify. I replaced it with explicit statements for each country table, which validate before writing and roll back on error. I accepted less flexibility in exchange for something I could explain and audit line by line.
- A bug I found myself and how: The unified member view returned 0 rows even though the country tables held data. I ran each count separately, compared the tables, the routing table and the view, and inspected the view definition. That narrowed it down to the procedure, and I fixed it with the rewrite above. I then confirmed it with eight consistency queries.
- What I would change with more time: I'd make the country routing config-driven instead of hard-coded, and ingest with Snowpipe plus Streams and Tasks so each run processes only the new data. I'd also compute Age and Stale_Member in a view so they never go out of date.