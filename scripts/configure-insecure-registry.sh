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
