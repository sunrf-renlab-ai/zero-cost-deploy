# Multi-stage Bun image. Fits in Render Free's 512 MB.
# Swap to oven/bun:1-alpine for ~40 MB smaller runtime layer if your app
# doesn't need glibc-only native deps.
#
# For Node.js apps, see references/render.md for the Node template.

FROM oven/bun:1 AS deps
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

FROM oven/bun:1 AS builder
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY . .
# Replace with your build command. If your app is pure runtime TS, you can
# skip the build step entirely and run `bun src/index.ts` from runtime.
RUN bun build src/index.ts --target=bun --outfile=dist/server.js

FROM oven/bun:1-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps    /app/node_modules ./node_modules
COPY --from=builder /app/dist          ./dist
# Copy anything else the app needs at runtime (e.g., public/, migrations/)
# COPY --from=builder /app/public ./public

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost:8080/healthz || exit 1
CMD ["bun", "run", "dist/server.js"]
