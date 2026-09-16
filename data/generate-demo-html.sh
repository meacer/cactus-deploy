#!/usr/bin/env bash
# Generates well-formatted, clean index.html pages for MTC demo domains from
# the output of `cactus-cli cert text` and the log's `/landmarks` endpoint.
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/enable-tai.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/enable-tai.env"
fi

if [[ $# -eq 0 ]]; then
    DOMAINS=("standalone.demo.mtcs.dev" "relative.demo.mtcs.dev" "landmark-relative.demo.mtcs.dev")
    if [[ "${ENABLE_TAI:-false}" == "true" ]]; then
        DOMAINS+=("tai.demo.mtcs.dev" "demo.mtcs.dev")
    fi
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
for i in range(len(sizes) - 2, -1, -1):
    lm_num = last - i
    lm_size = sizes[i]
    prev_size = sizes[i + 1]
    if lm_size > target:
        print(f"{lm_num}|{prev_size}|{lm_size}")
        sys.exit(0)
' "$index" <<< "$LANDMARKS_RAW"
}

format_cert_text_html() {
    python3 -c '
import html, re, sys

raw = sys.stdin.read()
escaped = html.escape(raw)

# Highlight top header line
escaped = re.sub(r"^(Merkle Tree Certificate)", r"<span class=\"hl-header\">\1</span>", escaped, flags=re.M)
# Highlight section headers
escaped = re.sub(r"^(\s+)(extensions:|MTC proof:)", r"\1<span class=\"hl-section\">\2</span>", escaped, flags=re.M)
# Highlight field labels
escaped = re.sub(r"^(\s+)([a-zA-Z0-9 _-]+:)(\s+)", r"\1<span class=\"hl-key\">\2</span>\3", escaped, flags=re.M)
# Highlight bullet items (cosigners)
escaped = re.sub(r"^(\s+-\s+cosigner\s+)([0-9.]+)", r"\1<span class=\"hl-val\">\2</span>", escaped, flags=re.M)

print(escaped, end="")
'
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
    formatted_cert_text="$(format_cert_text_html <<< "$cert_text")"

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
    badge_text="Standalone MTC"
    summary_desc="Verified via ${sigs} ML-DSA-44 cosigner signatures over checkpoint subtree <code>${subtree}</code>"
    if [[ "$form" == *"landmark-relative"* ]]; then
        is_relative=true
        badge_class="badge-relative"
        badge_text="Landmark-Relative MTC"
        summary_desc="Signature-free MTC verified via ${inc_proof} Merkle inclusion proof to a trusted landmark subtree"
        if [[ "$domain" == "tai.demo.mtcs.dev" || "$domain" == "demo.mtcs.dev" ]]; then
            badge_text="TAI Landmark-Relative MTC"
            summary_desc="Negotiated via TLS 1.3 Trust Anchor Identifiers (<code>trust_anchors</code>) &mdash; serves signature-free Landmark-Relative MTC when covering landmark TAID matches, or falls back to Standalone MTC"
        fi
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

    landmark_row=""
    if [[ -n "$lm_num" ]]; then
        landmark_row=$(cat <<EOF
        <tr>
          <th>Covering Landmark</th>
          <td>
            <span class="val-strong">Landmark #${lm_num}</span>
            <span class="meta">covers log entries <code>[${lm_prev}, ${lm_size})</code> &middot; tree size <code>${lm_size}</code></span>
            ${lm_taid:+<div class="meta-sub">Trust Anchor ID: <code>${lm_taid}</code></div>}
          </td>
        </tr>
EOF
)
    else
        landmark_row=$(cat <<EOF
        <tr>
          <th>Covering Landmark</th>
          <td><span class="meta">Pending next hourly landmark allocation</span></td>
        </tr>
EOF
)
    fi

    cosigner_row=""
    if [[ "$is_relative" == "false" ]]; then
        cosigner_list=""
        while IFS= read -r line; do
            if [[ "$line" =~ -[[:space:]]*cosigner[[:space:]]+([^[:space:]]+)[[:space:]]*\(([0-9]+)-byte[[:space:]]+signature\) ]]; then
                cos_id="${BASH_REMATCH[1]}"
                sig_bytes="${BASH_REMATCH[2]}"
                role="Mirror"
                if [[ "$cos_id" == "$ca_id" ]]; then
                    role="CA"
                fi
                cosigner_list="${cosigner_list}<div class=\"meta-sub\"><code>${cos_id}</code> (${role}, ${sig_bytes} B ML-DSA-44)</div>"
            fi
        done <<< "$cert_text"

        cosigner_row=$(cat <<EOF
        <tr>
          <th>Cosigner Signatures</th>
          <td>
            <span class="val-strong">${sigs} signature(s)</span>
            ${cosigner_list}
          </td>
        </tr>
EOF
)
    else
        cosigner_row=$(cat <<EOF
        <tr>
          <th>Cosigner Signatures</th>
          <td><code>0</code> <span class="meta">(omitted; relies on pre-distributed landmark subtree hash)</span></td>
        </tr>
EOF
)
    fi

    standalone_section=""
    if [[ ("$domain" == "tai.demo.mtcs.dev" || "$domain" == "demo.mtcs.dev") && -f "${CERTS_DIR}/${domain}-standalone.crt" ]]; then
        sa_file="${CERTS_DIR}/${domain}-standalone.crt"
        sa_text="$("$CACTUS_CLI" cert text "$sa_file")"
        sa_formatted="$(format_cert_text_html <<< "$sa_text")"
        sa_subtree="$(grep -E '^[[:space:]]*subtree:' <<< "$sa_text" | sed 's/^[[:space:]]*subtree:[[:space:]]*//')"
        sa_inc_proof="$(grep -E '^[[:space:]]*inclusion proof:' <<< "$sa_text" | sed 's/^[[:space:]]*inclusion proof:[[:space:]]*//')"
        sa_sigs="$(grep -E '^[[:space:]]*signatures:' <<< "$sa_text" | sed 's/^[[:space:]]*signatures:[[:space:]]*//')"

        sa_cosigner_list=""
        while IFS= read -r line; do
            if [[ "$line" =~ -[[:space:]]*cosigner[[:space:]]+([^[:space:]]+)[[:space:]]*\(([0-9]+)-byte[[:space:]]+signature\) ]]; then
                cos_id="${BASH_REMATCH[1]}"
                sig_bytes="${BASH_REMATCH[2]}"
                role="Mirror"
                if [[ "$cos_id" == "$ca_id" ]]; then
                    role="CA"
                fi
                sa_cosigner_list="${sa_cosigner_list}<div class=\"meta-sub\"><code>${cos_id}</code> (${role}, ${sig_bytes} B ML-DSA-44)</div>"
            fi
        done <<< "$sa_text"

        standalone_section=$(cat <<EOF
    <div class="panel">
      <div class="title-row">
        <h1>Fallback Certificate (No TAI Match)</h1>
        <span class="badge badge-standalone">Standalone MTC</span>
      </div>
      <p class="subtitle">Served when client does not send <code>trust_anchors</code> or does not advertise <code>${lm_taid:-the covering landmark TAID}</code></p>

      <table>
        <tr>
          <th>Proof Subtree</th>
          <td>
            <code>${sa_subtree}</code>
            <span class="meta">&middot; ${sa_inc_proof} inclusion proof</span>
          </td>
        </tr>
        <tr>
          <th>Cosigner Signatures</th>
          <td>
            <span class="val-strong">${sa_sigs} signature(s)</span>
            ${sa_cosigner_list}
          </td>
        </tr>
      </table>
    </div>

    <div class="panel">
      <h2>cactus-cli cert text (Standalone Fallback &mdash; ${domain}-standalone.crt)</h2>
      <pre><code>${sa_formatted}</code></pre>
    </div>
EOF
)
    fi

    primary_cert_heading="cactus-cli cert text"
    if [[ "$domain" == "tai.demo.mtcs.dev" || "$domain" == "demo.mtcs.dev" ]]; then
        primary_cert_heading="cactus-cli cert text (Landmark-Relative &mdash; ${domain}-landmark-relative.pem)"
    fi

    cat > "$out_html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${domain}</title>
  <style>
    body {
      margin: 0;
      padding: 2.5rem 1.25rem;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #f6f8fa;
      color: #1f2937;
      line-height: 1.55;
    }
    .container {
      max-width: 760px;
      margin: 0 auto;
    }
    nav {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
      margin-bottom: 1.5rem;
    }
    nav a {
      color: #4b5563;
      text-decoration: none;
      font-size: 0.875rem;
      padding: 0.35rem 0.75rem;
      border-radius: 6px;
      background: #ffffff;
      border: 1px solid #d1d5db;
    }
    nav a:hover {
      border-color: #9ca3af;
      color: #111827;
    }
    nav a.active {
      background: #eff6ff;
      color: #1d4ed8;
      border-color: #93c5fd;
      font-weight: 600;
    }
    .panel {
      background: #ffffff;
      border: 1px solid #e5e7eb;
      border-radius: 8px;
      padding: 1.5rem 1.75rem;
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      margin-bottom: 1.25rem;
    }
    .title-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      flex-wrap: wrap;
      gap: 0.75rem;
      margin-bottom: 0.4rem;
    }
    h1 {
      font-size: 1.35rem;
      font-weight: 600;
      color: #111827;
      margin: 0;
    }
    .badge {
      display: inline-block;
      padding: 0.2rem 0.65rem;
      border-radius: 9999px;
      font-size: 0.78rem;
      font-weight: 600;
    }
    .badge-relative {
      background: #ecfdf5;
      color: #047857;
      border: 1px solid #a7f3d0;
    }
    .badge-standalone {
      background: #eff6ff;
      color: #1d4ed8;
      border: 1px solid #bfdbfe;
    }
    .subtitle {
      color: #4b5563;
      font-size: 0.92rem;
      margin: 0 0 1.25rem 0;
      padding-bottom: 1rem;
      border-bottom: 1px solid #f3f4f6;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.92rem;
    }
    th, td {
      text-align: left;
      vertical-align: top;
      padding: 0.65rem 0.25rem;
      border-bottom: 1px solid #f3f4f6;
    }
    tr:last-child th, tr:last-child td {
      border-bottom: none;
    }
    th {
      width: 32%;
      color: #4b5563;
      font-weight: 500;
    }
    td {
      color: #111827;
    }
    .val-strong {
      font-weight: 600;
      color: #0f172a;
    }
    .meta {
      color: #6b7280;
      font-size: 0.86rem;
      margin-left: 0.35rem;
    }
    .meta-sub {
      color: #6b7280;
      font-size: 0.83rem;
      margin-top: 0.2rem;
    }
    code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      font-size: 0.86em;
      background: #f3f4f6;
      color: #0f172a;
      padding: 0.12rem 0.38rem;
      border-radius: 4px;
      border: 1px solid #e5e7eb;
    }
    h2 {
      font-size: 0.85rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: #4b5563;
      margin: 0 0 0.75rem 0;
    }
    pre {
      margin: 0;
      padding: 1.1rem 1.25rem;
      background: #1e293b;
      color: #e2e8f0;
      border-radius: 6px;
      overflow-x: auto;
      font-size: 0.82rem;
      line-height: 1.55;
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    }
    pre code {
      background: transparent;
      color: inherit;
      padding: 0;
      border: none;
      font-size: inherit;
    }
    .hl-header {
      color: #f8fafc;
      font-weight: 600;
    }
    .hl-section {
      color: #93c5fd;
      font-weight: 600;
    }
    .hl-key {
      color: #7dd3fc;
    }
    .hl-val {
      color: #fde68a;
    }
  </style>
