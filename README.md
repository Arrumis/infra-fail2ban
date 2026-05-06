# infra-fail2ban

fail2ban を独立リポジトリとして扱うための新しい正本候補です。旧 installer の filter / jail / action をそのまま repo に持ち、proxy の nginx ログだけを外部パスから受け取る形にしています。

## 日本語メモ

GitHub のコミット一覧が英語で分かりにくい場合は、[コミット履歴の日本語メモ](docs/COMMIT_HISTORY_JA.md) を見てください。

## サンプル値の置き換え

`.env.example` は公開用の見本です。実際に使う値は `.env.local` に書きます。

- `PROXY_LOG_DIR` は reverse proxy のログディレクトリへ変更します
- 親 repo からまとめて使う場合は、`docker-stack-installer` の `stack.service.env.local` に `GLOBAL__PROXY_LOG_DIR` を書くのがおすすめです
- GitHub に上げられない個人パスや秘密情報は、この repo ではなく `.env.local` 側にだけ置きます
- Discord 通知を使う場合は `.env.local` に `DISCORD_WEBHOOK_URL` を書きます

## 起動

```bash
cp .env.example .env.local
./scripts/init-runtime.sh
docker compose --env-file .env.local up -d --build
```

## 前提

- reverse proxy の nginx ログ保存先を `PROXY_LOG_DIR` で指定する
- コンテナ内の `iptables` がホストの firewall rules を変更できること
- Docker ソケットにアクセスできること
- Discord 通知を使うホストに `jq` と `curl` があること

## Discord 通知

fail2ban の ban/unban 状態を定期的に読み取り、差分がある場合に Discord webhook へ送信できます。Webhook URL は秘密値なので `.env.local` にだけ置きます。

```bash
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
DISCORD_NOTIFY_STATE_DIR=./runtime/discord-notify
DISCORD_NOTIFY_LOG_FILE=./runtime/docker-fail2ban-discord.log
# 通常は未設定で自動検出します。複数の fail2ban コンテナがある場合だけ指定します。
DISCORD_NOTIFY_CONTAINER=
```

手動確認:

```bash
./scripts/docker-fail2ban-discord.sh
tail -n 50 runtime/docker-fail2ban-discord.log
```

cron で動かす場合は `scripts/docker-fail2ban-discord.cron.example` を参考にします。root の `/etc/cron.d` に置けない環境では、Docker を実行できるユーザーの crontab に登録しても動きます。

```bash
./scripts/install-discord-cron.sh
crontab -l | tail
```

## データ配置

- `action.d/`
- `filter.d/`
- `jail.local`
- `fail2ban.local`
- `runtime/`

## 補足

- 旧 `inst/fail2ban` の資産を repo 化した段階です
- Ubuntu 26.04 などホスト側 glibc が新しい環境では、ホストの `/usr/sbin/iptables` をコンテナへ bind mount しないでください。コンテナ内に入っている互換バイナリを使います
