# Production-Grade CI/CD & GitOps Lifecycle

<img width="1536" height="1024" alt="image" src="https://github.com/user-attachments/assets/1f223cbc-5903-4ecc-a54c-f84eb092112b" />

<img width="1442" height="523" alt="image" src="https://github.com/user-attachments/assets/1e15cdd6-48dc-43f2-bc54-13b3da94c1bc" />

<img width="1901" height="590" alt="image" src="https://github.com/user-attachments/assets/d25e188d-e95a-49e1-bcfa-186611fb9e44" />



---

# SECTION 1 — ARCHITECTURE & REPOSITORY DIRECTORY LAYOUT

## 1.1 Architectural Overview

Before touching a file, understand what you're building:

```
Git Push ──► Jenkins Pipeline ──► Docker Build ──► Nexus Push ──► Trivy Scan ──► kubectl rollout
                                                                                       │
                                                                               Kubernetes Cluster
                                                                                       │
                                                                         ┌─────────────┼─────────────┐
                                                                         │             │             │
                                                                      Pod-1         Pod-2         Pod-3
                                                                         │             │             │
                                                                    /metrics      /metrics      /metrics
                                                                         │             │             │
                                                                    ServiceMonitor (Prometheus Operator)
                                                                         │
                                                                    Prometheus ──► Alertmanager ──► Slack
                                                                         │
                                                                      Grafana
```

**Infrastructure components and their roles:**
- **Jenkins**: Orchestrates the entire pipeline. Runs on a dedicated VM or K8s pod. Has Docker socket access and kubeconfig.
- **Nexus**: Acts as your private Docker registry (port 8082) AND Maven/npm proxy cache. Runs as a Docker container on a dedicated host.
- **Trivy**: Vulnerability scanner, runs as a CLI step inside the Jenkins pipeline — no separate server needed.
- **Kubernetes**: Target deployment environment. Nodes must trust the Nexus registry to pull images.

---

## 1.2 Exact Repository Directory Layout

```
k8s-observability-cicd/
│
├── app/                                    # Node.js application source
│   ├── src/
│   │   ├── server.js                       # Main Express application entrypoint
│   │   ├── metrics.js                      # Prometheus metrics definitions (prom-client)
│   │   └── routes/
│   │       ├── health.js                   # /healthz and /readyz endpoints
│   │       └── api.js                      # Business logic routes
│   ├── package.json                        # Exact dependency pinning (no ^ or ~)
│   ├── package-lock.json                   # Committed lockfile — mandatory
│   └── .dockerignore                       # Excludes node_modules, .git, tests
│
├── docker/
│   └── Dockerfile                          # Multi-stage, hardened Node.js Dockerfile
│
├── jenkins/
│   ├── Jenkinsfile                         # Declarative pipeline — the pipeline definition
│   └── jenkins-agent-setup.sh             # Bootstrap script for Jenkins agent node
│
├── k8s/
│   ├── namespace.yaml                      # Dedicated namespace: app-production
│   ├── app/
│   │   ├── deployment.yaml                 # 3-replica Deployment with imagePullSecrets
│   │   ├── service.yaml                    # ClusterIP Service exposing port 3000
│   │   └── nexus-pull-secret.yaml          # Template only — secret created via CLI
│   ├── monitoring/
│   │   ├── servicemonitor.yaml             # Prometheus ServiceMonitor for /metrics
│   │   ├── prometheusrule.yaml             # Alerting rules (existing, kept intact)
│   │   └── alertmanagerconfig.yaml         # Slack routing (existing, kept intact)
│   └── nexus/
│       ├── nexus-statefulset.yaml          # Optional: run Nexus in K8s
│       └── nexus-service.yaml              # NodePort service for Nexus
│
├── load-testing/
│   ├── load-generator.sh                   # Existing load script — unchanged
│   └── k6-load-test.js                     # Optional: k6 load test script
│
├── scripts/
│   ├── bootstrap-nexus-docker.sh           # Run Nexus as Docker container on host
│   ├── configure-insecure-registry.sh      # Apply daemon.json to all K8s nodes
│   └── generate-pull-secret.sh            # Wrapper to kubectl create secret
│
└── README.md
```

> **Critical rule:** `package-lock.json` MUST be committed. Your Dockerfile will use `npm ci` (not `npm install`), which requires the lockfile and guarantees reproducible builds. Never use `^` or `~` in production `package.json`.

---

## 1.3 Node.js Application Source Files

These must exist before the Dockerfile has anything to build. Here is the complete application.

check `app/src/server.js`

```javascript
'use strict';

const express = require('express');
const { register, collectDefaultMetrics, Counter, Histogram } = require('prom-client');

const app = express();
const PORT = process.env.PORT || 3000;

// Collect default Node.js runtime metrics (event loop lag, memory, CPU, GC)
collectDefaultMetrics({ prefix: 'nodejs_app_' });

// --- Custom Business Metrics ---

// Counter: total HTTP requests by method, route, and status code
const httpRequestCounter = new Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
});

// Histogram: request duration in seconds, with custom buckets
const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
});

// --- Middleware: record metrics for every request ---
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    const labels = {
      method: req.method,
      route: req.route ? req.route.path : req.path,
      status_code: res.statusCode,
    };
    httpRequestCounter.inc(labels);
    end(labels);
  });
  next();
});

app.use(express.json());

// --- Routes ---

// Kubernetes liveness probe
app.get('/healthz', (req, res) => {
  res.status(200).json({ status: 'alive', timestamp: new Date().toISOString() });
});

// Kubernetes readiness probe — checks actual app readiness
app.get('/readyz', (req, res) => {
  // In production: check DB connections, cache connections, etc.
  res.status(200).json({ status: 'ready', timestamp: new Date().toISOString() });
});

// Prometheus metrics scrape endpoint
app.get('/metrics', async (req, res) => {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).end(err.message);
  }
});

// Application root endpoint
app.get('/', (req, res) => {
  res.status(200).json({
    service: 'k8s-observability-app',
    version: process.env.APP_VERSION || 'unknown',
    build: process.env.BUILD_NUMBER || 'local',
  });
});

// Simulate a work endpoint (for load testing)
app.get('/api/work', (req, res) => {
  // Simulate variable latency
  const delay = Math.floor(Math.random() * 200);
  setTimeout(() => {
    res.status(200).json({ processed: true, delay_ms: delay });
  }, delay);
});

// --- Graceful shutdown ---
const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(JSON.stringify({
    level: 'info',
    event: 'server_started',
    port: PORT,
    timestamp: new Date().toISOString(),
  }));
});

const shutdown = (signal) => {
  console.log(JSON.stringify({
    level: 'info',
    event: 'shutdown_initiated',
    signal,
    timestamp: new Date().toISOString(),
  }));
  server.close(() => {
    console.log(JSON.stringify({ level: 'info', event: 'server_closed' }));
    process.exit(0);
  });
  // Force-kill after 10 seconds if graceful shutdown hangs
  setTimeout(() => {
    console.error('Graceful shutdown timed out. Forcing exit.');
    process.exit(1);
  }, 10000);
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

module.exports = app; // exported for testing
```

### `app/package.json`

```json
{
  "name": "k8s-observability-app",
  "version": "1.0.0",
  "description": "Production Node.js app with Prometheus metrics",
  "main": "src/server.js",
  "scripts": {
    "start": "node src/server.js",
    "test": "jest --forceExit --coverage",
    "lint": "eslint src/"
  },
  "dependencies": {
    "express": "4.18.2",
    "prom-client": "15.1.0"
  },
  "devDependencies": {
    "jest": "29.7.0",
    "supertest": "6.3.4",
    "eslint": "8.57.0"
  },
  "engines": {
    "node": ">=20.0.0"
  }
}
```

### `app/.dockerignore`

```
node_modules/
npm-debug.log*
.git/
.gitignore
.env
.env.*
coverage/
.nyc_output/
*.test.js
*.spec.js
__tests__/
README.md
.dockerignore
Dockerfile
```

---

# SECTION 2 — CONTAINERIZATION (DOCKER)

## 2.1 The Production Dockerfile

**Location:** `docker/Dockerfile`

This uses a multi-stage build. Stage 1 (`builder`) installs all dependencies including devDependencies so we can run tests and prune. Stage 2 (`production`) copies only the production-pruned `node_modules` and source into a minimal, non-root image.

```dockerfile

FROM node:20.14.0-alpine3.19 AS builder
# Install OS-level build tools needed for native npm modules
# dumb-init: proper PID 1 process manager for signal forwarding
RUN apk add --no-cache \
    dumb-init=1.2.5-r3 \
    python3=3.11.9-r0 \
    make=4.4.1-r2 \
    g++=13.2.1_git20231014-r0

# Set working directory
WORKDIR /build

# Copy package files first — Docker layer cache: only re-run npm ci if these change
COPY app/package.json app/package-lock.json ./

# Install ALL dependencies (including devDependencies for testing)
# npm ci: strict mode — uses lockfile exactly, fails if lockfile is out of sync
RUN npm ci --frozen-lockfile

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

# =============================================================================
# Stage 2: production
# Purpose: Minimal, non-root, hardened runtime image
# =============================================================================
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
```

