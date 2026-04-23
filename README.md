# infra-fail2ban

fail2ban を独立リポジトリとして扱うための新しい正本候補です。旧 installer の filter / jail / action をそのまま repo に持ち、proxy の nginx ログだけを外部パスから受け取る形にしています。

## 起動

```bash
cp .env.example .env.local
./scripts/init-runtime.sh
docker compose --env-file .env.local up -d --build
```

## 前提

- reverse proxy の nginx ログ保存先を `PROXY_LOG_DIR` で指定する
- ホストの `iptables` と Docker ソケットにアクセスできること

## データ配置

- `action.d/`
- `filter.d/`
- `jail.local`
- `fail2ban.local`
- `runtime/`

## 補足

- 旧 `inst/fail2ban` の資産を repo 化した段階です
- Discord 通知連携はまだ別 repo / 別構成へ切り出していません

