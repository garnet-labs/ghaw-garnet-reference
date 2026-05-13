#!/usr/bin/env bash
set -Eeuo pipefail

OUT_DIR="${1:-.garnet/runtime/latest}"
RUN_ID="${GITHUB_RUN_ID:-}"
REPOSITORY_ID="${GITHUB_REPOSITORY:-}"
WORKFLOW_NAME="${GITHUB_WORKFLOW:-}"

mkdir -p "${OUT_DIR}"

HAS_JQ=0
if command -v jq >/dev/null 2>&1; then
  HAS_JQ=1
fi

log() {
  printf '[garnet-snapshot] %s\n' "$*" >&2
}

write_file() {
  local file="$1"
  shift
  printf '%s\n' "$*" > "${file}"
}

capture_cmd() {
  local name="$1"
  shift
  local cmd="$*"

  local out_file="${OUT_DIR}/${name}.txt"
  local err_file="${OUT_DIR}/${name}.err"
  local attempts_file="${OUT_DIR}/${name}.attempts.log"

  : > "${attempts_file}"
  write_file "${OUT_DIR}/${name}.command.txt" "${cmd}"

  printf '[1] %s\n' "${cmd}" >> "${attempts_file}"
  if bash -lc "${cmd}" > "${out_file}" 2> "${err_file}"; then
    if [[ -s "${err_file}" ]]; then
      cat "${err_file}" >> "${attempts_file}"
    fi
    rm -f "${err_file}"
    write_file "${OUT_DIR}/${name}.status" "ok"
    return 0
  fi

  if [[ -s "${err_file}" ]]; then
    cat "${err_file}" >> "${attempts_file}"
  fi
  rm -f "${err_file}"
  write_file "${OUT_DIR}/${name}.status" "failed"
  return 1
}

capture_with_retries() {
  local name="$1"
  local retries="$2"
  local sleep_s="$3"
  shift 3
  local cmd="$*"

  local out_file="${OUT_DIR}/${name}.txt"
  local err_file="${OUT_DIR}/${name}.err"
  local attempts_file="${OUT_DIR}/${name}.attempts.log"

  : > "${attempts_file}"
  write_file "${OUT_DIR}/${name}.command.txt" "${cmd}"

  local i=1
  while [[ "${i}" -le "${retries}" ]]; do
    printf '[%s] %s\n' "${i}" "${cmd}" >> "${attempts_file}"
    if bash -lc "${cmd}" > "${out_file}" 2> "${err_file}"; then
      if [[ -s "${err_file}" ]]; then
        cat "${err_file}" >> "${attempts_file}"
      fi
      rm -f "${err_file}"
      write_file "${OUT_DIR}/${name}.status" "ok"
      return 0
    fi

    if [[ -s "${err_file}" ]]; then
      cat "${err_file}" >> "${attempts_file}"
    fi
    rm -f "${err_file}"

    if [[ "${i}" -lt "${retries}" ]]; then
      sleep "${sleep_s}"
    fi
    i=$((i + 1))
  done

  write_file "${OUT_DIR}/${name}.status" "failed"
  return 1
}

json_or_text() {
  local src="$1"
  local base="$2"
  if [[ "${HAS_JQ}" -eq 1 ]] && jq -e . "${src}" >/dev/null 2>&1; then
    mv "${src}" "${base}.json"
  else
    local text_target="${base}.txt"
    if [[ "${src}" != "${text_target}" ]]; then
      mv "${src}" "${text_target}"
    fi
  fi
}

extract_action_output_agent_id() {
  if [[ "${HAS_JQ}" -ne 1 || ! -f "${OUT_DIR}/action_outputs.json" ]]; then
    return 0
  fi

  jq -r '
    [
      .agent_id,
      .agentId,
      .id,
      .agent.id,
      .agent.agent_id,
      .outputs.agent_id,
      .outputs.agentId
    ]
    | map(select(type == "string" and length > 0))
    | .[0] // empty
  ' "${OUT_DIR}/action_outputs.json" 2>/dev/null || true
}

