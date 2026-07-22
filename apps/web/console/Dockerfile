# The Hop console (Next.js) for Cloud Run. Multi-stage: build the standalone server bundle, then run
# it on a slim node image. HOP_ACCOUNTD_URL (the account service's internal URL) is provided at
# runtime by the Cloud Run env; every /api/* request is proxied there (next.config.mjs).
# Build context is the repo root: docker build -f apps/web/console/Dockerfile .

FROM node:22-bookworm-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3 AS build
WORKDIR /app
COPY apps/web/console/package.json apps/web/console/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY apps/web/console/ ./
RUN npm run build

FROM node:22-bookworm-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=8080
# The standalone bundle carries its own minimal node_modules + server.js.
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
EXPOSE 8080
CMD ["node", "server.js"]
