---
name: report
description: "Generate a self-contained HTML audit report for the active repo (or a named one). The report includes summary stats, per-finding triage / PoC / fix / review detail, and the full activity log. Use when the user says 'generate a report', 'export findings', 'build the audit summary', 'write up the audit'."
argument-hint: "[--all | <slug>]"
allowed-tools: "Bash"
---

## Generate the HTML report

Three forms:

- no args → report for the active repo
- `<slug>` → report for a specific repo (need not be active)
- `--all` → one report per repo this plugin has ever initialised

The script writes to `${repo_dir}/reports/<UTC-timestamp>.html` and emits the absolute path on stdout. Reports are self-contained (inline CSS, no external assets), print-friendly, and safe to share — finding-content fields are HTML-escaped.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/build-report.sh" "$@"
```

After the script returns:

1. Print the output path so the user can open it in a browser (`xdg-open`, `open`, or scp / serve from nginx).
2. If the user asked for a PDF / DOCX / PPTX format and the host has a converter installed, mention the follow-up command they can run:
   - PDF (any host with `weasyprint`): `weasyprint <html-path> <pdf-path>`
   - PDF (chromium-based): `chromium --headless --no-sandbox --print-to-pdf=<pdf-path> file://<html-path>`
   - DOCX (with `pandoc`): `pandoc -f html -t docx <html-path> -o <docx-path>`
   - PPTX (with `pandoc`): `pandoc -f html -t pptx <html-path> -o <pptx-path>`

Future releases of this plugin will wire the converter calls directly into the skill once the dependency choice is settled. For now the HTML is the canonical artefact.

## Notes

- The report only includes findings that exist in the data directory; it does not re-scan or re-triage. Run `/auto-audit:tick` until the queue is drained before generating a final report if you want the latest state.
- Reports are append-only — every invocation writes a fresh timestamped file. Old reports are kept; `ls ${repo_dir}/reports/` shows the history.
- The activity log section preserves the full iterations stream (one line per state transition). If a finding bounced between `confirmed` ↔ `pr_rejected` ↔ `confirmed` (a fixer retry), that history is visible.