</head>
<body>
  <div class="container">
    <nav>
      <a href="https://standalone.demo.mtcs.dev/" class="$([ "$domain" = "standalone.demo.mtcs.dev" ] && echo active || true)">standalone.demo.mtcs.dev</a>
      <a href="https://relative.demo.mtcs.dev/" class="$([ "$domain" = "relative.demo.mtcs.dev" ] && echo active || true)">relative.demo.mtcs.dev</a>
      <a href="https://landmark-relative.demo.mtcs.dev/" class="$([ "$domain" = "landmark-relative.demo.mtcs.dev" ] && echo active || true)">landmark-relative.demo.mtcs.dev</a>
      $([[ "${ENABLE_TAI:-false}" == "true" || "$domain" == "tai.demo.mtcs.dev" || "$domain" == "demo.mtcs.dev" ]] && echo "<a href=\"https://tai.demo.mtcs.dev/\" class=\"$([ \"$domain\" = \"tai.demo.mtcs.dev\" ] && echo active || true)\">tai.demo.mtcs.dev</a> <a href=\"https://demo.mtcs.dev/\" class=\"$([ \"$domain\" = \"demo.mtcs.dev\" ] && echo active || true)\">demo.mtcs.dev</a>" || true)
    </nav>

    <div class="panel">
      <div class="title-row">
        <h1>${domain}</h1>
        <span class="badge ${badge_class}">${badge_text}</span>
      </div>
      <p class="subtitle">${summary_desc}</p>

      <table>
        <tr>
          <th>Issuance Log Entry</th>
          <td>
            <span class="val-strong">Index #${entry_index}</span>
            <span class="meta">in Log #${log_number} &middot; CA ID <code>${ca_id}</code></span>
          </td>
        </tr>
