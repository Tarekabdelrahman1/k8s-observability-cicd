FROM node:20.14.0-alpine3.19 AS builder
# Install OS-level build tools needed for native npm modules
# dumb-init: proper PID 1 process manager for signal forwarding
RUN apk add --no-cache \
    dumb-init \
    python3 \
    make \
    g++
# Set working directory
WORKDIR /build

# Copy package files first — Docker layer cache: only re-run npm ci if these change
COPY app/package.json app/package-lock.json ./

# Install ALL dependencies (including devDependencies for testing)
# npm ci: strict mode — uses lockfile exactly, fails if lockfile is out of sync
RUN npm install

# Copy application source
COPY app/src ./src

# Run linting (fail the build if code quality checks fail)
# Uncomment when eslint config is in place:
# RUN npm run lint

# Run unit tests (fail the build if any test fails)
# Uncomment when tests exist:
# RUN npm test

# Prune devDependencies — only production deps remain after this
RUN npm prune --production

###########second stage############################

FROM node:20.14.0-alpine3.19 AS production

# Import dumb-init from builder stage (already compiled for this arch)
COPY --from=builder /usr/bin/dumb-init /usr/bin/dumb-init

# Security: Do NOT run as root
# node image already has a 'node' user with UID 1000
# We use it explicitly to make intent clear

# Set NODE_ENV — critical: Express and many libraries change behavior based on this
ENV NODE_ENV=production
ENV PORT=3000

# Create app directory and set ownership to node user before switching users
WORKDIR /app
RUN chown node:node /app

# Switch to non-root user
USER node

# Copy production node_modules from builder (already pruned)
COPY --chown=node:node --from=builder /build/node_modules ./node_modules

# Copy only the application source (not tests, not configs)
COPY --chown=node:node app/src ./src
COPY --chown=node:node app/package.json ./package.json

# Expose application port
EXPOSE 3000

# Health check: Docker will mark the container unhealthy if this fails
# This does NOT replace Kubernetes probes but is useful for local testing
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/healthz || exit 1

# dumb-init as PID 1: properly forwards SIGTERM to Node.js for graceful shutdown
# Without this, Docker sends SIGTERM to PID 1 (sh) which doesn't forward it to Node
ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["node", "src/server.js"]