> **Why `dumb-init`?** In a container, your process runs as PID 1. Linux sends SIGTERM to PID 1 during shutdown, but standard shells (`sh`, `bash`) do not forward signals to child processes. This means your Node.js `SIGTERM` handler is never called, and the app gets force-killed with `SIGKILL` after the timeout — causing in-flight requests to be dropped. `dumb-init` is a minimal init system that properly forwards signals, enabling graceful shutdown.

---

## 2.2 Local Build, Tag, and Verification Commands

Execute these from the **repository root** (`k8s-observability-cicd/`).

### Step 1: Build the image locally

```bash
# Build with explicit build context at repo root
# The Dockerfile references app/ so context must include it
docker build \
  --file docker/Dockerfile \
  --tag k8s-obs-app:local \
  --tag k8s-obs-app:$(git rev-parse --short HEAD) \
  --build-arg BUILDKIT_INLINE_CACHE=1 \
  --progress=plain \
  .
```

Expected output includes two stages. Total final image size should be under 150MB.

### Step 2: Inspect the image layers

```bash
# Verify the final image size
docker images k8s-obs-app

# Inspect that it runs as non-root (UID should be 1000, not 0)
docker inspect k8s-obs-app:local | jq '.[0].Config.User'
# Expected output: "node"

# Verify no secrets or dev files leaked into the image
docker run --rm k8s-obs-app:local ls -la /app
# Should show: src/ node_modules/ package.json — NO .env, NO test files
```

### Step 3: Run the container and validate all endpoints

```bash
# Run detached, map port 3000
docker run -d \
  --name obs-app-test \
  --env APP_VERSION=1.0.0 \
  --env BUILD_NUMBER=local-001 \
  -p 3000:3000 \
  k8s-obs-app:local

# Wait for the health check to pass
sleep 5

# Validate: application root
curl -s http://localhost:3000/ | jq .
# Expected: {"service":"k8s-observability-app","version":"1.0.0","build":"local-001"}

# Validate: liveness probe
curl -s http://localhost:3000/healthz | jq .
# Expected: {"status":"alive","timestamp":"..."}

# Validate: readiness probe
curl -s http://localhost:3000/readyz | jq .
# Expected: {"status":"ready","timestamp":"..."}

# CRITICAL VALIDATION: Prometheus /metrics endpoint
curl -s http://localhost:3000/metrics | head -50
# Expected output includes:
# # HELP nodejs_app_process_cpu_seconds_total ...
# # TYPE nodejs_app_process_cpu_seconds_total counter
# nodejs_app_process_cpu_seconds_total ...
# # HELP http_requests_total ...
# # HELP http_request_duration_seconds ...

# Generate some traffic so metrics have data
for i in $(seq 1 20); do
  curl -s http://localhost:3000/api/work > /dev/null
  curl -s http://localhost:3000/ > /dev/null
done

# Check that request metrics populated
curl -s http://localhost:3000/metrics | grep http_requests_total
# Expected: http_requests_total{method="GET",route="/api/work",status_code="200"} 20
#           http_requests_total{method="GET",route="/",status_code="200"} 20

# Clean up
docker stop obs-app-test && docker rm obs-app-test
```

### Step 4: Verify graceful shutdowm.

```bash
# Run interactively to watch signal handling
docker run --name obs-app-signal-test -p 3000:3000 k8s-obs-app:local &
DOCKER_PID=$!
sleep 3
# Send SIGTERM (what Kubernetes sends during pod termination)
docker stop obs-app-signal-test
# Watch logs — you should see:
# {"level":"info","event":"shutdown_initiated","signal":"SIGTERM",...}
# {"level":"info","event":"server_closed"}
# Container exits with code 0 (not 137, which would mean SIGKILL)
echo "Exit code: $?"
docker rm obs-app-signal-test
```

---

# SECTION 3 — PRIVATE REGISTRY SETUP (NEXUS)

## 3.1 Deployment Strategy Decision

We deploy Nexus as a **Docker container on a dedicated host** (not inside Kubernetes). This is intentional for a critical architectural reason: if your Kubernetes cluster is being bootstrapped or has a problem, you need your image registry to be independently operational so you can pull images to fix the cluster. A registry that lives inside the cluster it serves creates a circular dependency.

**Dedicated Nexus host requirements:**
- OS: Ubuntu 22.04 LTS
- CPU: 4 cores minimum
- RAM: 8 GB minimum (Nexus JVM is memory-hungry; it will OOM-kill under 4GB)
- Disk: 100 GB+ for `/nexus-data` (SSD preferred)
- IP: `192.168.1.50` (adjust to your environment — this value is used throughout)
- Ports open: `8081` (Nexus UI), `8082` (Docker hosted registry)

## 3.2 Bootstrap Nexus as a Docker Container

**File:** `scripts/bootstrap-nexus-docker.sh`

```bash
#!/usr/bin/env bash
# Run this script on the DEDICATED NEXUS HOST (192.168.1.50)
# NOT on a Kubernetes node

set -euo pipefail

NEXUS_VERSION="3.68.0"
NEXUS_DATA_DIR="/nexus-data"
NEXUS_HTTP_PORT="8081"
NEXUS_DOCKER_PORT="8082"

echo "==> Creating Nexus data directory"
sudo mkdir -p "${NEXUS_DATA_DIR}"
# UID 200 is the nexus user inside the official container
sudo chown -R 200:200 "${NEXUS_DATA_DIR}"
sudo chmod 750 "${NEXUS_DATA_DIR}"

echo "==> Pulling official Sonatype Nexus image"
docker pull sonatype/nexus3:${NEXUS_VERSION}

echo "==> Stopping any existing Nexus container"
docker stop nexus 2>/dev/null || true
docker rm   nexus 2>/dev/null || true

echo "==> Starting Nexus container"
docker run -d \
  --name nexus \
  --restart unless-stopped \
  --publish ${NEXUS_HTTP_PORT}:8081 \
  --publish ${NEXUS_DOCKER_PORT}:8082 \
  --volume ${NEXUS_DATA_DIR}:/nexus-data \
  --env INSTALL4J_ADD_VM_PARAMS="-Xms2703m -Xmx2703m -XX:MaxDirectMemorySize=2703m -Djava.util.prefs.userRoot=/nexus-data/javaprefs" \
  sonatype/nexus3:${NEXUS_VERSION}

echo "==> Nexus starting. Waiting for it to become ready (this takes 2-3 minutes)..."
until curl -s -o /dev/null -w "%{http_code}" http://localhost:${NEXUS_HTTP_PORT}/service/rest/v1/status | grep -q "200"; do
  echo "    Still waiting..."
  sleep 15
done

echo "==> Nexus is UP"
echo "==> Fetching initial admin password..."
# The admin password is written to a file on first boot
# It must be retrieved from the container's volume, not the host path, until nexus writes it
docker exec nexus cat /nexus-data/admin.password

echo ""
echo "==> Access Nexus at: http://192.168.1.50:${NEXUS_HTTP_PORT}"
echo "==> Docker registry will be at: http://192.168.1.50:${NEXUS_DOCKER_PORT}"
echo "==> Login with admin and the password shown above"
echo "==> You MUST change the admin password on first login via the UI wizard"
```

```bash
chmod +x scripts/bootstrap-nexus-docker.sh
# Copy to the Nexus host and execute:
scp scripts/bootstrap-nexus-docker.sh user@192.168.1.50:~/
ssh user@192.168.1.50 "bash ~/bootstrap-nexus-docker.sh"
```

---

## 3.3 Nexus UI Configuration — Step by Step

After running the bootstrap script, open `http://192.168.1.50:8081` in a browser.

### Step 1: Complete the Setup Wizard

1. Click **"Sign In"** top-right. Use username `admin` and the password printed by the bootstrap script.
2. The setup wizard appears. Click **"Next"**.
3. Set a new admin password: `YourStrongAdminPassword123!` — record this securely.
4. On the **"Anonymous Access"** screen — select **"Disable anonymous access"** (for security).
5. Click **"Finish"**.

### Step 2: Enable the Docker Bearer Token Realm

This is **mandatory** for Docker clients to authenticate via Bearer token (the standard Docker auth flow).

1. Navigate to: **Administration (gear icon) → Security → Realms**
2. In the **Available** column, find **"Docker Bearer Token Realm"**
3. Click the right-arrow `→` to move it to the **Active** column
4. Ensure the **Active** column order is:
   - Local Authenticating Realm
   - Local Authorizing Realm
   - Docker Bearer Token Realm
5. Click **"Save"**

### Step 3: Create the Docker Hosted Repository

This is your private registry — images you push go here.

1. Navigate to: **Administration → Repository → Repositories**
2. Click **"Create repository"**
3. Select recipe: **"docker (hosted)"**
4. Fill in the form exactly:

