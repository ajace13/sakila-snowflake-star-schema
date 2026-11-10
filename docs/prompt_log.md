# Prompt log

**PROMPT — Aidan → Claude Code (the Dashboard task: "Claude explains; Snowflake decides"; Claude Code = CHECKER, subagents = EXPLAINER and REVIEWER)**
Read CLAUDE.md first. Use the Snowflake connection already configured. Never print, log or write account identifiers, usernames, keys, tokens or connection strings. You (main agent) are the CHECKER; spawn a separate subagent as "CLAUDE (explainer)"; do not fill in the Y/N column, accept/reject decisions or the "where Claude was wrong" note; Tasks 1–5 (explain a plan, explain a difference, review, document, prompt log and tool log); output docs/ai_verification.md ending in a TO DECIDE checklist; show the plan before running anything that changes data or creates objects.

**ANSWER** Read CLAUDE.md; gathered the read-only evidence; showed the plan and asked four questions before changing anything; ran Tasks 1–5; wrote docs/ai_verification.md with the tables and the TO DECIDE checklist (none of the Y/N, accept/reject or "where Claude was wrong" cells filled in).

**PROMPT — checker → explainer #1 (no tools; given only the text of the slowest app query and its GET_QUERY_OPERATOR_STATS output)**
Name the most expensive operator and why, say what the plan does, whether the date filter does useful work, whether the join or aggregate is a problem, and how much of the 973 ms is compilation versus execution. Short numbered, falsifiable claims.

**ANSWER** Said no single operator stands out (the two TableScans tie at 0.25, remote disk I/O; join and aggregate 0.0), no pruning (1 of 1 partition), and could not attribute 113 ms of the 973 ms. Snowflake: those 113 ms are QUEUED_PROVISIONING_TIME.

**PROMPT — checker → explainer #2 (no tools; given the normalized and star revenue-by-store queries and their results, and column names only)**
Why do A and B differ, which is right, what do they have in common, what single query decides, and what would B look like under A's definition?

**ANSWER** Said they use different keys for "store" and neither is wrong; totals are identical; proposed a three-way query; guessed the star's store is "the store that took the payment". Snowflake: the star's store is the store holding the rented copy, and the staff-store totals do not match.

** PROMPT — checker → grain-reviewer subagent (reads files only)**
Review the fact and SCD2 DDL in sql/04_dw_ddl.sql against sql/01: grain, keys, additivity, double counting, Snowflake specifics; ranked concrete findings with line numbers and fixes.

**ANSWER** Three findings: unenforced Type 2 uniqueness could double-count; the two facts resolve customer_key at different dates and joining them multiplies rows; CREATE TABLE IF NOT EXISTS turns DDL edits into silent no-ops. Its line numbers all checked out; two of its asides were slips ("326" rentals, a hedged guess about NULL rental_id).

** PROMPT — Aidan → Claude Code (reply to the plan questions)**
Chose: drop the redundant date filter at full range as the one Task 1b change; run the headless claude -p command as written; redact my login name from docs/prompt_log.md; leave the "customer or staff" wording alone for now.

**ANSWER** Did all four. The redaction replaced 3 occurrences in docs/prompt_log.md only; the wording in sql/04 and docs/dimensional_model.md was left untouched.

** PROMPT — checker → explainer #3 (no tools; given the before and after queries and the earlier plan statistics, no results)**
Predict with numbers: will the two queries return identical results, BYTES_SCANNED before and after, TOTAL_ELAPSED_TIME before and after, which operator disappears, and does it depend on the cache?

**ANSWER** Predicted identical results, about 196,624 bytes before and about 160,000 (131,000–196,624) after, a difference under 50 ms, and the Filter operator missing after. Snowflake: results identical; bytes 239,616 before and after; no Filter operator in either plan; elapsed difference not reproducible.

** PROMPT — headless: claude -p (run exactly as written by Claude Code)**
claude -p "Write docs/data_dictionary.md for every DW table from INFORMATION_SCHEMA; cite the query for each fact."

**ANSWER** Exit code 0 but wrote nothing: both file writes (docs/data_dictionary.md and docs/prompt_log.md) were blocked by permissions. It documented CLASSICMODELS.DW (5 tables, 35 columns), not SAKILA.DW. Three of its printed claims were checked against INFORMATION_SCHEMA and all hold.

