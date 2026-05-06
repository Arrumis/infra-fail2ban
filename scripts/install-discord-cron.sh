#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="${SCRIPT_DIR}/docker-fail2ban-discord.sh"
MARKER="# docker-stack infra-fail2ban Discord notifier"
CRON_LINE="0 * * * * ${NOTIFIER}"

if [[ ! -x "${NOTIFIER}" ]]; then
  echo "通知スクリプトに実行権限がありません: ${NOTIFIER}" >&2
  exit 1
fi

tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}"' EXIT

crontab -l 2>/dev/null | grep -v -F "${MARKER}" | grep -v -F "${CRON_LINE}" > "${tmp_file}" || true
{
  cat "${tmp_file}"
  echo "${MARKER}"
  echo "${CRON_LINE}"
} | crontab -

echo "現在のユーザーの crontab に、fail2ban Discord 通知の毎時実行を登録しました。"