pick_agent_id_for_run() {
  local run_id="$1"
  local agents_file="$2"

  if [[ "${HAS_JQ}" -ne 1 || ! -f "${agents_file}" ]]; then
    return 0
  fi

  jq -r --arg run_id "${run_id}" '
    def rows:
      if type == "array" then .
      elif type == "object" and (.items | type) == "array" then .items
      elif type == "object" and (.agents | type) == "array" then .agents
      elif type == "object" and (.data | type) == "array" then .data
      else []
      end;

    def agent_id($a): ($a.agent_id // $a.agentId // $a.id // empty);
    def run_match($a):
      [
        $a.run_id,
        $a.runId,
        $a.github_run_id,
        $a.githubRunId,
        $a.github_context.run_id,
        $a.github_context.runId,
        $a.github.run_id,
        $a.github.runId,
        $a.context.github.run_id,
        $a.context.github.runId,
        $a.metadata.run_id,
        $a.metadata.runId,
        $a.metadata.github_run_id,
        $a.metadata.githubRunId,
        $a.metadata.github.run_id,
        $a.metadata.github.runId,
        $a.metadata.github_context.run_id,
        $a.metadata.github_context.runId
      ]
      | map(select(. != null) | tostring)
      | index($run_id) != null;

    rows as $r
    | (
        $r
        | map(select(type == "object" and run_match(.)))
        | map(agent_id(.))
        | map(select(type == "string" and length > 0))
        | .[0]
      ) // (
        $r
        | map(select(type == "object"))
        | sort_by(.last_seen // .lastSeen // .updated_at // .updatedAt // .created_at // .createdAt // "")
        | reverse
        | map(agent_id(.))
        | map(select(type == "string" and length > 0))
        | .[0] // empty
      )
  ' "${agents_file}" 2>/dev/null || true
}

extract_profile_for_run_from_agent_profiles() {
  local run_id="$1"
  local in_file="$2"
  local out_file="$3"

  if [[ "${HAS_JQ}" -ne 1 || ! -f "${in_file}" ]]; then
    return 1
  fi

  jq -c --arg run_id "${run_id}" '
    def rows:
      if type == "array" then .
      elif type == "object" and (.items | type) == "array" then .items
      elif type == "object" and (.profiles | type) == "array" then .profiles
      elif type == "object" and (.data | type) == "array" then .data
      else []
      end;

    def has_run($p):
      [
        $p.run_id,
        $p.runId,
        $p.github_run_id,
        $p.githubRunId,
        $p.workflow_run_id,
        $p.workflowRunId,
        $p.metadata.run_id,
        $p.metadata.runId,
        $p.metadata.github_run_id,
        $p.metadata.githubRunId,
        $p.metadata.github.run_id,
        $p.metadata.github.runId,
        $p.github.run_id,
        $p.github.runId,
        $p.context.github.run_id,
        $p.context.github.runId
      ]
      | map(select(. != null) | tostring)
      | index($run_id) != null;

    rows as $r
    | (
        $r
        | map(select(type == "object" and has_run(.)))
        | .[0]
      ) // (
        $r
        | map(select(type == "object"))
        | sort_by(.created_at // .createdAt // .timestamp // .time // "")
        | reverse
        | .[0]
      )
  ' "${in_file}" > "${out_file}" 2>/dev/null
}

extract_domains_from_profile_json() {
  local profile_file="$1"

  if [[ "${HAS_JQ}" -ne 1 || ! -f "${profile_file}" ]]; then
    return 0
  fi

  jq -r '
    def walk_values(x):
      if (x|type) == "array" then x[] | walk_values(.)
      elif (x|type) == "object" then
        (
          [x.domain, x.hostname, x.host, x.destination, x.dest, x.address, x.name][]? | strings
        ),
        (x[]? | walk_values(.))
      elif (x|type) == "string" then x
      else empty
      end;

    walk_values(.)
  ' "${profile_file}" 2>/dev/null \
  | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##' \
  | sed -E 's#[/:?#].*$##' \
  | sed -E 's#\.$##' \
  | tr '[:upper:]' '[:lower:]' \
  | awk 'length($0)>0' \
  | grep -E '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,63}$' \
  | sort -u || true
}

build_domains_summary() {
  local profile_status="$1"
  local domains_file="$2"

  local count=0
  if [[ -f "${domains_file}" ]]; then
    count="$(wc -l < "${domains_file}" | tr -d ' ')"
  fi

  {
    echo "Run-Scoped Domains Summary"
    echo "run_id: ${RUN_ID:-unknown}"
    echo "profile_status: ${profile_status}"
    echo "domains_found: ${count}"
    if [[ "${count}" -gt 0 ]]; then
      echo ""
      echo "Domains"
      cat "${domains_file}" | sed 's/^/- /'
    else
      echo "No domains were extracted from profile_for_run output for this run."
    fi
  } > "${OUT_DIR}/domains_for_run.md"

  {
    echo "run_id=${RUN_ID:-}"
    echo "profile_status=${profile_status}"
    echo "domains_found=${count}"
  } > "${OUT_DIR}/domains_for_run.txt"

  if [[ "${count}" -gt 0 ]]; then
    write_file "${OUT_DIR}/domains_for_run.status" "ok"
  else
    write_file "${OUT_DIR}/domains_for_run.status" "none"
  fi
}

log "Output directory: ${OUT_DIR}"

if ! command -v garnetctl >/dev/null 2>&1; then
  write_file "${OUT_DIR}/error.txt" "garnetctl not found in PATH"
  exit 1
fi

if [[ -n "${GARNET_API_BASEURL:-}" ]]; then
  garnetctl config set-baseurl "${GARNET_API_BASEURL}" >/dev/null 2>&1 || true
fi

write_file "${OUT_DIR}/generated_at.txt" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
write_file "${OUT_DIR}/run_id.txt" "${RUN_ID}"
write_file "${OUT_DIR}/repository_id.txt" "${REPOSITORY_ID}"
write_file "${OUT_DIR}/workflow_name.txt" "${WORKFLOW_NAME}"
printf '%s\n' "${GARNET_ACTION_OUTPUTS:-{}}" > "${OUT_DIR}/action_outputs.json"
garnetctl --version > "${OUT_DIR}/garnetctl.version.txt" 2>&1 || true

# 1) Fetch active agents (canonical command)
capture_cmd "agents" "garnetctl list agent --newest 20 --output json" || true
if [[ -f "${OUT_DIR}/agents.txt" ]]; then
  json_or_text "${OUT_DIR}/agents.txt" "${OUT_DIR}/agents"
fi

AGENT_ID="$(extract_action_output_agent_id || true)"
AGENT_ID_SOURCE="action_outputs"

if [[ -z "${AGENT_ID}" && -f "${OUT_DIR}/agents.json" && -n "${RUN_ID}" ]]; then
  AGENT_ID="$(pick_agent_id_for_run "${RUN_ID}" "${OUT_DIR}/agents.json" || true)"
  AGENT_ID_SOURCE="agents_json"
fi

if [[ -z "${AGENT_ID}" && -f "${OUT_DIR}/agents.json" ]]; then
  AGENT_ID="$(pick_agent_id_for_run "" "${OUT_DIR}/agents.json" || true)"
  AGENT_ID_SOURCE="agents_newest"
fi

write_file "${OUT_DIR}/agent_id.txt" "${AGENT_ID}"
write_file "${OUT_DIR}/agent_id.source.txt" "${AGENT_ID_SOURCE}"

# 2) Fetch exact agent/events/profiles in run context
if [[ -n "${AGENT_ID}" ]]; then
  capture_cmd "agent" "garnetctl get agent '${AGENT_ID}'" || true

  capture_cmd "events_for_agent" "garnetctl list events --filter agent_id=${AGENT_ID} --newest 200" || true
  if [[ -f "${OUT_DIR}/events_for_agent.txt" ]]; then
    json_or_text "${OUT_DIR}/events_for_agent.txt" "${OUT_DIR}/events_for_agent"
  fi

  capture_cmd "profiles_for_agent" "garnetctl list profiles --agent-id '${AGENT_ID}' --last 200 --format json" || true
  if [[ -f "${OUT_DIR}/profiles_for_agent.txt" ]]; then
    json_or_text "${OUT_DIR}/profiles_for_agent.txt" "${OUT_DIR}/profiles_for_agent"
  fi
fi

# 3) Run-scoped profile for this exact GitHub run ID
PROFILE_STATUS="failed"
if [[ -n "${RUN_ID}" ]]; then
  if capture_with_retries "profile_for_run" 6 10 "garnetctl get profile --run-id '${RUN_ID}' --format json"; then
    if [[ -f "${OUT_DIR}/profile_for_run.txt" ]]; then
      json_or_text "${OUT_DIR}/profile_for_run.txt" "${OUT_DIR}/profile_for_run"
    fi
    PROFILE_STATUS="ok"
  else
    PROFILE_STATUS="failed"
  fi
fi

# 4) Fallback to profile list scoped to same agent, filtered to same run ID
if [[ "${PROFILE_STATUS}" != "ok" && -f "${OUT_DIR}/profiles_for_agent.json" && -n "${RUN_ID}" && "${HAS_JQ}" -eq 1 ]]; then
  if extract_profile_for_run_from_agent_profiles "${RUN_ID}" "${OUT_DIR}/profiles_for_agent.json" "${OUT_DIR}/profile_for_run.json"; then
    if jq -e . "${OUT_DIR}/profile_for_run.json" >/dev/null 2>&1; then
      write_file "${OUT_DIR}/profile_for_run.status" "ok_fallback"
      PROFILE_STATUS="ok_fallback"
    fi
  fi
fi

# 5) Optional merged policy snapshot for current workflow scope
if [[ -n "${REPOSITORY_ID}" && -n "${WORKFLOW_NAME}" ]]; then
  capture_cmd "network_policy_merged" "garnetctl get network-policy merged --repository-id '${REPOSITORY_ID}' --workflow-name '${WORKFLOW_NAME}'" || true
fi

# 6) Extract domains from exact run-scoped profile only
DOMAINS_TXT="${OUT_DIR}/domains_for_run.list.txt"
: > "${DOMAINS_TXT}"
if [[ -f "${OUT_DIR}/profile_for_run.json" ]]; then
  extract_domains_from_profile_json "${OUT_DIR}/profile_for_run.json" > "${DOMAINS_TXT}" || true
elif [[ -f "${OUT_DIR}/profile_for_run.txt" ]]; then
  # keep scope strict: parse only this run's profile output
  grep -Eo '([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}' "${OUT_DIR}/profile_for_run.txt" \
    | tr '[:upper:]' '[:lower:]' \
    | sort -u > "${DOMAINS_TXT}" || true
fi

build_domains_summary "${PROFILE_STATUS}" "${DOMAINS_TXT}"

# 7) Correlation + machine summary
find "${OUT_DIR}" -maxdepth 1 -type f -exec basename {} \; | sort > "${OUT_DIR}/files.list.txt"

EVENTS_TOTAL="unknown"
if [[ "${HAS_JQ}" -eq 1 && -f "${OUT_DIR}/events_for_agent.json" ]]; then
  EVENTS_TOTAL="$(jq -r '
    if type == "array" then length
    elif type == "object" and (.items | type) == "array" then (.items | length)
    elif type == "object" and (.events | type) == "array" then (.events | length)
    elif type == "object" and (.data | type) == "array" then (.data | length)
    else 0 end
  ' "${OUT_DIR}/events_for_agent.json" 2>/dev/null || echo unknown)"
fi

DOMAINS_COUNT=0
if [[ -f "${DOMAINS_TXT}" ]]; then
  DOMAINS_COUNT="$(wc -l < "${DOMAINS_TXT}" | tr -d ' ')"
fi

{
  echo "# Garnet Runtime Correlation"
  echo ""
  echo "- generated_at: $(cat "${OUT_DIR}/generated_at.txt")"
  echo "- run_id: ${RUN_ID:-unknown}"
  echo "- repository_id: ${REPOSITORY_ID:-unknown}"
  echo "- workflow_name: ${WORKFLOW_NAME:-unknown}"
  echo "- agent_id: ${AGENT_ID:-unknown}"
  echo "- agent_id_source: ${AGENT_ID_SOURCE}"
  echo "- total_events (agent scope): ${EVENTS_TOTAL}"
  echo "- profile_for_run_status: ${PROFILE_STATUS}"
  echo "- domains_for_run_status: $(cat "${OUT_DIR}/domains_for_run.status")"
  echo ""
  echo "## Run-Scoped Domain Summary"
  cat "${OUT_DIR}/domains_for_run.md"
  echo ""
  echo "## Captured Files"
  sed 's/^/- /' "${OUT_DIR}/files.list.txt"
} > "${OUT_DIR}/correlation.md"

if [[ "${HAS_JQ}" -eq 1 ]]; then
  jq -n \
    --arg generated_at "$(cat "${OUT_DIR}/generated_at.txt")" \
    --arg run_id "${RUN_ID}" \
    --arg repository_id "${REPOSITORY_ID}" \
    --arg workflow_name "${WORKFLOW_NAME}" \
    --arg agent_id "${AGENT_ID}" \
    --arg agent_id_source "${AGENT_ID_SOURCE}" \
    --arg events_total "${EVENTS_TOTAL}" \
    --arg profile_for_run_status "${PROFILE_STATUS}" \
    --arg domains_for_run_status "$(cat "${OUT_DIR}/domains_for_run.status")" \
    --argjson domains "$(jq -R -s 'split("\n") | map(select(length > 0))' "${DOMAINS_TXT}")" \
    --argjson files "$(jq -R -s 'split("\n") | map(select(length > 0))' "${OUT_DIR}/files.list.txt")" \
    '{
      generated_at: $generated_at,
      run_id: $run_id,
      repository_id: $repository_id,
      workflow_name: $workflow_name,
      agent_id: (if ($agent_id | length) > 0 then $agent_id else null end),
      agent_id_source: $agent_id_source,
      events_total: ($events_total | tonumber? // $events_total),
      profile_for_run_status: $profile_for_run_status,
      domains_for_run_status: $domains_for_run_status,
      domains_for_run: $domains,
      files: $files
    }' > "${OUT_DIR}/summary.json"
fi

{
  echo "generated_at=$(cat "${OUT_DIR}/generated_at.txt")"
  echo "run_id=${RUN_ID}"
  echo "repository_id=${REPOSITORY_ID}"
  echo "workflow_name=${WORKFLOW_NAME}"
  echo "agent_id=${AGENT_ID}"
  echo "profile_for_run_status=${PROFILE_STATUS}"
  echo "domains_for_run_status=$(cat "${OUT_DIR}/domains_for_run.status")"
  echo "domains_for_run_count=${DOMAINS_COUNT}"
} > "${OUT_DIR}/summary.txt"

{
  echo "# Claude Runtime Brief"
  echo ""
  echo "- run_url: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${RUN_ID:-unknown}"
  echo "- event: ${GITHUB_EVENT_NAME:-unknown}"
  echo "- snapshot_dir: ${OUT_DIR}"
  echo ""
  echo "## Primary Question"
  echo "For run_id ${RUN_ID}, what domains appear in that run's profile?"
  echo ""
  echo "## Required Commands (run-scoped only)"
  echo '- `garnetctl get profile --run-id "${GITHUB_RUN_ID}" --format json`'
  echo '- `garnetctl list agent --newest 20 --output json`'
  echo '- `garnetctl list profiles --agent-id "<resolved_agent_id>" --last 200 --format json`'
  echo ""
  echo "## Files"
  sed 's/^/- /' "${OUT_DIR}/files.list.txt"
  echo ""
  echo "## Run-Scoped Domains"
  cat "${OUT_DIR}/domains_for_run.md"
} > "${OUT_DIR}/claude_runtime_brief.md"

log "Snapshot complete for run_id=${RUN_ID}, domains=$(wc -l < "${DOMAINS_TXT}" | tr -d ' ')"