**PROMPT — Aidan → Claude Code** (added later: logged at the end of this exchange)
I just resumed the session: give a status update and where we are in the general plan; verify the work done so far and report progress; then we fix things or move to Reflection.

**ANSWER** Verified live: connection and warehouse (AUTO_SUSPEND 60); no file changed since my last write; the whole notebook re-executed to a scratch copy with 0 errors (Migration counts, controls, keys and foreign keys; Dimensional model and Business questions live checks; file inventory); sql/06 gave 57 OK / 0 FAIL; sql/05 re-run inserted and updated nothing; the Streamlit headless test was identical to the saved log; AI verification file has 41 TO DECIDE cells and none filled in; identifier scan 0 hits in 84 files. Found the scratchpad had been wiped on resume (my builders and scanner; the project's evidence is intact). Listed the open items and asked for the Reflection text.

**PROMPT — Aidan → Claude Code** (added later: logged while the exchange was in progress)
I ran the Streamlit app in Snowflake, so check on that if possible. Now go through the calls from AI verification: ask me the Y/N and accept/reject questions here in the terminal and make the edits in place as we go. Don't worry about security or the Cloud SQL instance; I will prompt Reflection next.

**ANSWER** Checked the Snowflake side: 27 queries from one OAuth session (Linux, Python 3.11, i.e. the Streamlit-in-Snowflake runtime, not my key-pair/Python 3.12 local runs), all succeeded, across the unfiltered view and two filtered ranges, each with the Check queries; ranges with no payments stop after the KPI query as designed; the star and normalized answers match for the three ranges used (67,406.56 / 65,534.57 / 21,252.85). The rendered page and the screenshot cannot be seen from Snowflake. The query analysed in AI verification was one of this run's. Then asked the AI verification questions in batches and wrote my answers into docs/ai_verification.md (see the Decisions section there).

**PROMPT — headless: claude -p (second run, approved by me)**
claude -p "Write docs/data_dictionary.md for every table in the SAKILA.DW schema (the Sakila star schema; ignore CLASSICMODELS.DW) from INFORMATION_SCHEMA; cite the query for each fact." --allowedTools "Edit(docs/data_dictionary.md)"

**ANSWER** Wrote docs/data_dictionary.md (7 tables, 84 columns, 22 constraints, queries Q1–Q6, the right schema this time). It could not log in docs/prompt_log.md (not allowed; the file's checksum is unchanged), so this entry was written by Claude Code. The first attempt used `Write(...)` in the flag, which this version rejects (my mistake); the second used `Edit(...)`. Three claims were tested against INFORMATION_SCHEMA and all three were marked correct by me.

**PROMPT — Aidan → Claude Code** (my answers to the AI verification questions, given in the terminal; logged afterwards)
Tick-box answers for every claim, accept for the three findings, approval of the three judgement calls, four edits (fix the "customer or staff" wording, a note on the Snowflake run in 1a, redact the tool log, re-run the dictionary), the candidates for where Claude was wrong, plus a note on 1b claim 5, a note on Task 4 claim 1 and an added candidate (explainer #2's claim about the store).

**ANSWER** Recorded in docs/ai_verification.md: 41 Y/N cells (32 Y, 9 N), 3 Accept, nothing left open; made the four edits; recorded the five candidates under Decisions.

**PROMPT — Aidan → Claude Code**
Audit the whole project against the project requirements before submission (read-only on Snowflake, no edits until approved; do not change AI verification verdicts or write Reflection; screenshots are mine); then apply the approved fixes and rebuild the PDF.

**ANSWER** Re-ran the Snowflake counts (16/16 tables, 47,268 rows, 17 control totals, sql/06 57 OK) and checked the app, the dictionary and the Business questions figures against Snowflake. Found the agent session had ACCOUNTADMIN/SYSADMIN active and CLAUDE_RO could not read SAKILA.DW (no schema USAGE). Applied: CLAUDE.md for Sakila, sql/03 grants, AI verification heading and a role note, the stale "Streamlit in Snowflake not run" text, the 16,049/67,416.51 attribution, header comments of sql/07 and sql/08; built submission/ with the PDF.
