#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_DIR}/.env.local" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_DIR}/.env.local"
  set +a
elif [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_DIR}/.env"
  set +a
fi

F2B_CONTAINER="${DISCORD_NOTIFY_CONTAINER:-${F2B_CONTAINER:-}}"
STATE_DIR="${DISCORD_NOTIFY_STATE_DIR:-${REPO_DIR}/runtime/discord-notify}"
LOG_FILE="${DISCORD_NOTIFY_LOG_FILE:-${REPO_DIR}/runtime/docker-fail2ban-discord.log}"
BAN_DETAIL_FILE="${BAN_DETAIL_FILE:-${STATE_DIR}/ban-details.json}"
LOCK_FILE="${DISCORD_NOTIFY_LOCK_FILE:-${STATE_DIR}/notify.lock}"
WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-${WEBHOOK_URL:-}}"
DRY_RUN="${DISCORD_NOTIFY_DRY_RUN:-false}"

resolve_repo_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "${REPO_DIR}" "$1" ;;
  esac
}

STATE_DIR="$(resolve_repo_path "${STATE_DIR}")"
LOG_FILE="$(resolve_repo_path "${LOG_FILE}")"
BAN_DETAIL_FILE="$(resolve_repo_path "${BAN_DETAIL_FILE}")"
LOCK_FILE="$(resolve_repo_path "${LOCK_FILE}")"

log() {
  mkdir -p "$(dirname "${LOG_FILE}")"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_FILE}"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "ERROR: required command not found: $1"
    exit 1
  fi
}

detect_fail2ban_container() {
  if [[ -n "${F2B_CONTAINER}" ]]; then
    return
  fi

  F2B_CONTAINER="$(
    docker ps \
      --filter label=com.docker.compose.service=fail2ban \
      --format '{{.Names}}' |
      head -1
  )"
  if [[ -z "${F2B_CONTAINER}" ]]; then
    F2B_CONTAINER="$(docker ps --format '{{.Names}}' | grep -i fail2ban | head -1 || true)"
  fi
  if [[ -z "${F2B_CONTAINER}" ]]; then
    log "ERROR: fail2ban container not found"
    exit 1
  fi
}

get_current_bans() {
  docker exec "${F2B_CONTAINER}" sh -lc '
    jails=$(fail2ban-client status | sed -n "s/.*Jail list:[[:space:]]*//p" | tr "," " ")
    for jail in $jails; do
      jail=$(echo "$jail" | xargs)
      [ -n "$jail" ] || continue
      fail2ban-client status "$jail" | sed -n "s/^.*Banned IP list:[[:space:]]*//p" | tr " " "\n" |
        awk -v jail="$jail" "NF { print \$1 \"|\" jail }"
    done
  ' 2>/dev/null | sort -u
}

build_embed_payload() {
  local events_json="$1"
  local title description color

  local ban_count unban_count
  ban_count="$(jq '[.[] | select(.type == "ban")] | length' <<< "${events_json}")"
  unban_count="$(jq '[.[] | select(.type == "unban")] | length' <<< "${events_json}")"

  title="Fail2ban update: ${ban_count} ban, ${unban_count} unban"
  color=16753920
  if [[ "${ban_count}" -gt 0 && "${unban_count}" -eq 0 ]]; then
    color=15158332
  elif [[ "${ban_count}" -eq 0 && "${unban_count}" -gt 0 ]]; then
    color=3066993
  fi

  description="$(
    jq -r '.[] | if .type == "ban" then "Ban `" + .ip + "` [" + .jail + "]" else "Unban `" + .ip + "` [" + .jail + "]" end' <<< "${events_json}" |
      head -50 |
      sed 's/^/- /'
  )"

  jq -n \
    --arg title "${title}" \
    --arg description "${description}" \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg footer "Fail2ban Discord notifier" \
    --argjson color "${color}" \
    '{embeds: [{title: $title, description: $description, color: $color, timestamp: $timestamp, footer: {text: $footer}}]}'
}

send_discord() {
  local payload="$1"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "INFO: dry-run enabled; Discord payload not sent"
    return 0
  fi

  if [[ -z "${WEBHOOK_URL}" ]]; then
    log "INFO: DISCORD_WEBHOOK_URL is not set; notification skipped"
    return 0
  fi

  local status
  status="$(
    curl -sS -o /tmp/docker-fail2ban-discord-response.txt -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -X POST \
      --data "${payload}" \
      "${WEBHOOK_URL}" || true
  )"

  if [[ "${status}" == "204" ]]; then
    log "INFO: Discord notification sent"
    return 0
  fi

  log "ERROR: Discord notification failed with HTTP ${status}"
  return 1
}

main() {
  require_command docker
  require_command jq
  require_command curl

  log "INFO: docker-fail2ban-discord.sh start"
  detect_fail2ban_container

  mkdir -p "${STATE_DIR}"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
      log "INFO: another notifier process is running; exiting"
      exit 0
    fi
  fi

  if [[ ! -f "${BAN_DETAIL_FILE}" ]]; then
    printf '{}\n' > "${BAN_DETAIL_FILE}"
  fi

  local previous_json current_bans events_json new_json
  previous_json="$(cat "${BAN_DETAIL_FILE}")"
  if ! jq -e type >/dev/null 2>&1 <<< "${previous_json}"; then
    log "WARNING: invalid state file; resetting ${BAN_DETAIL_FILE}"
    previous_json="{}"
  fi

  current_bans="$(get_current_bans)"
  events_json="[]"

  while IFS='|' read -r ip jail; do
    [[ -n "${ip:-}" && -n "${jail:-}" ]] || continue
    local key="${ip}|${jail}"
    if ! jq -e --arg key "${key}" 'has($key)' >/dev/null <<< "${previous_json}"; then
      log "INFO: new ban detected: ${ip} (${jail})"
      events_json="$(
        jq --arg ip "${ip}" --arg jail "${jail}" --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
          '. += [{type: "ban", ip: $ip, jail: $jail, timestamp: $ts}]' <<< "${events_json}"
      )"
    fi
  done <<< "${current_bans}"

  while read -r key; do
    [[ -n "${key}" ]] || continue
    local ip jail
    ip="$(jq -r --arg key "${key}" '.[$key].ip // ($key | split("|")[0])' <<< "${previous_json}")"
    jail="$(jq -r --arg key "${key}" '.[$key].jail // ($key | split("|")[1] // "unknown")' <<< "${previous_json}")"
    if ! grep -Fxq "${key}" <<< "${current_bans}"; then
      log "INFO: unban detected: ${ip} (${jail})"
      events_json="$(
        jq --arg ip "${ip}" --arg jail "${jail}" --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
          '. += [{type: "unban", ip: $ip, jail: $jail, timestamp: $ts}]' <<< "${events_json}"
      )"
    fi
  done <<< "$(jq -r 'keys[]?' <<< "${previous_json}")"

  if [[ "$(jq 'length' <<< "${events_json}")" -gt 0 ]]; then
    send_discord "$(build_embed_payload "${events_json}")"
  fi

  new_json="{}"
  while IFS='|' read -r ip jail; do
    [[ -n "${ip:-}" && -n "${jail:-}" ]] || continue
    local key="${ip}|${jail}"
    new_json="$(
      jq --arg key "${key}" --arg ip "${ip}" --arg jail "${jail}" --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
        '. + {($key): {ip: $ip, jail: $jail, seen_at: $ts}}' <<< "${new_json}"
    )"
  done <<< "${current_bans}"

  printf '%s\n' "${new_json}" > "${BAN_DETAIL_FILE}"
  log "INFO: docker-fail2ban-discord.sh complete"
}

main "$@"
