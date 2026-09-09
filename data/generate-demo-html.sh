#!/usr/bin/env bash
# Generates informative index.html pages for MTC demo domains from the output
# of `cactus-cli cert text` and the log's `/landmarks` endpoint.
#
# Usage:
#   ./generate-demo-html.sh [domain ...]
#   If no domain arguments are given, generates pages for:
#     standalone.demo.mtcs.dev
#     relative.demo.mtcs.dev
#     landmark-relative.demo.mtcs.dev

set -euo pipefail

export PATH="/var/lib/toolbox/bin:$PATH"
CACTUS_CLI="${CACTUS_CLI:-cactus-cli}"
CERTS_DIR="${CERTS_DIR:-./certs/certificates}"
WWW_ROOT="${WWW_ROOT:-./www}"
LOG_URL="${LOG_URL:-http://localhost:14080/1}"

if [[ $# -eq 0 ]]; then
    DOMAINS=("standalone.demo.mtcs.dev" "relative.demo.mtcs.dev" "landmark-relative.demo.mtcs.dev")
else
    DOMAINS=("$@")
fi

# Fetch /landmarks once and parse into lines of: number tree_size prev_tree_size
LANDMARKS_RAW="$(curl -s "${LOG_URL}/landmarks" || true)"

find_covering_landmark() {
    local index="$1"
    if [[ -z "$LANDMARKS_RAW" ]]; then
        echo ""
        return
    fi

    # Parse landmarks list:
    # Line 1: <last> <num_active>
    # Line 2..(num_active+2): tree sizes in descending order from <last> down to <last - num_active>
    python3 -c '
import sys

lines = [l.strip() for l in sys.stdin.read().splitlines() if l.strip()]
if not lines:
    sys.exit(0)
hdr = lines[0].split()
if len(hdr) != 2:
    sys.exit(0)
last = int(hdr[0])
num_active = int(hdr[1])
sizes = [int(x) for x in lines[1:num_active+2]]

target = int(sys.argv[1])
# Walk from oldest to newest (reverse of sizes list)
for i in range(len(sizes) - 2, -1, -1):
    lm_num = last - i
    lm_size = sizes[i]
    prev_size = sizes[i + 1]
    if lm_size > target:
        print(f"{lm_num}|{prev_size}|{lm_size}")
        sys.exit(0)
' "$index" <<< "$LANDMARKS_RAW"
}

for domain in "${DOMAINS[@]}"; do
    cert_file="${CERTS_DIR}/${domain}-landmark-relative.pem"
    if [[ ! -f "$cert_file" ]]; then
        cert_file="${CERTS_DIR}/${domain}.crt"
    fi
    if [[ ! -f "$cert_file" ]]; then
        echo "==> warning: certificate file not found for ${domain} in ${CERTS_DIR}; skipping" >&2
        continue
    fi

    cert_text="$("$CACTUS_CLI" cert text "$cert_file")"

    # Extract fields from cactus-cli cert text output
    serial_line="$(grep -E '^[[:space:]]*serial:' <<< "$cert_text" | sed 's/^[[:space:]]*serial:[[:space:]]*//')"
    entry_index="$(sed -n 's/.*entry index \([0-9]*\).*/\1/p' <<< "$serial_line")"
    log_number="$(sed -n 's/.*log number \([0-9]*\).*/\1/p' <<< "$serial_line")"
    issuer="$(grep -E '^[[:space:]]*issuer:' <<< "$cert_text" | sed 's/^[[:space:]]*issuer:[[:space:]]*//')"
    not_before="$(grep -E '^[[:space:]]*not before:' <<< "$cert_text" | sed 's/^[[:space:]]*not before:[[:space:]]*//')"
    not_after="$(grep -E '^[[:space:]]*not after:' <<< "$cert_text" | sed 's/^[[:space:]]*not after:[[:space:]]*//')"
    form="$(grep -E '^[[:space:]]*form:' <<< "$cert_text" | sed 's/^[[:space:]]*form:[[:space:]]*//')"
    subtree="$(grep -E '^[[:space:]]*subtree:' <<< "$cert_text" | sed 's/^[[:space:]]*subtree:[[:space:]]*//')"
    inc_proof="$(grep -E '^[[:space:]]*inclusion proof:' <<< "$cert_text" | sed 's/^[[:space:]]*inclusion proof:[[:space:]]*//')"
    sigs="$(grep -E '^[[:space:]]*signatures:' <<< "$cert_text" | sed 's/^[[:space:]]*signatures:[[:space:]]*//')"

    ca_id="$(sed -n 's/.*trustAnchorID=\([0-9.]*\).*/\1/p' <<< "$issuer")"

    is_relative=false
    badge_class="badge-standalone"
    badge_text="Standalone MTC Certificate"
    if [[ "$form" == *"landmark-relative"* ]]; then
        is_relative=true
        badge_class="badge-relative"
        badge_text="Landmark-Relative MTC Certificate"
    fi

    landmark_info="$(find_covering_landmark "${entry_index:-0}")"
    lm_num=""
    lm_prev=""
    lm_size=""
    lm_taid=""
    if [[ -n "$landmark_info" ]]; then
        IFS='|' read -r lm_num lm_prev lm_size <<< "$landmark_info"
        if [[ -n "$ca_id" && -n "$log_number" ]]; then
            lm_taid="${ca_id}.1.${log_number}.${lm_num}"
        fi
    fi

    if command -v a2ensite >/dev/null 2>&1; then
        doc_root="/var/www/${domain}"
    else
        doc_root="${WWW_ROOT}/${domain}"
    fi
    mkdir -p "$doc_root"
    out_html="${doc_root}/index.html"

    landmark_card=""
    if [[ -n "$lm_num" ]]; then
        landmark_card=$(cat <<EOF
      <div class="card highlight-card">
        <div class="card-label">Covering Landmark</div>
        <div class="card-value">Landmark #${lm_num}</div>
        <div class="card-sub">
          Covers entries <code>[${lm_prev}, ${lm_size})</code> &bull; Tree size: <code>${lm_size}</code>
          ${lm_taid:+<br>Landmark Trust Anchor ID: <code>${lm_taid}</code>}
        </div>
      </div>
EOF
)
    else
        landmark_card=$(cat <<EOF
      <div class="card">
        <div class="card-label">Covering Landmark</div>
        <div class="card-value">Pending next hourly allocation</div>
        <div class="card-sub">Entry index <code>${entry_index}</code> is newer than the latest published landmark</div>
      </div>
EOF
)
    fi

    cat > "$out_html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${domain} — Merkle Tree Certificate Demo</title>
  <style>
    :root {
      --bg: #0f172a;
      --surface: #1e293b;
      --surface-highlight: #1e3a5f;
      --border: #334155;
      --text: #f8fafc;
      --muted: #94a3b8;
      --accent: #38bdf8;
      --green-bg: rgba(34, 197, 94, 0.15);
      --green-text: #4ade80;
      --amber-bg: rgba(245, 158, 11, 0.15);
      --amber-text: #fbbf24;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 2.5rem 1.25rem;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.5;
    }
    .container {
      max-width: 860px;
      margin: 0 auto;
    }
    header {
      margin-bottom: 2rem;
    }
    .nav {
      display: flex;
      gap: 0.75rem;
      flex-wrap: wrap;
      margin-bottom: 1.25rem;
    }
    .nav a {
      color: var(--muted);
      text-decoration: none;
      font-size: 0.875rem;
      padding: 0.35rem 0.75rem;
      border-radius: 6px;
      border: 1px solid var(--border);
      background: var(--surface);
      transition: all 0.15s ease;
    }
    .nav a:hover, .nav a.active {
      color: var(--accent);
      border-color: var(--accent);
    }
    h1 {
      font-size: 1.75rem;
      margin: 0 0 0.65rem 0;
      letter-spacing: -0.02em;
    }
    .badge {
      display: inline-block;
      padding: 0.25rem 0.75rem;
      border-radius: 9999px;
      font-size: 0.825rem;
      font-weight: 600;
    }
    .badge-relative {
      background: var(--green-bg);
      color: var(--green-text);
      border: 1px solid rgba(74, 222, 128, 0.3);
    }
    .badge-standalone {
      background: var(--amber-bg);
      color: var(--amber-text);
      border: 1px solid rgba(251, 191, 36, 0.3);
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
      gap: 1rem;
      margin-bottom: 1.5rem;
    }
    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 1.15rem 1.25rem;
    }
    .highlight-card {
      background: var(--surface-highlight);
      border-color: rgba(56, 189, 248, 0.35);
    }
    .card-label {
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      color: var(--muted);
      margin-bottom: 0.35rem;
    }
    .card-value {
      font-size: 1.35rem;
      font-weight: 700;
      color: var(--text);
      margin-bottom: 0.25rem;
    }
    .card-sub {
      font-size: 0.825rem;
      color: var(--muted);
    }
    code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      color: var(--accent);
      font-size: 0.85em;
    }
    .section {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 1.25rem;
      margin-bottom: 1.5rem;
    }
    .section h2 {
      font-size: 1rem;
      margin: 0 0 0.85rem 0;
      color: var(--muted);
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.925rem;
    }
    th, td {
      text-align: left;
      padding: 0.55rem 0.5rem;
      border-bottom: 1px solid rgba(255,255,255,0.06);
    }
    th {
      color: var(--muted);
      font-weight: 500;
      width: 34%;
    }
    pre {
      margin: 0;
      padding: 1rem;
      background: #090e17;
      border: 1px solid var(--border);
      border-radius: 8px;
      overflow-x: auto;
      font-size: 0.84rem;
      line-height: 1.45;
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="nav">
        <a href="https://standalone.demo.mtcs.dev/" class="$([ "$domain" = "standalone.demo.mtcs.dev" ] && echo active || true)">standalone.demo.mtcs.dev</a>
        <a href="https://relative.demo.mtcs.dev/" class="$([ "$domain" = "relative.demo.mtcs.dev" ] && echo active || true)">relative.demo.mtcs.dev</a>
        <a href="https://landmark-relative.demo.mtcs.dev/" class="$([ "$domain" = "landmark-relative.demo.mtcs.dev" ] && echo active || true)">landmark-relative.demo.mtcs.dev</a>
      </div>
      <h1>${domain}</h1>
      <span class="badge ${badge_class}">${badge_text}</span>
    </header>

    <div class="grid">
      <div class="card highlight-card">
        <div class="card-label">Issuance Log Entry Index</div>
        <div class="card-value">#${entry_index}</div>
        <div class="card-sub">Log #${log_number} &bull; Issuer CA ID: <code>${ca_id}</code></div>
      </div>

${landmark_card}
    </div>

    <div class="section">
      <h2>MTC Proof &amp; Certificate Properties</h2>
      <table>
        <tr>
          <th>Certificate Form</th>
          <td><code>${form}</code></td>
        </tr>
        <tr>
          <th>Proof Subtree Range</th>
          <td><code>${subtree}</code></td>
        </tr>
        <tr>
          <th>Inclusion Proof</th>
          <td><code>${inc_proof}</code></td>
        </tr>
        <tr>
          <th>Cosigner Signatures</th>
          <td><code>${sigs}</code></td>
        </tr>
        <tr>
          <th>Validity Window</th>
          <td><code>${not_before}</code> &rarr; <code>${not_after}</code></td>
        </tr>
      </table>
    </div>

    <div class="section">
      <h2>Full Output of <code>cactus-cli cert text</code></h2>
      <pre><code>${cert_text}</code></pre>
    </div>
  </div>
</body>
</html>
EOF
    echo "==> Generated ${out_html} (entry index #${entry_index}, landmark #${lm_num:-none})"
done
