#!/usr/bin/env bash
set -Eeuo pipefail

OUT_DIR="${1:-.garnet/runtime/latest}"
RUN_ID="${GITHUB_RUN_ID:-}"
REPO="${GITHUB_REPOSITORY:-}"
GARNET_DASHBOARD_BASEURL="${GARNET_DASHBOARD_BASEURL:-https://dashboard.garnet.ai}"
# Domain pattern: best-effort validation for ASCII hostnames (labels cannot start/end with hyphens) plus localhost; IDN/punycode is not included.
# The last label must start with a letter and other single-label words are not hosts, so log prefixes, table headers, counts, versions and IPs are not reported as domains.
LABEL_PATTERN='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
TLD_PATTERN='[A-Za-z]([A-Za-z0-9-]*[A-Za-z0-9])?'
DOMAIN_REGEX="((${LABEL_PATTERN}\\.)+${TLD_PATTERN})|localhost"
ALLOWED_DASHBOARD_HOSTS_REGEX="${GARNET_DASHBOARD_ALLOWED_HOSTS_REGEX:-dashboard\.garnet\.ai|localhost(:[0-9]+)?}"

mkdir -p "${OUT_DIR}"

log() {
  printf '[garnet-report-backfill] %s\n' "$*" >&2
}

write_file() {
  local file="$1"
  shift
  printf '%s\n' "$*" > "${file}"
}

extract_run_id_from_profile_json() {
  local file="$1"
  if ! command -v jq >/dev/null 2>&1 || [[ ! -f "${file}" ]]; then
    return 0
  fi

  jq -r '
    [
      .run_id,
      .runId,
      .run.id,
      .run.run_id,
      .run.runId,
      .metadata.run_id,
      .metadata.runId,
      .context.run_id,
      .context.runId,
      .context.github.run_id,
      .context.github.runId,
      .github_run_id,
      .githubRunId
    ]
    | map(select(. != null) | tostring)
    | .[0] // empty
  ' "${file}" 2>/dev/null || true
}

extract_run_id_from_profiles_list() {
  local file="$1"
  if ! command -v jq >/dev/null 2>&1 || [[ ! -f "${file}" ]]; then
    return 0
  fi

  jq -r '
    def rows:
      if type == "array" then .
      elif type == "object" and (.items | type) == "array" then .items
      elif type == "object" and (.profiles | type) == "array" then .profiles
      elif type == "object" and (.data | type) == "array" then .data
      else []
      end;

    rows
    | map(select(type == "object"))
    | map(
        [
          .run_id,
          .runId,
          .run.id,
          .run.run_id,
          .run.runId,
          .metadata.run_id,
          .metadata.runId,
          .context.run_id,
          .context.runId,
          .context.github.run_id,
          .context.github.runId,
          .github_run_id,
          .githubRunId
        ]
        | map(select(. != null) | tostring)
        | .[0] // empty
      )
    | map(select(length > 0))
    | .[0] // empty
  ' "${file}" 2>/dev/null || true
}

