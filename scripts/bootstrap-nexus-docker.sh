#!/usr/bin/env bash
# Modified for Local Lab execution

set -euo pipefail

NEXUS_VERSION="3.68.0"
NEXUS_DATA_DIR="/nexus-data"
NEXUS_HTTP_PORT="8081"
NEXUS_DOCKER_PORT="8082"

echo "==> Creating Nexus data directory"
sudo mkdir -p "${NEXUS_DATA_DIR}"
sudo chown -R 200:200 "${NEXUS_DATA_DIR}"
sudo chmod 750 "${NEXUS_DATA_DIR}"

echo "==> Pulling official Sonatype Nexus image"
docker pull sonatype/nexus3:${NEXUS_VERSION}

echo "==> Stopping any existing Nexus container"
docker stop nexus 2>/dev/null || true
docker rm   nexus 2>/dev/null || true

echo "==> Starting Nexus container"
# RAM constraint reduced to 1536m to avoid OOM-Kill on lab instances
docker run -d \
  --name nexus \
  --restart unless-stopped \
  --publish ${NEXUS_HTTP_PORT}:8081 \
  --publish ${NEXUS_DOCKER_PORT}:8082 \
  --volume ${NEXUS_DATA_DIR}:/nexus-data \
  --env INSTALL4J_ADD_VM_PARAMS="-Xms1536m -Xmx1536m -XX:MaxDirectMemorySize=1536m -Djava.util.prefs.userRoot=/nexus-data/javaprefs" \
  sonatype/nexus3:${NEXUS_VERSION}

echo "==> Nexus starting. Waiting for it to become ready (this takes 2-3 minutes)..."
until curl -s -o /dev/null -w "%{http_code}" http://localhost:${NEXUS_HTTP_PORT}/service/rest/v1/status | grep -q "200"; do
  echo "    Still waiting..."
  sleep 15
done

echo "==> Nexus is UP"
echo "==> Fetching initial admin password..."
docker exec nexus cat /nexus-data/admin.password

echo ""
echo "==> Login to Nexus UI via your EC2 Public IP on port ${NEXUS_HTTP_PORT}"
echo "==> Example: http://<EC2_PUBLIC_IP>:8081"
