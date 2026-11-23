# 词光 Word Atlas · 静态站点镜像（Zeabur / 任意容器平台）
# 构建阶段只负责 npm ci + vite build，运行阶段是纯 nginx。
FROM node:22-alpine AS build
WORKDIR /app
ENV NODE_OPTIONS=--max-old-space-size=1536
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build

FROM nginx:alpine AS runtime
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080 80
# 健康检查：入口页 + 词库索引
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD wget -qO- http://127.0.0.1:8080/ >/dev/null && wget -qO- http://127.0.0.1:8080/atlas/index.json >/dev/null || exit 1