| Field | Value |
|---|---|
| Name | `docker-private` |
| HTTP | ✅ Enabled, Port: `8082` |
| HTTPS | ❌ Disabled (we use insecure for now) |
| Allow anonymous docker pull | ❌ Unchecked |
| Enable Docker V1 API | ❌ Unchecked |
| Deployment policy | `Allow redeploy` |
| Storage → Blob store | `default` |

5. Click **"Create repository"**

### Step 4: Create a Service Account for Jenkins

Do NOT use the admin account in your pipelines.

1. Navigate to: **Administration → Security → Users**
2. Click **"Create local user"**
3. Fill in:

| Field | Value |
|---|---|
| ID | `jenkins-publisher` |
| First Name | `Jenkins` |
| Last Name | `Publisher` |
| Email | `jenkins@internal.company.com` |
| Password | `JenkinsNexus$ecret456!` |
| Status | `Active` |
| Roles | `nx-anonymous` (we'll assign a proper role next) |

4. Navigate to: **Administration → Security → Roles**
5. Click **"Create role"** → **"Nexus role"**:

| Field | Value |
|---|---|
| Role ID | `docker-push-role` |
| Role Name | `Docker Push Role` |
| Description | `Allows pushing to docker-private repository` |

6. In the **Privileges** section, search for and add these exact privileges:
   - `nx-repository-view-docker-docker-private-add`
   - `nx-repository-view-docker-docker-private-edit`
   - `nx-repository-view-docker-docker-private-read`
   - `nx-repository-view-docker-docker-private-browse`

7. Save the role.
8. Go back to the `jenkins-publisher` user, remove `nx-anonymous`, add `docker-push-role`.

### Step 5: Verify Nexus Docker Registry is Reachable

```bash
# From the Jenkins host, confirm Nexus Docker port responds
curl -v http://192.168.1.50:8082/v2/
# Expected response:
# HTTP/1.1 401 Unauthorized
# WWW-Authenticate: Bearer realm="http://192.168.1.50:8081/service/rest/v1/security/docker/login",...
# This 401 is CORRECT — it means Docker auth negotiation is working
```

---

## 3.4 Configure Insecure Registry on All Nodes

Because we're not using HTTPS initially, Docker on every host that needs to push or pull from Nexus must be told to trust the insecure registry. This applies to:
- The **Jenkins agent host** (pushes images)
- **All Kubernetes nodes** — control-plane + all workers (pull images to run pods)

**File:** `scripts/configure-insecure-registry.sh`

Run this script on **each node individually** (Jenkins host + all K8s nodes):

```bash
#!/usr/bin/env bash
# Run as root or with sudo on EACH host that needs to reach Nexus
# Arguments: $1 = Nexus host IP and port, e.g., "192.168.1.50:8082"

set -euo pipefail

NEXUS_REGISTRY="${1:-192.168.1.50:8082}"
DAEMON_JSON="/etc/docker/daemon.json"

echo "==> Configuring insecure registry: ${NEXUS_REGISTRY}"

# Preserve any existing daemon.json config by merging (if file exists)
if [ -f "${DAEMON_JSON}" ]; then
  echo "==> Existing daemon.json found — merging"
  # Use python3 to safely merge JSON (available on Ubuntu)
  python3 -c "
import json, sys

with open('${DAEMON_JSON}', 'r') as f:
    config = json.load(f)

registries = config.get('insecure-registries', [])
if '${NEXUS_REGISTRY}' not in registries:
    registries.append('${NEXUS_REGISTRY}')
config['insecure-registries'] = registries

# Ensure log settings for production
config.setdefault('log-driver', 'json-file')
config.setdefault('log-opts', {'max-size': '100m', 'max-file': '3'})

with open('${DAEMON_JSON}', 'w') as f:
    json.dump(config, f, indent=2)
print('Done:', json.dumps(config, indent=2))
"
else
  echo "==> Creating new daemon.json"
  cat > "${DAEMON_JSON}" <<EOF
{
  "insecure-registries": ["${NEXUS_REGISTRY}"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF
fi

echo "==> daemon.json contents:"
cat "${DAEMON_JSON}"

echo "==> Reloading Docker daemon (zero-downtime reload)"
systemctl daemon-reload
systemctl restart docker

echo "==> Waiting for Docker to come back up..."
sleep 5
docker info | grep -A5 "Insecure Registries"
echo "==> Done. Registry ${NEXUS_REGISTRY} is now trusted as insecure."
```

Execute on each host:

```bash
# On Jenkins agent host:
sudo bash scripts/configure-insecure-registry.sh 192.168.1.50:8082

# On Kubernetes control-plane node:
ssh user@k8s-control-plane "sudo bash /tmp/configure-insecure-registry.sh 192.168.1.50:8082"

# On each Kubernetes worker node (repeat for each):
ssh user@k8s-worker-1 "sudo bash /tmp/configure-insecure-registry.sh 192.168.1.50:8082"
ssh user@k8s-worker-2 "sudo bash /tmp/configure-insecure-registry.sh 192.168.1.50:8082"
# ... etc
```

### Verify the insecure registry from a K8s node:

```bash
# SSH to any worker node and test pulling from Nexus
ssh user@k8s-worker-1
docker login 192.168.1.50:8082 -u jenkins-publisher -p 'JenkinsNexus$ecret456!'
# Expected: Login Succeeded
docker pull 192.168.1.50:8082/k8s-obs-app:latest 2>&1 || echo "Pull failed — image not yet pushed. Auth worked if no auth error."
```

---

## 3.5 Jenkins Installation Prerequisites

### Install Jenkins (Debian/Ubuntu — dedicated Jenkins host)

```bash
# Install Java 17 (required for Jenkins LTS)
sudo apt update
sudo apt install -y openjdk-17-jdk

# Add Jenkins repository
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  | sudo tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null

echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc]" \
  "https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

sudo apt update
sudo apt install -y jenkins=2.462.1

sudo systemctl enable jenkins
sudo systemctl start jenkins

# Fetch initial admin password
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

### Install Docker on Jenkins host (so pipeline can run Docker commands)

```bash
# Install Docker Engine
curl -fsSL https://get.docker.com | sudo bash

# Add jenkins user to docker group (so Jenkins can run docker without sudo)
sudo usermod -aG docker jenkins

# Apply insecure registry for Nexus
sudo bash scripts/configure-insecure-registry.sh 192.168.1.50:8082

# IMPORTANT: Restart Jenkins after adding to docker group
sudo systemctl restart jenkins
```

### Install Trivy on Jenkins host

```bash
# Trivy: vulnerability scanner by Aqua Security
sudo apt install -y wget apt-transport-https gnupg lsb-release

wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
  | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb \
  $(lsb_release -sc) main" \
  | sudo tee /etc/apt/sources.list.d/trivy.list

sudo apt update
sudo apt install -y trivy

# Verify
trivy --version
# Expected: Version: 0.52.x
```

### Install kubectl on Jenkins host

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

### Required Jenkins Plugins

After Jenkins is up, navigate to **Manage Jenkins → Plugins → Available plugins** and install:

| Plugin | Purpose |
|---|---|
| `Docker Pipeline` | `docker.build()`, `docker.withRegistry()` DSL |
| `Docker Commons Plugin` | Shared Docker infra |
| `Credentials Binding Plugin` | `withCredentials` block |
| `Git Plugin` | SCM checkout |
| `Pipeline: Stage View` | Visual pipeline stages |
| `Blue Ocean` | Modern pipeline UI (optional but excellent) |
| `Kubernetes CLI Plugin` | `withKubeConfig` DSL |

After installing plugins, **restart Jenkins**: `sudo systemctl restart jenkins`

---

## 3.6 Store Credentials in Jenkins

Navigate to **Manage Jenkins → Credentials → System → Global credentials → Add Credential**.

### Credential 1: Nexus Docker Registry Login

| Field | Value |
|---|---|
| Kind | `Username with password` |
| Scope | `Global` |
| Username | `jenkins-publisher` |
| Password | `JenkinsNexus$ecret456!` |
| ID | `nexus-docker-credentials` |
| Description | `Nexus Docker registry login for jenkins-publisher` |

### Credential 2: Kubernetes Cluster Config

You need the kubeconfig from your control plane node.

```bash
# On the control-plane node, get the admin kubeconfig
cat /etc/kubernetes/admin.conf
```

Back in Jenkins:

| Field | Value |
|---|---|
| Kind | `Secret file` |
| Scope | `Global` |
| File | Upload the `admin.conf` file content |
| ID | `k8s-kubeconfig` |
| Description | `Kubeconfig for production cluster` |

# Production-Grade CI/CD & GitOps Lifecycle

---

# SECTION 4 — AUTOMATED CI/CD PIPELINE (JENKINSFILE)

## 4.1 Jenkins Pipeline Configuration

Before the Jenkinsfile, create the Jenkins Pipeline job:

1. **New Item** → name it `k8s-obs-app-pipeline` → type: **Pipeline**
2. Under **General**: check **"Discard old builds"** → keep max 10 builds
3. Under **Build Triggers**: check **"Poll SCM"** → Schedule: `H/2 * * * *` (every 2 minutes for development; use webhooks in production)
4. Under **Pipeline**: select **"Pipeline script from SCM"**
   - SCM: `Git`
   - Repository URL: `https://github.com/yourorg/k8s-observability-cicd.git`
   - Branch: `*/main`
   - Script Path: `jenkins/Jenkinsfile`
5. Click **Save**

## 4.2 The Complete Declarative Jenkinsfile

**File:** `jenkins/Jenkinsfile`

```groovy
// =============================================================================
// Production-Ready Declarative Jenkins Pipeline
// Project: k8s-observability-cicd
// Purpose: Build → Scan → Push → Deploy
// =============================================================================

pipeline {

  // ---------------------------------------------------------------------------
  // AGENT: Run on any available agent with Docker capability
  // In a real cluster, you'd label agents: agent { label 'docker-agent' }
  // ---------------------------------------------------------------------------
  agent any

  // ---------------------------------------------------------------------------
  // ENVIRONMENT: All values defined once, referenced everywhere
  // Sensitive values come from Jenkins Credential Store — NEVER hardcoded
  // ---------------------------------------------------------------------------
  environment {
    // ---- Registry Configuration ----
    NEXUS_HOST           = '192.168.1.50'
    NEXUS_DOCKER_PORT    = '8082'
    NEXUS_REGISTRY       = "${NEXUS_HOST}:${NEXUS_DOCKER_PORT}"

    // ---- Image Naming ----
    IMAGE_NAME           = 'k8s-obs-app'
    // Full image path including registry prefix
    IMAGE_FULL           = "${NEXUS_REGISTRY}/${IMAGE_NAME}"

    // ---- Kubernetes Deployment Target ----
    K8S_NAMESPACE        = 'app-production'
    K8S_DEPLOYMENT_NAME  = 'k8s-obs-app'

    // ---- Credentials IDs (must match what you stored in Jenkins) ----
    // These variables hold the credential ID strings, not the values themselves.
    // The actual secret values are injected by withCredentials() blocks.
    NEXUS_CRED_ID        = 'nexus-docker-credentials'
    KUBECONFIG_CRED_ID   = 'k8s-kubeconfig'

    // ---- Build Metadata ----
    // BUILD_NUMBER is a built-in Jenkins variable (auto-incrementing integer)
    GIT_COMMIT_SHORT     = sh(script: "git rev-parse --short HEAD 2>/dev/null || echo 'unknown'", returnStdout: true).trim()
    BUILD_TAG            = "${env.BUILD_NUMBER}-${GIT_COMMIT_SHORT}"

    // ---- Trivy Scan Configuration ----
    // EXIT_CODE=1: Fail the build on CRITICAL vulnerabilities
    // You can change to HIGH,CRITICAL once you've resolved initial findings
    TRIVY_SEVERITY       = 'CRITICAL'
    TRIVY_EXIT_CODE      = '1'
  }

  // ---------------------------------------------------------------------------
  // OPTIONS: Pipeline-level behavior settings
  // ---------------------------------------------------------------------------
  options {
    // Abort the build if it runs longer than 30 minutes total
    timeout(time: 30, unit: 'MINUTES')

    // Prefix all console output with timestamps — essential for debugging
    timestamps()

    // Color ANSI codes in output (requires AnsiColor plugin, optional)
    // ansiColor('xterm')

    // Don't run concurrent builds of the same pipeline
    // Prevents race conditions during deploy
    disableConcurrentBuilds()

    // Keep build artifacts and logs for last 10 successful builds, 20 total
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))
  }

  // ---------------------------------------------------------------------------
  // STAGES: The actual pipeline steps
  // ---------------------------------------------------------------------------
  stages {

    // =========================================================================
    // STAGE 1: Checkout
    // What: Fetch the latest code from the configured SCM branch
    // Why: Ensures we're always building from the canonical source of truth
    // =========================================================================
    stage('1. Checkout Code') {
      steps {
        // The declarative 'checkout scm' directive checks out the branch/commit
        // that triggered this build. It also sets GIT_COMMIT, GIT_BRANCH, etc.
        checkout scm

        // Print build context for log clarity
        sh '''
          echo "=========================================="
          echo "  BUILD CONTEXT"
          echo "=========================================="
          echo "  Jenkins Build Number : ${BUILD_NUMBER}"
          echo "  Build Tag            : ${BUILD_TAG}"
          echo "  Git Branch           : ${GIT_BRANCH}"
          echo "  Git Commit (short)   : ${GIT_COMMIT_SHORT}"
          echo "  Workspace            : ${WORKSPACE}"
          echo "  Target Registry      : ${NEXUS_REGISTRY}"
          echo "  Target Image         : ${IMAGE_FULL}"
          echo "  K8s Namespace        : ${K8S_NAMESPACE}"
          echo "=========================================="
        '''
      }
    }

    // =========================================================================
    // STAGE 2: Docker Build
    // What: Build the Docker image using our multi-stage Dockerfile
    // Why: Produces the immutable, versioned artifact for this build
    // Tags: We tag with BOTH a specific build tag AND 'latest' for rollback
    // =========================================================================
    stage('2. Docker Build') {
      steps {
        script {
          echo "Building Docker image: ${IMAGE_FULL}:${BUILD_TAG}"

          // docker.build() returns a Docker image object we can use in later stages
          // The second argument is the build context (root of repo) with the Dockerfile path
          env.DOCKER_BUILD_IMAGE = "${IMAGE_FULL}:${BUILD_TAG}"

          sh """
            docker build \\
              --file docker/Dockerfile \\
              --tag ${IMAGE_FULL}:${BUILD_TAG} \\
              --tag ${IMAGE_FULL}:latest \\
              --build-arg BUILDKIT_INLINE_CACHE=1 \\
              --label "build.number=${BUILD_NUMBER}" \\
              --label "build.commit=${GIT_COMMIT_SHORT}" \\
              --label "build.branch=${GIT_BRANCH}" \\
              --label "build.timestamp=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" \\
              .
          """

          // Verify the image was created
          sh "docker images ${IMAGE_FULL}:${BUILD_TAG}"

          // Quick smoke test: start the container, check /healthz, stop it
          // This catches failures where the image builds but the app crashes at startup
          sh """
            echo "--- Running post-build smoke test ---"
            docker run -d \\
              --name smoke-test-${BUILD_NUMBER} \\
              --env APP_VERSION=smoke-test \\
              --env BUILD_NUMBER=${BUILD_NUMBER} \\
              --publish 13000:3000 \\
              ${IMAGE_FULL}:${BUILD_TAG}

            # Wait for startup
            sleep 8

            # Test /healthz endpoint
            HTTP_STATUS=\$(curl -s -o /dev/null -w "%{http_code}" http://localhost:13000/healthz)
            if [ "\${HTTP_STATUS}" != "200" ]; then
              echo "SMOKE TEST FAILED: /healthz returned HTTP \${HTTP_STATUS}"
              docker logs smoke-test-${BUILD_NUMBER}
              docker stop smoke-test-${BUILD_NUMBER}
              docker rm  smoke-test-${BUILD_NUMBER}
              exit 1
            fi
            echo "SMOKE TEST PASSED: /healthz returned 200"

            # Test /metrics endpoint
            HTTP_STATUS=\$(curl -s -o /dev/null -w "%{http_code}" http://localhost:13000/metrics)
            if [ "\${HTTP_STATUS}" != "200" ]; then
              echo "SMOKE TEST FAILED: /metrics returned HTTP \${HTTP_STATUS}"
              docker stop smoke-test-${BUILD_NUMBER}
              docker rm  smoke-test-${BUILD_NUMBER}
              exit 1
            fi
            echo "SMOKE TEST PASSED: /metrics returned 200"

            # Clean up smoke test container
            docker stop smoke-test-${BUILD_NUMBER}
            docker rm  smoke-test-${BUILD_NUMBER}
            echo "--- Smoke test complete ---"
          """
        }
      }
    }

    // =========================================================================
    // STAGE 3: Vulnerability Scan (Trivy)
    // What: Scan the built image for known CVEs before pushing anywhere
    // Why: Shift-left security — catch vulnerabilities at build time, not in prod
    // Behavior: Fails build on CRITICAL CVEs. HIGH CVEs produce warnings.
    // =========================================================================
    stage('3. Vulnerability Scan (Trivy)') {
      steps {
        script {
          echo "Scanning image for vulnerabilities: ${IMAGE_FULL}:${BUILD_TAG}"

          // Ensure Trivy DB is up to date (cache in /tmp for Jenkins agent reuse)
          sh "trivy image --download-db-only --cache-dir /tmp/trivy-cache"

          // Scan 1: Table output for human-readable log
          sh """
            trivy image \\
              --cache-dir /tmp/trivy-cache \\
              --format table \\
              --exit-code 0 \\
              --severity HIGH,CRITICAL \\
              --no-progress \\
              ${IMAGE_FULL}:${BUILD_TAG} | tee /tmp/trivy-table-${BUILD_NUMBER}.txt
          """

          // Scan 2: JSON output for archiving and potential integration
          sh """
            trivy image \\
              --cache-dir /tmp/trivy-cache \\
              --format json \\
              --exit-code 0 \\
              --severity HIGH,CRITICAL \\
              --no-progress \\
              --output /tmp/trivy-report-${BUILD_NUMBER}.json \\
              ${IMAGE_FULL}:${BUILD_TAG}
          """

          // Archive the JSON report as a Jenkins build artifact
          archiveArtifacts artifacts: "/tmp/trivy-report-${BUILD_NUMBER}.json", allowEmptyArchive: false

          // Scan 3: Enforcement scan — FAILS the build on CRITICAL findings
          sh """
            echo "--- Enforcement scan (fails on ${TRIVY_SEVERITY}) ---"
            trivy image \\
              --cache-dir /tmp/trivy-cache \\
              --format table \\
              --exit-code ${TRIVY_EXIT_CODE} \\
              --severity ${TRIVY_SEVERITY} \\
              --no-progress \\
              --ignore-unfixed \\
              ${IMAGE_FULL}:${BUILD_TAG}
            echo "--- No ${TRIVY_SEVERITY} vulnerabilities found. Proceeding. ---"
          """
        }
      }
    }

    // =========================================================================
    // STAGE 4: Push to Nexus
    // What: Authenticate to Nexus and push both image tags
    // Why: Makes the image available for Kubernetes to pull on all nodes
    // Security: withCredentials() injects secrets as env vars, they are masked
    //           in logs and never stored in the Jenkinsfile
    // =========================================================================
    stage('4. Nexus Authentication & Push') {
      steps {
        // withCredentials: binds the Jenkins credential to NEXUS_USER and NEXUS_PASS
        // These variables ONLY exist within this block; Jenkins masks them in logs
        withCredentials([
          usernamePassword(
            credentialsId: "${NEXUS_CRED_ID}",
            usernameVariable: 'NEXUS_USER',
            passwordVariable: 'NEXUS_PASS'
          )
        ]) {
          sh """
            echo "==> Logging in to Nexus Docker registry"
            # --password-stdin: more secure than -p flag (no password in process list)
            echo "${NEXUS_PASS}" | docker login \\
              --username "${NEXUS_USER}" \\
              --password-stdin \\
              ${NEXUS_REGISTRY}

            echo "==> Pushing versioned tag: ${IMAGE_FULL}:${BUILD_TAG}"
            docker push ${IMAGE_FULL}:${BUILD_TAG}

            echo "==> Pushing latest tag: ${IMAGE_FULL}:latest"
            docker push ${IMAGE_FULL}:latest

            echo "==> Push complete. Logging out."
            docker logout ${NEXUS_REGISTRY}
          """
        }
      }
    }

    // =========================================================================
    // STAGE 5: Deploy to Kubernetes
    // What: Update the Deployment image and trigger a rolling update
    // Why: Automated, zero-downtime deployment without manual kubectl commands
    // Strategy: 'kubectl set image' updates the image tag in-place,
    //           triggering Kubernetes' own rolling update controller
    // =========================================================================
    stage('5. Deploy to Kubernetes') {
      steps {
        // withKubeConfig: mounts the kubeconfig secret as a temp file,
        // sets KUBECONFIG env var within the block, then deletes the file after
        withKubeConfig([credentialsId: "${KUBECONFIG_CRED_ID}"]) {
          sh """
            echo "==> Verifying cluster connectivity"
            kubectl cluster-info --request-timeout=10s

            echo "==> Verifying namespace exists: ${K8S_NAMESPACE}"
            kubectl get namespace ${K8S_NAMESPACE} || kubectl create namespace ${K8S_NAMESPACE}

            echo "==> Updating deployment image"
            kubectl set image deployment/${K8S_DEPLOYMENT_NAME} \\
              ${K8S_DEPLOYMENT_NAME}=${IMAGE_FULL}:${BUILD_TAG} \\
              --namespace=${K8S_NAMESPACE} \\
              --record=false

            echo "==> Annotating deployment with build metadata"
            kubectl annotate deployment/${K8S_DEPLOYMENT_NAME} \\
              --namespace=${K8S_NAMESPACE} \\
              --overwrite \\
              deployment.kubernetes.io/build-number="${BUILD_NUMBER}" \\
              deployment.kubernetes.io/git-commit="${GIT_COMMIT_SHORT}" \\
              deployment.kubernetes.io/image-tag="${BUILD_TAG}"

            echo "==> Waiting for rolling update to complete (timeout: 5 minutes)"
            kubectl rollout status deployment/${K8S_DEPLOYMENT_NAME} \\
              --namespace=${K8S_NAMESPACE} \\
              --timeout=300s

            echo "==> Deployment successful. Current pod status:"
            kubectl get pods \\
              --namespace=${K8S_NAMESPACE} \\
              --selector=app=${K8S_DEPLOYMENT_NAME} \\
              --output=wide

            echo "==> Deployment image verification:"
            kubectl get deployment/${K8S_DEPLOYMENT_NAME} \\
              --namespace=${K8S_NAMESPACE} \\
              --output=jsonpath='{.spec.template.spec.containers[0].image}'
            echo ""
          """
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // POST: Actions after all stages, regardless of success/failure
  // ---------------------------------------------------------------------------
  post {

    // Runs on every completion (success AND failure)
    always {
      script {
        echo "==> Cleaning up local Docker images to reclaim disk space"
        // Remove the specific build image to prevent disk bloat on the agent
        sh """
          docker rmi ${IMAGE_FULL}:${BUILD_TAG} 2>/dev/null || true
          docker rmi ${IMAGE_FULL}:latest 2>/dev/null || true
          # Remove dangling (untagged) images from multi-stage builds
          docker image prune -f 2>/dev/null || true
        """
      }
    }

    success {
      echo """
      ╔══════════════════════════════════════════════════════╗
      ║              PIPELINE SUCCESS                        ║
      ╠══════════════════════════════════════════════════════╣
      ║  Build    : ${BUILD_NUMBER}                          ║
      ║  Image    : ${IMAGE_FULL}:${BUILD_TAG}               ║
      ║  Deployed : ${K8S_NAMESPACE}/${K8S_DEPLOYMENT_NAME}  ║
      ╚══════════════════════════════════════════════════════╝
      """
    }

    failure {
      echo """
      ╔══════════════════════════════════════════════════════╗
      ║              PIPELINE FAILED                         ║
      ╠══════════════════════════════════════════════════════╣
      ║  Build       : ${BUILD_NUMBER}                       ║
      ║  Check logs above for the failing stage.             ║
      ║  Kubernetes was NOT updated (deploy stage not run).  ║
      ╚══════════════════════════════════════════════════════╝
      """
      // Optional: Add Slack notification here using the Slack Notifier plugin
      // slackSend(color: 'danger', message: "Build FAILED: ${env.JOB_NAME} #${env.BUILD_NUMBER}")
    }

    unstable {
      echo "Build marked UNSTABLE — check test results or scan findings"
    }
  }
}
```

---

## 4.3 Jenkins Pipeline Execution Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│  Jenkins Pipeline: k8s-obs-app-pipeline                              │
├──────────────┬──────────────┬────────────────┬──────────────────────┤
│ Stage 1      │ Stage 2      │ Stage 3        │ Stage 4              │
│ Checkout     │ Docker Build │ Trivy Scan     │ Nexus Push           │
│              │              │                │                      │
│ git checkout │ docker build │ trivy image    │ docker login         │
│ scm          │ --tag :BUILD │ --exit-code 1  │ docker push :BUILD   │
│              │ --tag :latest│ (CRITICAL only)│ docker push :latest  │
│              │ smoke test   │ archive JSON   │ docker logout        │
│              │ /healthz     │ report         │                      │
│              │ /metrics     │                │                      │
└──────────────┴──────────────┴────────────────┴──────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Stage 5: Deploy to Kubernetes                                        │
│                                                                      │
│ kubectl set image deployment/k8s-obs-app                             │
│         k8s-obs-app=192.168.1.50:8082/k8s-obs-app:BUILD_TAG         │
│ kubectl rollout status --timeout=300s                                │
│         (Kubernetes performs rolling update: 1 pod at a time)        │
│                                                                      │
│   [Old Pod 1] ──replace──► [New Pod 1]                              │
│   [Old Pod 2] ──replace──► [New Pod 2]                              │
│   [Old Pod 3] ──replace──► [New Pod 3]                              │
│                                                                      │
│   Zero downtime: replicas serve traffic during replacement           │
└─────────────────────────────────────────────────────────────────────┘
```

---

# SECTION 5 — KUBERNETES MANIFEST UPDATES

## 5.1 Namespace

**File:** `k8s/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: app-production
  labels:
    # Prometheus Operator uses this label to discover ServiceMonitors in this namespace
    monitoring: "true"
    environment: "production"
```

Apply it:
```bash
kubectl apply -f k8s/namespace.yaml
```

---

## 5.2 Create the imagePullSecret

Kubernetes nodes need credentials to pull your image from the private Nexus registry. This is configured as a Secret of type `kubernetes.io/dockerconfigjson`.

**Generate and apply the secret with this exact command:**

```bash
kubectl create secret docker-registry nexus-pull-secret \
  --docker-server=192.168.1.50:8082 \
  --docker-username=jenkins-publisher \
  --docker-password='JenkinsNexus$ecret456!' \
  --docker-email=jenkins@internal.company.com \
  --namespace=app-production \
  --dry-run=client -o yaml | kubectl apply -f -
```

> **Why `--dry-run=client -o yaml | kubectl apply -f -`?** This pattern is idempotent — you can run it multiple times without error. A plain `kubectl create secret` fails on re-run because the secret already exists. This generates the manifest and applies it, updating in place.

**Verify the secret was created:**
```bash
kubectl get secret nexus-pull-secret -n app-production
# NAME                TYPE                             DATA   AGE
# nexus-pull-secret   kubernetes.io/dockerconfigjson   1      5s

# Decode and inspect the .dockerconfigjson (should show your registry and credentials)
kubectl get secret nexus-pull-secret -n app-production \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq .
# Expected output:
# {
#   "auths": {
#     "192.168.1.50:8082": {
#       "username": "jenkins-publisher",
#       "password": "JenkinsNexus$ecret456!",
#       "email": "jenkins@internal.company.com",
#       "auth": "<base64-encoded-user:pass>"
#     }
#   }
# }
```

---

## 5.3 Complete Deployment Manifest

**File:** `k8s/app/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: k8s-obs-app
  namespace: app-production
  labels:
    app: k8s-obs-app
    version: "1.0.0"
    managed-by: jenkins
  annotations:
    # These annotations are updated by the Jenkins pipeline on each deploy
    # They give you auditability: who deployed what and when
    deployment.kubernetes.io/build-number: "0"
    deployment.kubernetes.io/git-commit: "initial"
    deployment.kubernetes.io/image-tag: "initial"

spec:
  # 3 replicas: ensures HA across 3 different nodes
  replicas: 3

  selector:
    matchLabels:
      app: k8s-obs-app

  # ---------------------------------------------------------------------------
  # Rolling Update Strategy
  # maxUnavailable: 0 = no pods go down before new ones are ready
  # maxSurge: 1      = one extra pod is created during the update
  # Effect: new pod starts, passes readiness check, THEN an old pod is removed
  # This guarantees zero-downtime deployments
  # ---------------------------------------------------------------------------
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1

  template:
    metadata:
      labels:
        app: k8s-obs-app
        version: "1.0.0"
      annotations:
        # Prometheus scrape config — Prometheus Operator reads ServiceMonitor,
        # but these annotations are kept for compatibility with annotation-based scraping
        prometheus.io/scrape: "true"
        prometheus.io/port: "3000"
        prometheus.io/path: "/metrics"

    spec:
      # ---------------------------------------------------------------------------
      # imagePullSecrets: tells Kubernetes which credentials to use to pull from Nexus
      # Must match the secret name created in Section 5.2
      # ---------------------------------------------------------------------------
      imagePullSecrets:
        - name: nexus-pull-secret

      # ---------------------------------------------------------------------------
      # Security Context (Pod-level)
      # runAsNonRoot: Kubernetes enforces non-root (complements the Dockerfile USER)
      # seccompProfile: restricts syscalls the pod can make
      # ---------------------------------------------------------------------------
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault

      # Ensure pods land on different nodes (anti-affinity for true HA)
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app
                      operator: In
                      values:
                        - k8s-obs-app
                topologyKey: kubernetes.io/hostname

      # ---------------------------------------------------------------------------
      # terminationGracePeriodSeconds: how long Kubernetes waits for graceful shutdown
      # before sending SIGKILL. Must be >= your app's shutdown timeout (we set 10s)
      # ---------------------------------------------------------------------------
      terminationGracePeriodSeconds: 30

      containers:
        - name: k8s-obs-app
          # IMAGE IS MANAGED BY JENKINS: do not manually edit this field
          # Jenkins pipeline runs: kubectl set image deployment/k8s-obs-app
          #                        k8s-obs-app=192.168.1.50:8082/k8s-obs-app:BUILD_TAG
          image: 192.168.1.50:8082/k8s-obs-app:latest

          # Always pull on every pod start — ensures we never run stale images
          # Use IfNotPresent only if network access to Nexus is unreliable
          imagePullPolicy: Always

          ports:
            - name: http
              containerPort: 3000
              protocol: TCP

          env:
            - name: NODE_ENV
              value: "production"
            - name: PORT
              value: "3000"
            # Pod metadata injected as env vars — visible in / endpoint response
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName

          # ---------------------------------------------------------------------------
          # Resource Limits and Requests
          # Requests: guaranteed resources; used for scheduling decisions
          # Limits: hard cap; pod is OOM-killed if it exceeds memory limit
          # Rule of thumb: set limit ~2x the observed peak of request
          # ---------------------------------------------------------------------------
          resources:
            requests:
              cpu: "100m"       # 0.1 CPU core
              memory: "128Mi"   # 128 megabytes
            limits:
              cpu: "500m"       # 0.5 CPU core
              memory: "256Mi"   # 256 megabytes

          # ---------------------------------------------------------------------------
          # Liveness Probe
          # What: Is the process alive? If this fails, Kubernetes RESTARTS the pod.
          # When to use: detect deadlocks, infinite loops, zombie processes
          # initialDelaySeconds: wait before first probe (let Node.js start up)
          # ---------------------------------------------------------------------------
          livenessProbe:
            httpGet:
              path: /healthz
              port: 3000
              scheme: HTTP
            initialDelaySeconds: 15
            periodSeconds: 20
            timeoutSeconds: 5
            successThreshold: 1
            failureThreshold: 3

          # ---------------------------------------------------------------------------
          # Readiness Probe
          # What: Is the pod ready to serve traffic? If this fails, pod is REMOVED
          #       from the Service's endpoint list (traffic stops going to it).
          # Critical for rolling updates: new pod MUST pass readiness before old is removed
          # This is what makes maxUnavailable: 0 actually work
          # ---------------------------------------------------------------------------
          readinessProbe:
            httpGet:
              path: /readyz
              port: 3000
              scheme: HTTP
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 3
            successThreshold: 1
            failureThreshold: 3

          # ---------------------------------------------------------------------------
          # Startup Probe
          # What: Is the application done initializing? Prevents liveness from killing
          #       a slow-starting pod before it's had a chance to come up.
          # Once startup probe succeeds once, it's disabled for the lifetime of the pod.
          # failureThreshold * periodSeconds = 60s max startup time
          # ---------------------------------------------------------------------------
          startupProbe:
            httpGet:
              path: /healthz
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 12
            successThreshold: 1

          # ---------------------------------------------------------------------------
          # Container Security Context
          # ---------------------------------------------------------------------------
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL

          # Writable tmp directory (needed by some Node.js operations)
          # readOnlyRootFilesystem: true requires explicit writable mounts
          volumeMounts:
            - name: tmp-dir
              mountPath: /tmp

      volumes:
        - name: tmp-dir
          emptyDir: {}
```

---

## 5.4 Service Manifest

**File:** `k8s/app/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: k8s-obs-app
  namespace: app-production
  labels:
    app: k8s-obs-app
    # This label is used by the ServiceMonitor's selector to discover this Service
    monitoring: "true"
spec:
  type: ClusterIP
  selector:
    # Must match the pod labels in the Deployment template
    app: k8s-obs-app
  ports:
    - name: http
      port: 3000
      targetPort: 3000
      protocol: TCP
```

---

## 5.5 ServiceMonitor Manifest

This is for the Prometheus Operator. It tells Prometheus to scrape the `/metrics` endpoint of all pods selected by the service.

**File:** `k8s/monitoring/servicemonitor.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: k8s-obs-app
  namespace: app-production
  labels:
    # This label must match the Prometheus Operator's serviceMonitorSelector
    # Check your Prometheus CR: kubectl get prometheus -A -o yaml | grep serviceMonitorSelector
    release: prometheus   # Common label when installed via kube-prometheus-stack Helm chart
    app: k8s-obs-app
spec:
  # Which Services in which namespaces to monitor
  namespaceSelector:
    matchNames:
      - app-production
  # Which Services to monitor (by label)
  selector:
    matchLabels:
      app: k8s-obs-app
      monitoring: "true"
  # How to scrape those services
  endpoints:
    - port: http          # Must match the port name in the Service (spec.ports[].name)
      path: /metrics
      interval: 15s       # Scrape every 15 seconds
      scrapeTimeout: 10s
      scheme: http
      # Optional: rename Prometheus labels for clarity
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
```

---

## 5.6 PrometheusRule Manifest (updated to match new app labels)

**File:** `k8s/monitoring/prometheusrule.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: k8s-obs-app-rules
  namespace: app-production
  labels:
    release: prometheus
    app: k8s-obs-app
spec:
  groups:
    - name: k8s-obs-app.availability
      interval: 30s
      rules:
        # Alert: Pod is down
        - alert: AppPodDown
          expr: |
            up{job="k8s-obs-app", namespace="app-production"} == 0
          for: 1m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "Pod {{ $labels.pod }} is down"
            description: "{{ $labels.pod }} in {{ $labels.namespace }} has been unreachable for more than 1 minute."

        # Alert: Less than 3 replicas available
        - alert: AppReplicasMismatch
          expr: |
            kube_deployment_spec_replicas{deployment="k8s-obs-app", namespace="app-production"}
            !=
            kube_deployment_status_replicas_available{deployment="k8s-obs-app", namespace="app-production"}
          for: 5m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Deployment replica count mismatch"
            description: "Deployment {{ $labels.deployment }} has {{ $value }} available replicas, expected 3."

    - name: k8s-obs-app.performance
      rules:
        # Alert: High error rate
        - alert: AppHighErrorRate
          expr: |
            sum(rate(http_requests_total{namespace="app-production", status_code=~"5.."}[5m]))
            /
            sum(rate(http_requests_total{namespace="app-production"}[5m]))
            > 0.05
          for: 2m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "High HTTP 5xx error rate"
            description: "Error rate is {{ $value | humanizePercentage }} over the last 5 minutes."

        # Alert: High request latency
        - alert: AppHighLatency
          expr: |
            histogram_quantile(0.95,
              sum(rate(http_request_duration_seconds_bucket{namespace="app-production"}[5m]))
              by (le, route)
            ) > 1.0
          for: 2m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "High p95 request latency on {{ $labels.route }}"
            description: "p95 latency is {{ $value }}s on route {{ $labels.route }}."
```

---

## 5.7 Apply All Manifests

Apply in dependency order:

```bash
# 1. Create namespace
kubectl apply -f k8s/namespace.yaml

# 2. Create image pull secret (see Section 5.2 for the kubectl create command)
kubectl create secret docker-registry nexus-pull-secret \
  --docker-server=192.168.1.50:8082 \
  --docker-username=jenkins-publisher \
  --docker-password='JenkinsNexus$ecret456!' \
  --docker-email=jenkins@internal.company.com \
  --namespace=app-production \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Apply application manifests
kubectl apply -f k8s/app/deployment.yaml
kubectl apply -f k8s/app/service.yaml

# 4. Apply monitoring manifests
kubectl apply -f k8s/monitoring/servicemonitor.yaml
kubectl apply -f k8s/monitoring/prometheusrule.yaml

# 5. Verify everything
kubectl get all -n app-production
kubectl get servicemonitor -n app-production
kubectl get prometheusrule -n app-production
```

---

# SECTION 6 — VERIFICATION & DAY 2 TESTING

## 6.1 The Complete End-to-End Test Chain

This is the sequence you will follow to verify the entire system. Each step has a confirmation criterion — do not proceed to the next until the current step is verified.

---

### Step 1: Make a Code Change in Git

```bash
# Clone the repo (if not already)
git clone https://github.com/yourorg/k8s-observability-cicd.git
cd k8s-observability-cicd

# Make a visible, traceable code change — add a new endpoint
cat >> app/src/server.js << 'EOF'

// New endpoint added in build verification test
app.get('/api/version-check', (req, res) => {
  res.status(200).json({
    deployed_by: 'jenkins-pipeline',
    change: 'added-version-check-endpoint',
    build: process.env.BUILD_NUMBER || 'local',
  });
});
EOF

# Commit and push
git add app/src/server.js
git commit -m "feat: add /api/version-check endpoint — triggers pipeline build"
git push origin main
```

**Confirmation:** `git log --oneline -1` shows your commit. GitHub/GitLab shows the commit in the `main` branch.

---

### Step 2: Watch Jenkins Trigger and Execute

Jenkins polls every 2 minutes. Trigger it manually for immediate testing:

1. Open Jenkins at `http://<jenkins-host>:8080`
2. Navigate to `k8s-obs-app-pipeline`
3. Click **"Build Now"**
4. Click the build number in **"Build History"** → **"Console Output"**
5. Watch each stage execute in real time

**Watch for these key log lines:**

```
# Stage 2 — Docker Build
[Pipeline] sh
+ docker build --file docker/Dockerfile --tag 192.168.1.50:8082/k8s-obs-app:5-a3f2b1c ...
Successfully built abc123def456
Successfully tagged 192.168.1.50:8082/k8s-obs-app:5-a3f2b1c

# Stage 2 — Smoke Test
SMOKE TEST PASSED: /healthz returned 200
SMOKE TEST PASSED: /metrics returned 200

# Stage 3 — Trivy
2024-01-15T10:23:45.123Z INFO No CRITICAL vulnerabilities found.
No CRITICAL vulnerabilities found. Proceeding.

# Stage 4 — Push
==> Logging in to Nexus Docker registry
Login Succeeded
==> Pushing versioned tag: 192.168.1.50:8082/k8s-obs-app:5-a3f2b1c
The push refers to repository [192.168.1.50:8082/k8s-obs-app]
5-a3f2b1c: digest: sha256:... size: 1234
==> Pushing latest tag...

# Stage 5 — Deploy
==> Waiting for rolling update to complete (timeout: 5 minutes)
Waiting for deployment "k8s-obs-app" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "k8s-obs-app" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "k8s-obs-app" rollout to finish: 1 old replicas are pending termination...
deployment "k8s-obs-app" successfully rolled out
```

**Confirmation:** Build shows blue (✅) in Jenkins. All stages green.

---

### Step 3: Validate the Image in Nexus

Open `http://192.168.1.50:8081` → **Browse → docker-private**

Or via API:

```bash
# List all tags for our image in Nexus using the Docker Registry HTTP API v2
curl -s \
  -u jenkins-publisher:'JenkinsNexus$ecret456!' \
  http://192.168.1.50:8082/v2/k8s-obs-app/tags/list | jq .
# Expected output:
# {
#   "name": "k8s-obs-app",
#   "tags": ["latest", "5-a3f2b1c", "4-...", "3-...", ...]
# }

# Inspect the manifest for the specific build tag
DIGEST=$(curl -s \
  -u jenkins-publisher:'JenkinsNexus$ecret456!' \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  -I http://192.168.1.50:8082/v2/k8s-obs-app/manifests/5-a3f2b1c \
  | grep -i "docker-content-digest" | awk '{print $2}' | tr -d '\r')
echo "Digest: ${DIGEST}"
# Expected: sha256:abc123...
```

**Confirmation:** Your new build tag (e.g., `5-a3f2b1c`) appears in the Nexus tag list.

---

### Step 4: Verify the Rolling Update in Kubernetes

```bash
# Check rollout history — you should see a new revision
kubectl rollout history deployment/k8s-obs-app -n app-production
# REVISION  CHANGE-CAUSE
# 1         <none>
# 2         <none>
# 3         <none>  ← this is your latest

# Verify the running image tag on the deployment
kubectl get deployment k8s-obs-app -n app-production \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expected: 192.168.1.50:8082/k8s-obs-app:5-a3f2b1c

# Verify all 3 pods are running and the exact image they're using
kubectl get pods -n app-production -o wide
# All pods should be in Running state, AGE should be < rolling update time

# Get the exact image on each pod (proves each was replaced)
kubectl get pods -n app-production \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# Expected (all three should show the new tag):
# k8s-obs-app-7b9d4f8c5-abc12   192.168.1.50:8082/k8s-obs-app:5-a3f2b1c
# k8s-obs-app-7b9d4f8c5-def34   192.168.1.50:8082/k8s-obs-app:5-a3f2b1c
# k8s-obs-app-7b9d4f8c5-ghi56   192.168.1.50:8082/k8s-obs-app:5-a3f2b1c

# Test your new endpoint through kubectl port-forward
kubectl port-forward service/k8s-obs-app 13001:3000 -n app-production &
PORT_FORWARD_PID=$!
sleep 2

curl -s http://localhost:13001/api/version-check | jq .
# Expected:
# {
#   "deployed_by": "jenkins-pipeline",
#   "change": "added-version-check-endpoint",
#   "build": "5"
# }

# Check the build annotation was set by Jenkins
kubectl get deployment k8s-obs-app -n app-production \
  -o jsonpath='{.metadata.annotations}' | jq .
# Expected to include:
# "deployment.kubernetes.io/build-number": "5"
# "deployment.kubernetes.io/git-commit": "a3f2b1c"
# "deployment.kubernetes.io/image-tag": "5-a3f2b1c"

kill $PORT_FORWARD_PID
```

**Confirmation:** All pods report the new image tag. The `/api/version-check` endpoint returns expected JSON.

---

### Step 5: Execute Load Generator and Verify Prometheus Scraping

**File:** `load-testing/load-generator.sh`

```bash
#!/usr/bin/env bash
# Load generator: sends sustained traffic to trigger Prometheus metrics and alerts

set -euo pipefail

TARGET_HOST="${1:-localhost}"
TARGET_PORT="${2:-13001}"
REQUESTS_PER_SECOND="${3:-20}"
DURATION_SECONDS="${4:-120}"

BASE_URL="http://${TARGET_HOST}:${TARGET_PORT}"
TOTAL_REQUESTS=$((REQUESTS_PER_SECOND * DURATION_SECONDS))
SLEEP_INTERVAL=$(echo "scale=4; 1/${REQUESTS_PER_SECOND}" | bc)

echo "==> Load Generator Starting"
echo "    Target:   ${BASE_URL}"
echo "    RPS:      ${REQUESTS_PER_SECOND}"
echo "    Duration: ${DURATION_SECONDS}s"
echo "    Total:    ${TOTAL_REQUESTS} requests"

ENDPOINTS=(
  "/api/work"
  "/"
  "/healthz"
  "/api/version-check"
)

for i in $(seq 1 $TOTAL_REQUESTS); do
  ENDPOINT="${ENDPOINTS[$((RANDOM % ${#ENDPOINTS[@]}))]}"
  curl -s -o /dev/null "${BASE_URL}${ENDPOINT}" &
  sleep $SLEEP_INTERVAL
  # Print progress every 100 requests
  if [ $((i % 100)) -eq 0 ]; then
    echo "    Sent ${i}/${TOTAL_REQUESTS} requests"
  fi
done

wait
echo "==> Load Generator Complete. ${TOTAL_REQUESTS} requests sent."
```

Execute against the cluster:

```bash
# Port-forward the service
kubectl port-forward service/k8s-obs-app 13001:3000 -n app-production &
PF_PID=$!
sleep 2

# Run load generator: 20 RPS for 120 seconds
bash load-testing/load-generator.sh localhost 13001 20 120

kill $PF_PID
```

---

### Step 6: Verify Prometheus is Scraping New Pods

```bash
# Port-forward Prometheus (adjust namespace/service name to match your setup)
kubectl port-forward service/prometheus-operated 19090:9090 \
  -n monitoring &
PROM_PID=$!
sleep 2

# Query: all targets for our app — should show 3 pods, all state=up
curl -s "http://localhost:19090/api/v1/query?query=up{job='k8s-obs-app'}" | jq '.data.result'
# Expected: 3 results, each with value [timestamp, "1"]
# "1" means UP. "0" would mean scrape failing.

# Query: total HTTP requests accumulated across all pods
curl -s "http://localhost:19090/api/v1/query?query=sum(http_requests_total{namespace='app-production'})" | jq '.data.result[0].value[1]'
# Expected: a number > 0 (the requests your load generator sent)

# Query: p95 request duration
curl -s "http://localhost:19090/api/v1/query?query=histogram_quantile(0.95,sum(rate(http_request_duration_seconds_bucket{namespace='app-production'}[5m]))by(le))" | jq '.data.result[0].value[1]'
# Expected: a floating point number representing 95th percentile latency in seconds

# Check active alerts
curl -s "http://localhost:19090/api/v1/alerts" | jq '.data.alerts[] | select(.state == "firing")'
# During load test with high RPS: AppHighErrorRate may fire if /api/work returns 5xx

kill $PROM_PID
```

**Open Grafana** (port-forward it the same way) and verify:
- The "Kubernetes / Pods" dashboard shows 3 pods for `k8s-obs-app`
- The "Node.js" dashboard (if you have one) shows request rate data
- The pod names in the dashboards match the pods from `kubectl get pods`

---

### Step 7: Simulate a Rollback

The true test of a CD system is: can you recover from a bad deployment?

```bash
# View rollout history
kubectl rollout history deployment/k8s-obs-app -n app-production

# Roll back to the previous revision instantly
kubectl rollout undo deployment/k8s-obs-app -n app-production

# Watch the rollback in real-time
kubectl rollout status deployment/k8s-obs-app -n app-production --timeout=120s

# Verify the image reverted to the previous tag
kubectl get pods -n app-production \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# Pods now show the previous build tag
```

---

## 6.2 Day 2 Operational Hardening

### Create a Least-Privilege Jenkins ServiceAccount for K8s

```bash
# Create the ServiceAccount and RBAC in the app-production namespace only
cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-deployer
  namespace: app-production
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-deploy-role
  namespace: app-production
rules:
  # Allow Jenkins to update deployment images and check rollout status
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "patch", "update"]
  # Allow Jenkins to read pod status (for verification)
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  # Allow Jenkins to watch rollout status
  - apiGroups: ["apps"]
    resources: ["deployments/rollout"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-deploy-rolebinding
  namespace: app-production
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-deploy-role
subjects:
  - kind: ServiceAccount
    name: jenkins-deployer
    namespace: app-production
EOF

# Generate a long-lived token for the ServiceAccount (K8s 1.24+)
kubectl create token jenkins-deployer \
  --namespace=app-production \
  --duration=8760h    # 1 year — rotate periodically

# Or create a persistent secret-based token (better for CI/CD)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: jenkins-deployer-token
  namespace: app-production
  annotations:
    kubernetes.io/service-account.name: jenkins-deployer
type: kubernetes.io/service-account-token
EOF

# Get the token
kubectl get secret jenkins-deployer-token \
  -n app-production \
  -o jsonpath='{.data.token}' | base64 -d

# Get the CA cert
kubectl get secret jenkins-deployer-token \
  -n app-production \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/k8s-ca.crt

# Get the API server URL
kubectl cluster-info | grep 'Kubernetes control plane'
```

Use this token to build a minimal kubeconfig and store it in Jenkins instead of the full `admin.conf`.

---

### Nexus Cleanup Policy (Prevent Disk Exhaustion)

In Nexus UI:

1. **Administration → System → Cleanup Policies → Create**
2. Name: `docker-cleanup-old-builds`
3. Format: `Docker`
4. Criteria: **"Published Before"** = `30 days`
5. **Save**
6. **Administration → Repository → Repositories → docker-private → Edit**
7. Under **Cleanup Policies**: select `docker-cleanup-old-builds`
8. **Save**

**Enable and schedule the cleanup task:**

1. **Administration → System → Tasks → Create task**
2. Type: `Admin - Compact blob store`
3. Schedule: Daily at 02:00

---

### Kubernetes PodDisruptionBudget

Prevents the rolling update from taking down too many pods simultaneously:

```yaml
# k8s/app/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: k8s-obs-app-pdb
  namespace: app-production
spec:
  minAvailable: 2   # Always keep at least 2 pods running
  selector:
    matchLabels:
      app: k8s-obs-app
```

```bash
kubectl apply -f k8s/app/pdb.yaml
kubectl get pdb -n app-production
# NAME               MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# k8s-obs-app-pdb   2               N/A               1                     5s
```

---

## 6.3 Troubleshooting Reference

| Problem | Diagnosis Command | Likely Cause |
|---|---|---|
| Pod stuck in `ImagePullBackOff` | `kubectl describe pod <name> -n app-production` | Bad imagePullSecret, Nexus unreachable, or wrong image tag |
| Rollout never completes | `kubectl rollout status deployment/k8s-obs-app -n app-production` | Readiness probe failing on new pods — check app logs |
| Prometheus not scraping | `kubectl get servicemonitor -n app-production` | ServiceMonitor label doesn't match Prometheus's `serviceMonitorSelector` |
| Jenkins build fails at push | Jenkins console → "Nexus Authentication" stage | daemon.json not configured, or wrong credentials ID |
| Trivy exits with code 1 | Jenkins console → "Vulnerability Scan" stage | Real CRITICAL CVE in image — update base image tag in Dockerfile |
| Pod `OOMKilled` | `kubectl describe pod <name>` | Memory limit too low — increase `resources.limits.memory` |

```bash
# Most useful diagnostic command chain when pods fail:
POD=$(kubectl get pods -n app-production -l app=k8s-obs-app -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod $POD -n app-production
kubectl logs $POD -n app-production --previous  # logs from the crashed container
kubectl logs $POD -n app-production             # current container logs
```

---

## 6.4 Final Architecture Validation Checklist

Run through this checklist after the first successful end-to-end pipeline:

```
[ ] Git push triggers Jenkins build within 2 minutes (or manually via Build Now)
[ ] Docker image builds successfully with multi-stage Dockerfile
[ ] Smoke test: /healthz and /metrics return 200 in the built container
[ ] Trivy scan completes and produces a JSON report artifact in Jenkins
[ ] Image appears in Nexus with two tags: latest and BUILD_NUMBER-COMMIT_SHORT
[ ] kubectl rollout status reports "successfully rolled out"
[ ] All 3 pods show the new image tag via kubectl get pods -o wide
[ ] /api/version-check returns the expected JSON (proves code change deployed)
[ ] Prometheus shows 3 UP targets for app-production job
[ ] http_requests_total metric accumulates during load test
[ ] Grafana dashboards show pod metrics (no gaps in data during rolling update)
[ ] Rollback via kubectl rollout undo works and Prometheus continues scraping
[ ] Jenkins cleans up local Docker images after each build (no disk bloat)
```

---

*This guide covers the full lifecycle from code commit to running, monitored, Prometheus-scraped pods — with every step explicitly defined and no placeholders.*

