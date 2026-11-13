#!/usr/bin/env bash
# 把 dist/ 同步到 NAS 并做一次健康检查。
#   NAS_HOST=192.168.50.191 NAS_USER=jwfstars ./scripts/deploy-nas.sh
# 认证二选一：已配置 SSH 公钥（推荐），或本地执行 `export NAS_PASS=...`（走 sshpass）。
# 注意：走 NAS_PASS 时密码里不要带单引号。
set -euo pipefail

NAS_HOST="${NAS_HOST:-192.168.50.191}"
NAS_USER="${NAS_USER:?请先设置 NAS_USER}"
NAS_PORT="${NAS_PORT:-22}"
NAS_PATH="${NAS_PATH:-/vol2/word-atlas}"
BASE="${ATLAS_BASE:-/}"

cd "$(dirname "$0")/.."

if [ ! -d dist ]; then
  echo "== 构建（ATLAS_BASE=$BASE）"
  ATLAS_BASE="$BASE" npm run build
fi

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o NumberOfPasswordPrompts=1 -p $NAS_PORT"
if [ -n "${NAS_PASS:-}" ]; then
  SSH_CMD="sshpass -p '$NAS_PASS' $SSH_CMD"
fi

run() { eval "$SSH_CMD '$NAS_USER@$NAS_HOST' \"\$@\""; }

echo "== 同步 dist/ → $NAS_HOST:$NAS_PATH/dist"
rsync -rltD --no-owner --no-group --stats -e "$SSH_CMD" dist/ "$NAS_USER@$NAS_HOST:$NAS_PATH/dist/"

echo "== 健康检查"
run "curl -fsS -o /dev/null -w 'index %{http_code} %{size_download}B\n' http://127.0.0.1:8098/ ; curl -fsS -o /dev/null -w 'atlas %{http_code} %{size_download}B\n' http://127.0.0.1:8098/atlas/index.json"

echo "完成 → http://$NAS_HOST:8098/"
