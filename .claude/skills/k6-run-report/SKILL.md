---
name: k6-run-report
description: Render k6 summary JSON files (the run-<epoch>-summary.json files that k6/concurrent-transfers.js writes via handleSummary, usually in runs/) into an HTML report page published as an Artifact, optionally compared against a baseline run. Use this whenever the user wants to see, render, visualize, chart, share or write up a k6 run or load-test result, compare two or more k6 runs, or asks what changed between runs and would benefit from a page, even if they don't say "HTML" or "report".
---

# k6 run report

Turns a k6 summary export into one self-contained report page: verdict pills, headline numbers, latency strips, an optional side-by-side comparison with a baseline run, request and connection timings, thresholds and checks, and short notes on how to read the run. Both runs' JSON is embedded in the page, so the numbers on it always come straight from the files.

The bundled script does the rendering. Your job is to pick the right inputs, add the context only you can find (what changed between runs, what the logs say), and publish.

## Inputs

- **Run file**: a JSON object with a `metrics` key, as written by `handleSummary` (`SUMMARY_FILE`). In this repo they usually sit in `runs/` and are named `run-<unix seconds>-summary.json`. The number in the name is when the run started.
- **Baseline file (optional)**: another run to compare against. Use one when the user names two runs, says "compare", or asks about the impact of a change. If they don't say which is the baseline, take the older run (smaller number) as the baseline and the newer as the run being reported, and say so in your reply.
- **Labels**: a short name for each run's configuration, such as `SERIALIZABLE` or `READ_COMMITTED + FOR UPDATE`. Take them from the user's words first. Otherwise look at `git log` around the run times, since a commit made between two runs is usually the change under test. If you still can't tell, use neutral labels such as the run numbers rather than guessing.

## Steps

1. **Find the files.** List `runs/` (and the repo root, where older runs were written) to resolve the names the user gave. Check that each file parses and has `metrics`. The script exits with a clear message if not.

2. **Gather context, only where it is cheap and relevant.** Good sources:
   - `git log` and `git show <commit>` for what changed between the runs.
   - `k6/concurrent-transfers.js` and `k6/lib/api.js` for what the test does: senders, retries, backoff.
   - App logs (`kubectl -n concurrent-transactions logs <app pod> --since=...`), when the run had failures or retries and the pods are still from that run. Pods restart on deploy, so check their age against the run time first.

   Turn what you learn into a short `--context` paragraph and, where it explains a number, a note. Skip this step when the user just wants the numbers shown.

3. **Write notes (optional)** to a JSON file in the scratchpad:
   ```json
   [
     {"title": "All rejections were write conflicts on Charlie's account",
      "body": "The app logs show 103 errors, all <code>could not serialize access due to concurrent update</code> from <code>AccountDao.deposit</code>.",
      "source": "from the app pod logs, not from the k6 report"}
   ]
   ```
   Every note needs a `source` that says where the claim comes from. Readers will trust the page because its numbers come from the JSON, so anything that doesn't (logs, code reading, inference) must say so. The page already adds notes it can compute itself: whether every transfer and check succeeded, and, with a baseline, whether the slowdown is explained by retries. Don't repeat those. Keep each note to two or three sentences. `title` and `body` accept inline HTML such as `<code>`, so escape any `<` that comes from logs.

4. **Build the page** into the scratchpad directory, not the repo:
   ```bash
   python3 .claude/skills/k6-run-report/scripts/build_report.py runs/run-1795455726-summary.json \
     --label "SERIALIZABLE" \
     --baseline runs/run-1795454813-summary.json --baseline-label "READ_COMMITTED + FOR UPDATE" \
     --context 'Alice, Bob and Dan each send 500 transfers of $1 to Charlie. This run uses <code>SERIALIZABLE</code> isolation with no row locks (commit <code>6b0b52b</code>).' \
     --notes "$SCRATCH/notes.json" \
     --out "$SCRATCH/k6-report-1795455726.html"
   ```
   Run it from the repo root, or give it absolute paths. The title defaults to `<label> run <number>`; pass `--title` only for something better. The script prints the key numbers of each run, so you can write your reply without parsing the JSON again.

5. **Publish with the Artifact tool**, following that tool's own rules (call its quickstart first if it asks for one, then publish this file as a plain page with `icon: "chart"` and a one-sentence `description`). The template already meets the page contract: title, theme tokens for light and dark, phone-width layout. To update a report later in the same conversation, rebuild to the same `--out` path and publish that path again, so the link stays the same.

6. **Reply** with the link and a few sentences on what the report shows: the verdict, the biggest change against the baseline, and anything in the notes that didn't come from the JSON. Say if you couldn't preview the page.

## Several runs

The page compares exactly two runs. For a series (for example, the same test at 1, 5 and 20 VUs), build one page per run against the same baseline, or ask the user which pair matters most. Don't merge runs into one file.

## When something is missing

The template skips what a run doesn't have: no baseline hides the comparison table, custom metrics such as `transfer_retries` count as zero when absent, and a run without thresholds or checks says so. If the export comes from a different k6 script whose metrics don't match (no `transfers_succeeded`, for example), the transfer-specific tiles will show zeros. Tell the user the report fits `k6/concurrent-transfers.js`, and offer to adapt the template rather than publishing misleading zeros.

## Editing the look

The page design lives in `assets/template.html`: CSS tokens at the top, rendering script at the bottom. The script substitutes four placeholders, `__TITLE__`, `__RUN__`, `__BASE__` and `__META__`. Keep all four if you change the template.
