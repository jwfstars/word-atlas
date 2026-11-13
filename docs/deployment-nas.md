# 部署到 NAS（飞牛 fnOS）· 实操记录

> 目标机：`192.168.50.191`（飞牛 fnOS，主机名 `N3160`，x86_64，Docker 28.5.2 + Compose v2.40.3）
> 线上地址：**http://192.168.50.191:8098/**
> 部署位置：**`/vol2/word-atlas`**（只放构建产物，源码仍留在开发机）

## 1. 选盘：为什么是 /vol2

部署前实测的磁盘余量：

| 挂载点 | 容量 | 已用 | 可用 | 结论 |
| --- | --- | --- | --- | --- |
| `/`（系统盘 sdb2） | 58G | 16G | 39G | 不碰系统盘 |
| `/vol1` | 699G | 657G | **41G（95%）** | 紧张，只够一次，不做首选 |
| `/vol2` | 466G | 208G | **258G** | ✅ 采用 |
| `/vol3` | 954G | 37G | 916G | 备用（再涨就在这） |

站点体积：`dist/` ≈ **665 MB / 36,753 个文件**（`du` 实占 717 MB，含文件系统块开销）——
插画 199 MB、缩略图 84 MB、英美发音与例句音频 418 MB。
按「空间不够就换盘」的要求，部署目录放在 `/vol2`；如果要换到 `/vol3`，只改 `NAS_PATH`
（`/vol3/word-atlas`）并重新 `rsync`，其余不变。

> 注意：`/vol2`、`/vol3` 的根目录属于 `root`（`d---------`）。建目录需要一次 sudo，
> 之后 `jwfstars` 对该目录可读写，日常同步不需要 root。

```bash
sudo mkdir -p /vol2/word-atlas && sudo chown jwfstars:Users /vol2/word-atlas
```

## 2. 目录结构

```
/vol2/word-atlas/
├── dist/                 # npm run build 的产物，只读挂载给容器
│   ├── index.html
│   ├── assets/           # 构建产物（带 hash，可长缓存）
│   ├── atlas/            # index.json + entries/ + img/ + thumb/ + audio/
│   ├── brand/  sfx/  sw.js  manifest.webmanifest
├── nginx.conf            # 站点配置（挂到 /etc/nginx/conf.d/default.conf）
└── docker-compose.yml    # nginx:alpine，端口 8098
```

源码、`node_modules`、`.local/` 私人词库都不上 NAS——NAS 上只跑静态文件。

## 3. 容器

`/vol2/word-atlas/docker-compose.yml`：

```yaml
services:
  word-atlas:
    image: nginx:alpine
    container_name: word-atlas
    restart: unless-stopped
    ports:
      - "8098:80"
    volumes:
      - ./dist:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    environment:
      - TZ=Asia/Shanghai
```

`/vol2/word-atlas/nginx.conf` 的要点（完整内容见该文件）：

- **入口与 `sw.js` 不缓存**，发版立刻生效；
- `/assets/`（带 hash）1 年 `immutable`，插画/音频 180 天，`/atlas/entries/` 1 天，
  `/atlas/index.json` 1 小时——换词库不用用户清缓存；
- 开启 gzip（`index.json` 500 KB → 约 120 KB），音频/图片本来就是压缩格式，不重复压；
- `try_files ... /index.html` + 404 兜底，hash 路由刷新不会白屏；
- 保留 `Accept-Ranges`，音频可以拖动进度条（实测 `Range: bytes=0-99` → `206`）。

启动：

```bash
sudo docker compose -f /vol2/word-atlas/docker-compose.yml up -d
```

容器与既有服务（english-tube、LibreChat、imgforge 等）并存，没有复用它 5670 的 nginx 代理，
拿的是独立端口 **8098**（部署前已用 `/dev/tcp` 探测，未被占用）。

## 4. 发布 / 更新

在开发机上：

```bash
npm run build
NAS_USER=jwfstars NAS_PASS='<密码>' ./scripts/deploy-nas.sh    # 或先配好 SSH 公钥，省略 NAS_PASS
```

`scripts/deploy-nas.sh` 做的事：同步 `dist/` → 远端 `curl` 自检 `index.html` 与 `atlas/index.json`。
rsync 是增量的，第二次更新只传改动的文件（发布新版本通常只有几 MB）。

不想用脚本时就一条命令：

```bash
rsync -rltD --no-owner --no-group \
  -e "ssh -p 22" dist/ jwfstars@192.168.50.191:/vol2/word-atlas/dist/
```

> 建议给这个账号配 SSH 公钥（`ssh-copy-id -p 22 jwfstars@192.168.50.191`），
> 以后发布完全免密。本次部署**没有**改动 NAS 上的 authorized_keys。

## 5. 验收记录（实测）

```text
GET /                     → 200 text/html            1981 B
GET /atlas/index.json     → 200 application/json     （gzip）
GET /atlas/thumb/library.webp → 200 image/webp        13.7 KB
GET /atlas/img/library.webp   → 200 image/webp        28.7 KB
GET /atlas/audio/uk/library.mp3 → 200 audio/mpeg      Accept-Ranges: bytes
GET /atlas/audio/... Range 0-99 → 206
GET /assets/index-*.js     → Cache-Control: max-age=31536000, public, immutable
GET /sw.js                 → Cache-Control: no-cache
GET /nope/nothing          → 200 index.html（单页兜底）
```

浏览器实测（Playwright）：首屏正常、词条面板打开正常、点「标记为已掌握」后 chip 变「已掌握」、
按钮变「已掌握 · 点此撤销」、`localStorage` 出现 `"k":1`、「我的」页统计与「手动标记」面板同步，
控制台 0 报错。

## 6. 已知限制 / 可选加强

1. **HTTP 下没有 PWA 能力**。Service Worker 只在安全上下文（HTTPS 或 localhost）注册，所以
   `http://192.168.50.191:8098/` 能正常用，但**离线缓存、添加到主屏幕**不生效。
   想开：在 fnOS 里加一层反向代理 + 证书（自签或内网 CA），例如
   `https://words.home.lan/` → `http://127.0.0.1:8098`。
2. **放在子路径下**（例如 `http://...:5666/words/`）必须在**构建时**指定 base，否则资源 404：
   ```bash
   ATLAS_BASE=/words/ npm run build
   ```
   同时 nginx 侧要把 `location /words/` 指到 `dist/` 并 `try_files $uri $uri/ /words/index.html;`。
3. **私人词库不上线**。`loadPrivateAtlas` 依赖 Vite 的 `/local/catalog.json` 中间件，只有
   `npm run dev` 才有；线上只有开放词库（7,298 词）。
4. **不要 `rm -rf dist` 后立刻访问**：容器是只读挂载，重建期间会短暂 404，正常现象。
5. **端口冲突**：换端口只改 `docker-compose.yml` 的 `8098:80`，`docker compose up -d` 重建即可。

## 7. 排错

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 403 Forbidden | 目录/文件对容器内 nginx 用户不可读 | `chmod -R a+rX /vol2/word-atlas/dist` |
| 页面白，控制台 `index.json 404` | 同步漏了 `atlas/`，或 base 与访问路径不一致 | 重跑 rsync；检查 `ATLAS_BASE` |
| 图片/音频 404，其余正常 | 文件确实没上传（量大易漏） | `rsync` 加 `--stats` 对一下文件数 36,753 |
| `docker: permission denied` | 当前用户不在 docker 组 | 用 `sudo docker ...` |
| SSH 密码连续失败后 `Permission denied` | fnOS 有失败次数限制 | 等 20-30 秒再试，且每次只用一次密码尝试 |