${landmark_row}
        <tr>
          <th>Proof Subtree</th>
          <td>
            <code>${subtree}</code>
            <span class="meta">&middot; ${inc_proof} inclusion proof</span>
          </td>
        </tr>
${cosigner_row}
        <tr>
          <th>Validity Period</th>
          <td><code>${not_before}</code> &ndash; <code>${not_after}</code></td>
        </tr>
      </table>
    </div>

    <div class="panel">
      <h2>${primary_cert_heading}</h2>
      <pre><code>${formatted_cert_text}</code></pre>
    </div>

${standalone_section}
  </div>
</body>
</html>
EOF
    echo "==> Generated ${out_html} (entry index #${entry_index}, landmark #${lm_num:-none})"

    if [[ "$domain" == "tai.demo.mtcs.dev" || "$domain" == "demo.mtcs.dev" ]]; then
        no_tai_dir="${WWW_ROOT}/${domain}-no-tai"
        mkdir -p "$no_tai_dir"
        no_tai_html="${no_tai_dir}/index.html"
        cat > "$no_tai_html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${domain} &mdash; Enable TAI &amp; MTCs in Chrome</title>
  <style>
    :root {
      color-scheme: light;
    }
    * {
      box-sizing: border-box;
    }
    body {
      margin: 0;
      padding: 2rem 1rem 3.5rem;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: #f8fafc;
      color: #0f172a;
      line-height: 1.5;
    }
    .container {
      max-width: 960px;
      margin: 0 auto;
    }
    nav {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
      margin-bottom: 1.5rem;
    }
    nav a {
      text-decoration: none;
      font-size: 0.85rem;
      font-weight: 500;
      color: #475569;
      background: #ffffff;
      border: 1px solid #e2e8f0;
      padding: 0.4rem 0.75rem;
      border-radius: 6px;
      transition: all 0.15s ease;
    }
    nav a:hover {
      border-color: #cbd5e1;
      color: #0f172a;
    }
    nav a.active {
      background: #0f172a;
      color: #ffffff;
      border-color: #0f172a;
    }
    .panel {
      background: #ffffff;
      border: 1px solid #e2e8f0;
      border-radius: 8px;
      padding: 1.5rem;
      margin-bottom: 1.25rem;
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
    }
    .panel-warn {
      border-left: 4px solid #f59e0b;
    }
    .title-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      flex-wrap: wrap;
      gap: 0.75rem;
      margin-bottom: 0.35rem;
    }
    h1 {
      font-size: 1.35rem;
      font-weight: 600;
      margin: 0;
      color: #0f172a;
    }
    .badge {
      display: inline-block;
      padding: 0.2rem 0.65rem;
      border-radius: 9999px;
      font-size: 0.78rem;
      font-weight: 600;
    }
    .badge-warning {
      background: #fffbeb;
      color: #b45309;
      border: 1px solid #fde68a;
    }
    .badge-standalone {
      background: #eff6ff;
      color: #1d4ed8;
      border: 1px solid #bfdbfe;
    }
    .subtitle {
      color: #4b5563;
      font-size: 0.94rem;
      margin: 0.5rem 0 0 0;
    }
    h2 {
      font-size: 0.95rem;
      font-weight: 600;
      color: #0f172a;
      margin: 0 0 0.85rem 0;
    }
    ol.steps {
      margin: 0;
      padding-left: 1.35rem;
      color: #1e293b;
      font-size: 0.93rem;
    }
    ol.steps li {
      margin-bottom: 0.75rem;
    }
    ol.steps li:last-child {
      margin-bottom: 0;
    }
    code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      font-size: 0.86em;
      background: #f1f5f9;
      color: #0f172a;
      padding: 0.15rem 0.42rem;
      border-radius: 4px;
      border: 1px solid #e2e8f0;
      user-select: all;
    }
    pre {
      margin: 0.75rem 0 0 0;
      padding: 1rem 1.15rem;
      background: #1e293b;
      color: #e2e8f0;
      border-radius: 6px;
      overflow-x: auto;
      font-size: 0.82rem;
      line-height: 1.55;
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    }
    pre code {
      background: transparent;
      color: inherit;
      padding: 0;
      border: none;
      font-size: inherit;
      user-select: text;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.92rem;
      margin-top: 0.75rem;
    }
    th, td {
      text-align: left;
      vertical-align: top;
      padding: 0.65rem 0.25rem;
      border-bottom: 1px solid #f3f4f6;
    }
    tr:last-child th, tr:last-child td {
      border-bottom: none;
    }
    th {
      width: 32%;
      color: #4b5563;
      font-weight: 500;
    }
    td {
      color: #111827;
    }
    .val-strong {
      font-weight: 600;
      color: #0f172a;
    }
    .meta {
      color: #6b7280;
      font-size: 0.86rem;
      margin-left: 0.35rem;
    }
    .meta-sub {
      color: #6b7280;
      font-size: 0.83rem;
      margin-top: 0.2rem;
    }
    .hl-header {
      color: #f8fafc;
      font-weight: 600;
    }
    .hl-section {
      color: #93c5fd;
      font-weight: 600;
    }
    .hl-key {
      color: #7dd3fc;
    }
    .hl-val {
      color: #fde68a;
    }
  </style>
