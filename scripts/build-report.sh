#!/usr/bin/env bash
# Generate a self-contained HTML audit report for one repo.
#
# Usage:
#   build-report.sh                     # active repo
#   build-report.sh <slug>              # specific repo
#   build-report.sh --all               # one report per repo
#
# Output:
#   ${repo_dir}/reports/<UTC-timestamp>.html
#
# The report is self-contained (inline CSS, no external assets) and
# print-friendly, so a follow-up PDF / weasyprint render needs no
# additional template work.
set -euo pipefail
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/lib/state.sh"

_render_one_repo() {
  local slug="$1"
  local repo_dir="$AUTO_AUDIT_DATA/repos/$slug"
  [ -d "$repo_dir" ] || { err "no such repo: $slug"; return 1; }
  [ -f "$repo_dir/config.json" ] || { err "repo missing config.json: $slug"; return 1; }

  local out_dir="$repo_dir/reports"
  mkdir -p "$out_dir"
  local stamp; stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local out_file="$out_dir/${stamp}.html"

  local cfg_json iter_json findings_json
  cfg_json="$(cat "$repo_dir/config.json")"
  iter_json="[]"
  if [ -f "$repo_dir/iterations.jsonl" ]; then
    iter_json="$(jq -s '.' "$repo_dir/iterations.jsonl" 2>/dev/null || echo '[]')"
  fi
  findings_json="[]"
  if [ -d "$repo_dir/findings" ] && ls "$repo_dir/findings"/*.json >/dev/null 2>&1; then
    findings_json="$(jq -s '
      sort_by(
        ({"critical":0,"high":1,"medium":2,"low":3,"info":4}[.severity // "info"]) // 5,
        .id
      )' "$repo_dir/findings"/*.json)"
  fi

  jq -n -r \
    --argjson cfg "$cfg_json" \
    --argjson iter "$iter_json" \
    --argjson findings "$findings_json" \
    --arg generated_at "$(date -u +%FT%TZ)" \
    --arg slug "$slug" \
    '
    def h: (. // "") | tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;") | gsub("\u0027"; "&#39;");
    def code: (. // "") | tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
    def stat(s): [$findings[] | select(.status == s)] | length;
    def sev(v): [$findings[] | select(.severity == v)] | length;
    def pending: [$findings[] | select(.status as $s | ["discovered","triaging","confirmed","poc_writing","poc_written","fixing","fix_committed","pr_opened","reviewing","pr_approved","skipped","pr_rejected"] | index($s))] | length;
    def render_finding:
      "  <article class=\"finding\">\n" +
      "    <header>\n" +
      "      <span class=\"pill sev-\(.severity // "info" | h)\">\(.severity // "info" | h)</span>\n" +
      "      <span class=\"id\">\(.id | h)</span>\n" +
      "      <span class=\"status status-\(.status | h)\">\(.status | h)</span>\n" +
      "    </header>\n" +
      "    <h3>\(.title | h)</h3>\n" +
      "    <p class=\"loc\">\(.file | h):\(.line | tostring | h) — category <code>\(.category | h)</code></p>\n" +
      (if (.description // "") != "" then "    <div class=\"row\"><b>Description.</b> \(.description | h)</div>\n" else "" end) +
      (if (.code_snippet // "") != "" then "    <pre><code>\(.code_snippet | code)</code></pre>\n" else "" end) +
      (if (.triage.verdict // "") != "" then "    <div class=\"row\"><b>Triage:</b> \(.triage.verdict | h) — \(.triage.reasoning | h)</div>\n" else "" end) +
      (if (.poc.path // "") != "" then "    <div class=\"row\"><b>PoC:</b> <code>\(.poc.path | h)</code> (verified: \((.poc.verified // false) | tostring | h))</div>\n" else "" end) +
      (if (.fix.commit_sha // "") != "" then
        "    <div class=\"row\"><b>Fix:</b> branch <code>\(.fix.branch | h)</code>, commit <code>\(.fix.commit_sha[0:8] | h)</code>" +
        (if (.fix.test_status.status // "") == "skipped" then " — tests skipped (\(.fix.test_status.note // "" | h))" else "" end) +
        "</div>\n"
       else "" end) +
      (if (.pr.url // "") != "" then "    <div class=\"row pr-link\"><b>PR:</b> <a href=\"\(.pr.url | h)\">#\(.pr.number | tostring | h)</a></div>\n" else "" end) +
      (if (.review.verdict // "") != "" then "    <div class=\"row\"><b>Independent review:</b> \(.review.verdict | h) — \(.review.reasoning | h)</div>\n" else "" end) +
      "  </article>";
    def render_iteration:
      "    <div>\(.at | h) <b>\(.event | h)</b> \(.finding_id // "" | h) \(.note // "" | h)</div>";
    "<!DOCTYPE html>\n" +
    "<html lang=\"en\">\n" +
    "<head>\n" +
    "  <meta charset=\"utf-8\">\n" +
    "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n" +
    "  <title>auto-audit report — \($cfg.url | h)</title>\n" +
    "  <style>\n" +
    "    *{box-sizing:border-box}\n" +
    "    html{font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",system-ui,sans-serif;color:#1a1a1a;background:#fafafa;line-height:1.5}\n" +
    "    body{max-width:980px;margin:0 auto;padding:2.5rem 1.5rem 6rem;background:#fff}\n" +
    "    h1{font-size:1.65rem;margin:0 0 .25rem 0}\n" +
    "    h2{font-size:1.2rem;margin:2rem 0 .75rem;border-bottom:1px solid #e3e3e3;padding-bottom:.25rem}\n" +
    "    h3{font-size:1rem;margin:1.25rem 0 .25rem}\n" +
    "    .meta{color:#666;font-size:.9rem;margin-bottom:1.25rem}\n" +
    "    .meta a{color:#3050d0;text-decoration:none}\n" +
    "    .summary{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:.75rem;margin:1rem 0}\n" +
    "    .summary .card{padding:.75rem 1rem;border:1px solid #e3e3e3;border-radius:6px;background:#fbfbfb}\n" +
    "    .summary .label{font-size:.75rem;text-transform:uppercase;letter-spacing:.04em;color:#666}\n" +
    "    .summary .value{font-size:1.5rem;font-weight:600;margin-top:.15rem}\n" +
    "    .pill{display:inline-block;padding:.1rem .5rem;border-radius:999px;font-size:.7rem;font-weight:600;letter-spacing:.03em;text-transform:uppercase;vertical-align:middle}\n" +
    "    .sev-critical{background:#7a1e21;color:#fff}\n" +
    "    .sev-high{background:#c4342a;color:#fff}\n" +
    "    .sev-medium{background:#d97706;color:#fff}\n" +
    "    .sev-low{background:#5a8d3a;color:#fff}\n" +
    "    .sev-info{background:#5a6c8e;color:#fff}\n" +
    "    .status{display:inline-block;padding:.1rem .55rem;border-radius:4px;font-size:.75rem;font-weight:500;background:#eef0f4;color:#3a3a3a;margin-left:.4rem}\n" +
    "    .status-merged{background:#dcf2dc;color:#1f6b1f}\n" +
    "    .status-false_positive{background:#eef0f4;color:#5a5a5a}\n" +
    "    .status-failed{background:#fde2e2;color:#902020}\n" +
    "    .status-skipped{background:#fff3d6;color:#825c00}\n" +
    "    article.finding{border:1px solid #e3e3e3;border-radius:8px;padding:1.25rem 1.5rem;margin:1rem 0;background:#fff;page-break-inside:avoid}\n" +
    "    article.finding header{display:flex;flex-wrap:wrap;align-items:center;gap:.5rem;margin-bottom:.4rem}\n" +
    "    article.finding header .id{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.85rem;color:#666}\n" +
    "    article.finding h3{margin:0;font-size:1.05rem}\n" +
    "    article.finding .loc{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.8rem;color:#5a5a5a;margin:0 0 .75rem}\n" +
    "    pre{background:#f4f4f6;border:1px solid #e3e3e3;border-radius:6px;padding:.75rem 1rem;overflow-x:auto;font-size:.82rem;line-height:1.45}\n" +
    "    .row{margin:.6rem 0;font-size:.92rem}\n" +
    "    .row b{color:#3a3a3a;font-weight:600}\n" +
    "    .timeline{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.78rem;color:#5a5a5a;background:#fbfbfb;border:1px solid #e3e3e3;border-radius:6px;padding:.5rem .75rem;margin:.5rem 0;max-height:360px;overflow-y:auto}\n" +
    "    .timeline div{padding:.1rem 0}\n" +
    "    .timeline b{color:#3a3a3a}\n" +
    "    .pr-link a{color:#3050d0;text-decoration:none}\n" +
    "    .pr-link a:hover{text-decoration:underline}\n" +
    "    footer{margin-top:3rem;padding-top:1rem;border-top:1px solid #e3e3e3;color:#888;font-size:.8rem}\n" +
    "    @media print{body{padding:1rem}article.finding{break-inside:avoid;page-break-inside:avoid}h2{page-break-after:avoid}}\n" +
    "  </style>\n" +
    "</head>\n" +
    "<body>\n" +
    "  <h1>auto-audit report</h1>\n" +
    "  <div class=\"meta\">\n" +
    "    Repo: <a href=\"\($cfg.url | h)\">\($cfg.url | h)</a>\n" +
    "    · Slug: <code>\($slug | h)</code>\n" +
    "    · Modules: \($cfg.modules | join(", ") | h)\n" +
    "    · Merge policy: <code>\($cfg.merge_policy | h)</code>\n" +
    "    · Generated: \($generated_at | h)\n" +
    "  </div>\n" +
    "  <h2>Summary</h2>\n" +
    "  <div class=\"summary\">\n" +
    "    <div class=\"card\"><div class=\"label\">Total</div><div class=\"value\">\($findings | length)</div></div>\n" +
    "    <div class=\"card\"><div class=\"label\">Merged</div><div class=\"value\">\(stat("merged"))</div></div>\n" +
    "    <div class=\"card\"><div class=\"label\">False positive</div><div class=\"value\">\(stat("false_positive"))</div></div>\n" +
    "    <div class=\"card\"><div class=\"label\">Failed</div><div class=\"value\">\(stat("failed"))</div></div>\n" +
    "    <div class=\"card\"><div class=\"label\">Pending</div><div class=\"value\">\(pending)</div></div>\n" +
    "    <div class=\"card\"><div class=\"label\">Critical / High / Medium / Low</div><div class=\"value\" style=\"font-size:1.05rem\">\(sev("critical")) / \(sev("high")) / \(sev("medium")) / \(sev("low"))</div></div>\n" +
    "  </div>\n" +
    "  <h2>Findings</h2>\n" +
    (if ($findings | length) == 0 then "  <p>No findings yet.</p>\n" else ([$findings[] | render_finding] | join("\n")) + "\n" end) +
    "  <h2>Activity log</h2>\n" +
    "  <div class=\"timeline\">\n" +
    (if ($iter | length) == 0 then "    <div>(none yet)</div>\n" else ([$iter[] | render_iteration] | join("\n")) + "\n" end) +
    "  </div>\n" +
    "  <footer>\n" +
    "    <p>Generated by <a href=\"https://auto-audit.hesketh.pro\">auto-audit</a>. Each merged finding has gone through an independent-review checkpoint — the diff in the PR was written by one agent and approved by a separate, independent agent that had no visibility into the fixer''s reasoning.</p>\n" +
    "  </footer>\n" +
    "</body>\n" +
    "</html>\n"
    ' > "$out_file"

  log "wrote report: $out_file"
  printf '%s\n' "$out_file"
}

main() {
  if [ "${1:-}" = "--all" ]; then
    [ -d "$AUTO_AUDIT_DATA/repos" ] || { err "no repos initialised"; exit 1; }
    for d in "$AUTO_AUDIT_DATA"/repos/*/; do
      _render_one_repo "$(basename "$d")" || true
    done
    return 0
  fi
  local slug="${1:-}"
  if [ -z "$slug" ]; then
    slug="$(active_slug)" || exit 1
  fi
  _render_one_repo "$slug"
}

main "$@"
