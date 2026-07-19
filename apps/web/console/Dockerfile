# The Hop console (Next.js) for Cloud Run. Multi-stage: build the standalone server bundle, then run
# it on a slim node image. HOP_ACCOUNTD_URL (the account service's internal URL) is provided at
# runtime by the Cloud Run env; every /api/* request is proxied there (next.config.mjs).
# Build context is the repo root: docker build -f apps/web/console/Dockerfile .

FROM node:22-bookworm-slim@sha256:bac8ff0b5302b06924a5e288fb4ceecef9c8bb0bb92515985d2efd51f0d7649e AS build
WORKDIR /app
COPY apps/web/console/package.json apps/web/console/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY apps/web/console/ ./
RUN npm run build

FROM node:22-bookworm-slim@sha256:bac8ff0b5302b06924a5e288fb4ceecef9c8bb0bb92515985d2efd51f0d7649e
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=8080
# The standalone bundle carries its own minimal node_modules + server.js.
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
EXPOSE 8080
CMD ["node", "server.js"]
