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
    log "ERROR: 必要なコマンドが見つかりません: $1"
    exit 1
  fi
}

current_timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

timestamp_to_epoch() {
  date -d "$1" '+%s' 2>/dev/null || true
}

duration_seconds_between() {
  local started_at="$1"
  local ended_at="$2"
  local started_epoch ended_epoch

  started_epoch="$(timestamp_to_epoch "${started_at}")"
  ended_epoch="$(timestamp_to_epoch "${ended_at}")"
  if [[ -z "${started_epoch}" || -z "${ended_epoch}" || "${ended_epoch}" -lt "${started_epoch}" ]]; then
    return
  fi

  printf '%s\n' "$((ended_epoch - started_epoch))"
}

format_duration() {
  local total_seconds="$1"
  if [[ ! "${total_seconds}" =~ ^[0-9]+$ ]]; then
    return
  fi

  local days hours minutes parts
  days=$((total_seconds / 86400))
  hours=$(((total_seconds % 86400) / 3600))
  minutes=$(((total_seconds % 3600) / 60))
  parts=()

  if [[ "${days}" -gt 0 ]]; then
    parts+=("${days}日")
  fi
  if [[ "${hours}" -gt 0 ]]; then
    parts+=("${hours}時間")
  fi
  if [[ "${minutes}" -gt 0 ]]; then
    parts+=("${minutes}分")
  fi
  if [[ "${#parts[@]}" -eq 0 ]]; then
    parts=("1分未満")
  fi

  printf '%s\n' "${parts[*]}"
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
    log "ERROR: fail2ban コンテナが見つかりません"
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

  jq \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg footer "Fail2ban Discord Bot (Hourly Report)" \
    '
      def make_embed($title; $color; $description):
        {title: $title, description: $description, color: $color, timestamp: $timestamp, footer: {text: $footer}};
      def count_text:
        if (.ban_count // "") != "" then " - 通算" + (.ban_count | tostring) + "回目" else "" end;
      def omitted_text($items):
        if ($items | length) > 50 then "\n...ほか " + (($items | length) - 50 | tostring) + "件" else "" end;
      def death_line:
        "- **`" + .ip + "`** ([**" + .jail + "**]) - 💀 **極刑執行 (1年BAN)**";
      def recidive_line:
        "- **`" + .ip + "`** ([**" + .jail + "**])" + count_text + " ⚠️";
      def ban_line:
        "- `" + .ip + "` ([" + .jail + "])" + count_text;
      def unban_line:
        "- `" + .ip + "` ([" + .jail + "]) - " + ((.ban_duration // .duration // "不明") | tostring);
      [.[] | select(.type == "ban" and .jail == "death-penalty")] as $death_bans |
      [.[] | select(.type == "ban" and .jail == "recidive")] as $recidive_bans |
      [.[] | select(.type == "ban" and .jail != "death-penalty" and .jail != "recidive")] as $normal_bans |
      [.[] | select(.type == "unban")] as $unbans |
      {embeds: [
        if ($death_bans | length) > 0 then
          make_embed(
            "💀 【極刑】Fail2ban 1年間BAN執行通知";
            10027008;
            "### 💀 極刑 Ban (" + ($death_bans | length | tostring) + "件)\n" + ($death_bans[:50] | map(death_line) | join("\n")) + omitted_text($death_bans)
          )
        else empty end,
        if ($recidive_bans | length) > 0 then
          make_embed(
            "🔒 【警告】Fail2ban 再犯者検出通知";
            16776960;
            "### 🔒 再犯 Ban (" + ($recidive_bans | length | tostring) + "件)\n" + ($recidive_bans[:50] | map(recidive_line) | join("\n")) + omitted_text($recidive_bans)
          )
        else empty end,
        if ($normal_bans | length) > 0 then
          make_embed(
            "🚫 Fail2ban Ban通知";
            16711680;
            "### 🚫 新規 Ban (" + ($normal_bans | length | tostring) + "件)\n" + ($normal_bans[:50] | map(ban_line) | join("\n")) + omitted_text($normal_bans)
          )
        else empty end,
        if ($unbans | length) > 0 then
          make_embed(
            "✅ Fail2ban Unban通知";
            65280;
            "### ✅ Unban (" + ($unbans | length | tostring) + "件)\n" + ($unbans[:50] | map(unban_line) | join("\n")) + omitted_text($unbans)
          )
        else empty end
      ]}
    ' <<< "${events_json}"
}

send_discord() {
  local payload="$1"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "INFO: 試験実行のため Discord へ送信しません"
    return 0
  fi

  if [[ -z "${WEBHOOK_URL}" ]]; then
    log "INFO: DISCORD_WEBHOOK_URL が未設定のため通知を省略しました"
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
    log "INFO: Discord 通知を送信しました"
    return 0
  fi

  log "ERROR: Discord 通知に失敗しました。HTTP ${status}"
  return 1
}

build_sample_payload() {
  local sample_started_at sample_ended_at sample_duration_seconds sample_duration_human sample_events_json
  sample_started_at="${DISCORD_NOTIFY_SAMPLE_STARTED_AT:-2026-05-06 10:15:00}"
  sample_ended_at="${DISCORD_NOTIFY_SAMPLE_ENDED_AT:-2026-05-13 12:45:00}"
  sample_duration_seconds="$(duration_seconds_between "${sample_started_at}" "${sample_ended_at}")"
  sample_duration_human="$(format_duration "${sample_duration_seconds}")"

  sample_events_json="$(
    jq -n \
      --arg normal_ban_ip "198.51.100.23" \
      --arg recidive_ban_ip "198.51.100.44" \
      --arg death_ban_ip "198.51.100.99" \
      --arg unban_ip "203.0.113.45" \
      --arg short_unban_ip "203.0.113.88" \
      --arg started_at "${sample_started_at}" \
      --arg ended_at "${sample_ended_at}" \
      --arg duration "${sample_duration_human}" \
      --argjson duration_seconds "${sample_duration_seconds:-null}" \
      '[
        {type: "ban", ip: $normal_ban_ip, jail: "wordpress", timestamp: $ended_at, ban_count: 2},
        {type: "ban", ip: $recidive_ban_ip, jail: "recidive", timestamp: $ended_at, ban_count: 5},
        {type: "ban", ip: $death_ban_ip, jail: "death-penalty", timestamp: $ended_at},
        {
          type: "unban",
          ip: $unban_ip,
          jail: "scan-404",
          timestamp: $ended_at,
          ban_started_at: $started_at,
          ban_duration: $duration,
          ban_duration_seconds: $duration_seconds
        },
        {
          type: "unban",
          ip: $short_unban_ip,
          jail: "basic",
          timestamp: $ended_at,
          ban_started_at: "2026-05-13 11:40:00",
          ban_duration: "1時間 5分",
          ban_duration_seconds: 3900
        }
      ]'
  )"

  build_embed_payload "${sample_events_json}"
}

main() {
  if [[ "${1:-}" == "--sample" || "${1:-}" == "sample" ]]; then
    require_command jq
    build_sample_payload
    exit 0
  fi

  require_command docker
  require_command jq
  require_command curl

  log "INFO: docker-fail2ban-discord.sh 開始"
  detect_fail2ban_container

  mkdir -p "${STATE_DIR}"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
      log "INFO: 別の通知処理が実行中のため終了します"
      exit 0
    fi
  fi

  if [[ ! -f "${BAN_DETAIL_FILE}" ]]; then
    printf '{}\n' > "${BAN_DETAIL_FILE}"
  fi

  local previous_json current_bans events_json new_json
  previous_json="$(cat "${BAN_DETAIL_FILE}")"
  if ! jq -e type >/dev/null 2>&1 <<< "${previous_json}"; then
    log "WARNING: 状態ファイルが壊れているため作り直します: ${BAN_DETAIL_FILE}"
    previous_json="{}"
  fi

  current_bans="$(get_current_bans)"
  events_json="[]"

  while IFS='|' read -r ip jail; do
    [[ -n "${ip:-}" && -n "${jail:-}" ]] || continue
    local key="${ip}|${jail}"
    if ! jq -e --arg key "${key}" 'has($key)' >/dev/null <<< "${previous_json}"; then
      log "INFO: 新しい BAN を検知しました: ${ip} (${jail})"
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
      local ban_started_at ban_ended_at ban_duration_seconds ban_duration_human
      ban_started_at="$(jq -r --arg key "${key}" '.[$key].seen_at // empty' <<< "${previous_json}")"
      ban_ended_at="$(current_timestamp)"
      ban_duration_seconds="$(duration_seconds_between "${ban_started_at}" "${ban_ended_at}")"
      ban_duration_human="$(format_duration "${ban_duration_seconds}")"
      log "INFO: BAN 解除を検知しました: ${ip} (${jail})"
      events_json="$(
        jq --arg ip "${ip}" \
          --arg jail "${jail}" \
          --arg ts "${ban_ended_at}" \
          --arg ban_started_at "${ban_started_at}" \
          --arg ban_duration "${ban_duration_human}" \
          --argjson ban_duration_seconds "${ban_duration_seconds:-null}" \
          '. += [{
            type: "unban",
            ip: $ip,
            jail: $jail,
            timestamp: $ts,
            ban_started_at: $ban_started_at,
            ban_duration: $ban_duration,
            ban_duration_seconds: $ban_duration_seconds
          }]' <<< "${events_json}"
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
    local first_seen_at
    first_seen_at="$(jq -r --arg key "${key}" '.[$key].seen_at // empty' <<< "${previous_json}")"
    if [[ -z "${first_seen_at}" ]]; then
      first_seen_at="$(current_timestamp)"
    fi
    new_json="$(
      jq --arg key "${key}" --arg ip "${ip}" --arg jail "${jail}" --arg ts "${first_seen_at}" \
        '. + {($key): {ip: $ip, jail: $jail, seen_at: $ts}}' <<< "${new_json}"
    )"
  done <<< "${current_bans}"

  printf '%s\n' "${new_json}" > "${BAN_DETAIL_FILE}"
  log "INFO: docker-fail2ban-discord.sh 完了"
}

main "$@"