</head>
<body>
  <div class="container">
    <nav>
      <a href="https://standalone.demo.mtcs.dev/">standalone.demo.mtcs.dev</a>
      <a href="https://relative.demo.mtcs.dev/">relative.demo.mtcs.dev</a>
      <a href="https://landmark-relative.demo.mtcs.dev/">landmark-relative.demo.mtcs.dev</a>
      <a href="https://tai.demo.mtcs.dev/" class="$([ "$domain" = "tai.demo.mtcs.dev" ] && echo active || true)">tai.demo.mtcs.dev</a>
      <a href="https://demo.mtcs.dev/" class="$([ "$domain" = "demo.mtcs.dev" ] && echo active || true)">demo.mtcs.dev</a>
    </nav>

    <div class="panel panel-warn">
      <div class="title-row">
        <h1>${domain} &mdash; TAI &amp; MTCs Not Enabled</h1>
        <span class="badge badge-warning">WebPKI Fallback Served</span>
      </div>
      <p class="subtitle">
        Your browser connected without negotiating TLS Trust Anchor IDs (<code>trust_anchors</code> extension) or did not advertise a matching Merkle Tree Certificate (MTC) landmark group ID. To prevent SSL connection errors on standard browsers, the server served a standard <strong>Let&rsquo;s Encrypt WebPKI certificate</strong> instead of the compact <strong>Landmark-Relative MTC</strong>.
      </p>
    </div>

    <div class="panel">
      <h2>How to Enable Trust Anchor IDs (TAI) &amp; MTCs in Chrome</h2>
      <ol class="steps">
        <li>
          <strong>Enable TLS Trust Anchor IDs:</strong> Open <code>chrome://flags/#tls-trust-anchor-ids</code> in a new tab and set <strong>TLS Trust Anchor IDs</strong> to <strong>Enabled</strong>.
        </li>
        <li>
          <strong>Enable Verify MTCs:</strong> Open <code>chrome://flags/#verify-mtcs</code> and set <strong>Verify MTCs</strong> to <strong>Enabled</strong>.
        </li>
        <li>
          <strong>Relaunch Chrome:</strong> Click the <strong>Relaunch</strong> button at the bottom of the flags page.
        </li>
        <li>
          <strong>Ensure PKI Metadata is Up to Date:</strong> Open <code>chrome://components</code>, locate <strong>PKI Metadata</strong> (or <strong>PKI Metadata Fastpush</strong>), and click <strong>Check for update</strong> so your browser has the latest MTC landmark group trust anchors.
        </li>
        <li>
          <strong>Reload this page:</strong> Reload <a href="https://${domain}/">https://${domain}/</a> (or open in a new <strong>Incognito window</strong> / flush sockets at <code>chrome://net-internals/#sockets</code> to establish a new TLS connection). Once TAI is negotiated, this page will automatically display the full MTC certificate dashboard!
        </li>
      </ol>
      <p class="subtitle" style="margin-top: 1rem;">
        <strong>Command-line alternative:</strong> Launch Chrome directly with:<br>
        <code>google-chrome --enable-features=TLSTrustAnchorIDs,VerifyMTCs https://${domain}/</code>
      </p>
    </div>

${standalone_section}
  </div>
</body>
</html>
EOF
        echo "==> Generated ${no_tai_html} (non-TAI instructions page)"
    fi
done