fetch_public_run_report() {
  local run_id="$1"
  local base="$2"

  if [[ -z "${run_id}" ]]; then
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  if [[ "${base}" != http://* && "${base}" != https://* ]]; then
    return 1
  fi

  local trimmed="${base#http://}"
  trimmed="${trimmed#https://}"
  local host_port="${trimmed%%[/?]*}"
  if [[ "${host_port}" != "${trimmed}" ]]; then
    return 1
  fi

  if [[ ! "${host_port}" =~ ^(${ALLOWED_DASHBOARD_HOSTS_REGEX})$ ]]; then
    return 1
  fi

  base="${base%/}"
  local fetch_err="${OUT_DIR}/public_run_report.fetch.err"
  : > "${fetch_err}"
  local attempts=(
    "${base}/public/runs/${run_id}/report.md::${OUT_DIR}/public_run_report.md"
    "${base}/public/runs/${run_id}.md::${OUT_DIR}/public_run_report.md"
    "${base}/public/runs/${run_id}/report.txt::${OUT_DIR}/public_run_report.md"
    "${base}/public/runs/${run_id}::${OUT_DIR}/public_run_report.html"
  )

  local entry url target
  for entry in "${attempts[@]}"; do
    IFS="::" read -r url target <<< "${entry}"
    if curl -fsS "${url}" -o "${target}" 2>> "${fetch_err}"; then
      write_file "${OUT_DIR}/public_run_report.source.txt" "${url}"
      write_file "${OUT_DIR}/public_run_report.status" "ok"
      return 0
    fi
  done

  return 1
}

extract_domains_to_file() {
  local src="$1"
  local dest="$2"
  local strip_html="${3:-0}"

  if [[ ! -f "${src}" ]]; then
    return 0
  fi

  if [[ "${strip_html}" == "1" ]]; then
    if command -v html2text >/dev/null 2>&1; then
      html2text -width 1000 "${src}" \
        | grep -Eo "${DOMAIN_REGEX}" \
        | tr '[:upper:]' '[:lower:]' \
        | sort -u > "${dest}" || true
    else
      # HTML stripping is best-effort (regex-based) to capture obvious domain tokens; single-line tags only are expected, so domains inside attributes/scripts, newline-split tags, or complex markup may be skipped.
      sed 's/<[^>]*>//g' "${src}" \
        | grep -Eo "${DOMAIN_REGEX}" \
        | tr '[:upper:]' '[:lower:]' \
        | sort -u > "${dest}" || true
    fi
  else
    grep -Eo "${DOMAIN_REGEX}" "${src}" \
      | tr '[:upper:]' '[:lower:]' \
      | sort -u > "${dest}" || true
  fi
}

if [[ -z "${RUN_ID}" || -z "${REPO}" ]]; then
  write_file "${OUT_DIR}/domains_backfill.status" "failed"
  write_file "${OUT_DIR}/domains_backfill.error.txt" "missing GITHUB_RUN_ID or GITHUB_REPOSITORY"
  exit 0
fi

RAW_LOG="${OUT_DIR}/run.log.raw.txt"
CLEAN_LOG="${OUT_DIR}/run.log.clean.txt"
SECTION_FILE="${OUT_DIR}/egress_report.section.txt"
REPORT_DOMAINS="${OUT_DIR}/domains_from_report.list.txt"
PUBLIC_REPORT_DOMAINS="${OUT_DIR}/domains_from_public_report.list.txt"
RUN_DOMAINS="${OUT_DIR}/domains_for_run.list.txt"
GARNET_RUN_ID_FILE="${OUT_DIR}/garnet_run_id.txt"

PROFILE_RUN_ID=""
if [[ -f "${OUT_DIR}/profile_for_run.json" ]]; then
  PROFILE_RUN_ID="$(extract_run_id_from_profile_json "${OUT_DIR}/profile_for_run.json")"
fi
if [[ -z "${PROFILE_RUN_ID}" && -f "${OUT_DIR}/profiles_for_agent.json" ]]; then
  PROFILE_RUN_ID="$(extract_run_id_from_profiles_list "${OUT_DIR}/profiles_for_agent.json")"
fi
if [[ -z "${PROFILE_RUN_ID}" ]]; then
  PROFILE_RUN_ID="${RUN_ID}"
fi
write_file "${GARNET_RUN_ID_FILE}" "${PROFILE_RUN_ID}"

RUN_COUNT=0
if [[ -f "${RUN_DOMAINS}" ]]; then
  RUN_COUNT="$(wc -l < "${RUN_DOMAINS}" | tr -d ' ')"
fi

PUBLIC_COUNT=0
if fetch_public_run_report "${PROFILE_RUN_ID}" "${GARNET_DASHBOARD_BASEURL}"; then
  if [[ -f "${OUT_DIR}/public_run_report.md" ]]; then
    extract_domains_to_file "${OUT_DIR}/public_run_report.md" "${PUBLIC_REPORT_DOMAINS}"
  elif [[ -f "${OUT_DIR}/public_run_report.html" ]]; then
    extract_domains_to_file "${OUT_DIR}/public_run_report.html" "${PUBLIC_REPORT_DOMAINS}" "1"
  fi
fi

if [[ -f "${PUBLIC_REPORT_DOMAINS}" ]]; then
  PUBLIC_COUNT="$(wc -l < "${PUBLIC_REPORT_DOMAINS}" | tr -d ' ')"
fi

REPORT_COUNT=0
SOURCE="profile"

if [[ "${RUN_COUNT}" -eq 0 && "${PUBLIC_COUNT}" -gt 0 ]]; then
  cp "${PUBLIC_REPORT_DOMAINS}" "${RUN_DOMAINS}"
  RUN_COUNT="${PUBLIC_COUNT}"
  SOURCE="garnet_public_report"
elif [[ "${RUN_COUNT}" -eq 0 ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    write_file "${OUT_DIR}/domains_backfill.status" "failed"
    write_file "${OUT_DIR}/domains_backfill.error.txt" "gh CLI not found"
    exit 0
  fi

  if ! gh run view "${RUN_ID}" --repo "${REPO}" --log > "${RAW_LOG}" 2> "${OUT_DIR}/domains_backfill.fetch.err"; then
    write_file "${OUT_DIR}/domains_backfill.status" "failed"
    exit 0
  fi

  # Strip ANSI coloring and other control characters.
  perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' "${RAW_LOG}" > "${CLEAN_LOG}"

  awk '
    /NETWORK EGRESS SUMMARY/ {capture=1; next}
    /Network Telemetry Summary/ {capture=0}
    capture {print}
  ' "${CLEAN_LOG}" > "${SECTION_FILE}"

  # Prefer domain-like tokens from destination table rows.
  extract_domains_to_file "${SECTION_FILE}" "${REPORT_DOMAINS}"

  if [[ -f "${REPORT_DOMAINS}" ]]; then
    REPORT_COUNT="$(wc -l < "${REPORT_DOMAINS}" | tr -d ' ')"
  fi

  if [[ "${RUN_COUNT}" -eq 0 && "${REPORT_COUNT}" -gt 0 ]]; then
    cp "${REPORT_DOMAINS}" "${RUN_DOMAINS}"
    RUN_COUNT="${REPORT_COUNT}"
    SOURCE="garnet_runtime_report"
  fi
fi

if [[ "${RUN_COUNT}" -gt 0 ]]; then
  write_file "${OUT_DIR}/domains_for_run.status" "ok"
else
  write_file "${OUT_DIR}/domains_for_run.status" "none"
fi

{
  echo "Run-Scoped Domains Summary"
  echo "run_id: ${RUN_ID}"
  echo "domains_source: ${SOURCE}"
  echo "domains_found: ${RUN_COUNT}"
  if [[ "${RUN_COUNT}" -gt 0 ]]; then
    echo ""
    echo "Domains"
    sed 's/^/- /' "${RUN_DOMAINS}"
  else
    echo "No domains resolved for this run."
  fi
} > "${OUT_DIR}/domains_for_run.md"

{
  echo "run_id=${RUN_ID}"
  echo "domains_source=${SOURCE}"
  echo "domains_found=${RUN_COUNT}"
} > "${OUT_DIR}/domains_for_run.txt"

if command -v jq >/dev/null 2>&1 && [[ -f "${OUT_DIR}/summary.json" ]]; then
  jq --arg source "${SOURCE}" \
     --argjson domains "$(jq -R -s 'split("\n") | map(select(length > 0))' "${RUN_DOMAINS}")" \
     '.domains_source = $source
      | .domains_for_run = $domains
      | .domains_for_run_status = (if ($domains|length) > 0 then "ok" else "none" end)' \
     "${OUT_DIR}/summary.json" > "${OUT_DIR}/summary.json.tmp" && mv "${OUT_DIR}/summary.json.tmp" "${OUT_DIR}/summary.json"
fi

write_file "${OUT_DIR}/domains_backfill.status" "ok"
log "Backfill complete for run_id=${RUN_ID}, source=${SOURCE}, domains=${RUN_COUNT}"
