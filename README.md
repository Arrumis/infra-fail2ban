# infra-fail2ban

fail2ban を Docker で動かすためのリポジトリです。
リバースプロキシのアクセスログや SSH ログを見て、攻撃元 IP アドレスを遮断します。

## 使い方

```bash
cp .env.example .env.local
./scripts/init-runtime.sh
docker compose --env-file .env.local up -d --build
```

設定確認:

```bash
docker exec infra-fail2ban-fail2ban-1 fail2ban-client -t
docker exec infra-fail2ban-fail2ban-1 fail2ban-client ping
```

## 変更する値

`.env.example` は公開用の見本です。実際の値は `.env.local` に書きます。

- `PROXY_LOG_DIR`: リバースプロキシのログ保存先です。
- `DISCORD_WEBHOOK_URL`: Discord へ通知する場合だけ設定します。
- `DISCORD_NOTIFY_CONTAINER`: fail2ban コンテナが複数ある場合だけ指定します。
- `INFRA_FAIL2BAN__...`: 親リポジトリからまとめて設定するときに使います。

## 監視内容

主な監視対象:

- WordPress への攻撃
- Basic 認証の失敗
- 404 多発
- 悪質な URL 探索
- 悪質な User-Agent
- SSH ログイン失敗
- OpenVPN 認証失敗
- 再犯 IP アドレス

`jail.local` の `ignoreip` では、ローカルアドレス、一般的な家庭内ネットワーク、Tailscale の IPv4 と IPv6 を除外しています。

## Discord 通知

通知を使う場合は `.env.local` に次を設定します。

```bash
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
```

通知スクリプトを手動実行します。

```bash
./scripts/docker-fail2ban-discord.sh
```

現在のユーザーの cron に毎時実行を入れます。

```bash
./scripts/install-discord-cron.sh
```

## データ

GitHub に上げるもの:

- `compose.yaml`
- `.env.example`
- `jail.local`
- `fail2ban.local`
- `action.d/`
- `filter.d/`
- `scripts/`
- `README.md`

GitHub に上げないもの:

- `.env.local`
- `runtime/` の実ログや通知状態

## 補足

- Docker の `DOCKER-USER` チェーンを使ってコンテナ宛て通信を遮断します。
- ホストの `/usr/sbin/iptables` はコンテナへ直接マウントしません。ホストとコンテナのライブラリ不一致を避けるためです。
