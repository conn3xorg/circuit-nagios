#!/usr/bin/env sh
# Stops the container up.sh started, which removes it and its volumes, then
# removes everything up.sh and Conn3x created here.
set -eu
cd "$(dirname "$0")"
if [ -f container_id ]; then
  ${PODMAN:-podman} stop "$(cat container_id)" >/dev/null 2>&1 || true
fi
rm -rf id_ed25519 id_ed25519.pub known_hosts container_id .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup
echo "Removed."
