#!/usr/bin/env bash
# One-shot bootstrap for a fresh Ubuntu 24.04 Hetzner Cloud VM.
# Run as root (Hetzner's default 'root' SSH user) immediately after provisioning.
#
#   curl -fsSL https://raw.githubusercontent.com/CoreviaSoftware/corevia-devops/main/scripts/hetzner-bootstrap.sh | bash
#
# Or copy this file over and run:  bash hetzner-bootstrap.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root." >&2
  exit 1
fi

DEPLOY_USER=${DEPLOY_USER:-deploy}

echo "==> Updating apt"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg ufw git

echo "==> Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

echo "==> Creating deploy user: ${DEPLOY_USER}"
if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "${DEPLOY_USER}"
fi
usermod -aG docker "${DEPLOY_USER}"

# Forward root's authorized_keys so you can ssh in as deploy with the same key.
mkdir -p "/home/${DEPLOY_USER}/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys "/home/${DEPLOY_USER}/.ssh/authorized_keys"
fi
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
chmod 700 "/home/${DEPLOY_USER}/.ssh"
chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys" 2>/dev/null || true

echo "==> Configuring UFW firewall"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp     comment 'SSH'
ufw allow 80/tcp     comment 'HTTP (Caddy ACME + redirect)'
ufw allow 443/tcp    comment 'HTTPS (Caddy)'
ufw allow 1883/tcp   comment 'MQTT (Mosquitto)'
ufw allow 8554/tcp   comment 'RTSP (MediaMTX cameras)'
ufw --force enable

echo "==> Creating /opt/corevia"
install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" /opt/corevia

cat <<'EOF'

==========================================================================
Bootstrap complete.

Next steps (as deploy user — ssh deploy@<server-ip>):

1. Log into GHCR so docker can pull private images:
     echo <YOUR_GHCR_PAT> | docker login ghcr.io -u CoreviaSoftware --password-stdin
   (Create a PAT in the CoreviaSoftware org with scope: read:packages)

2. Clone the corevia-devops repo:
     git clone https://github.com/CoreviaSoftware/corevia-devops.git /opt/corevia
     cd /opt/corevia

3. Create the production env file:
     cp .env.production.example .env
     # edit .env — set DOMAIN, ACME_EMAIL, and generate real secrets:
     #   openssl rand -base64 48

4. Point your DNS A records to this server BEFORE first start
   (Caddy needs them to issue Let's Encrypt certs):
     corevia.example.com       A    <server-ip>
     hls.corevia.example.com   A    <server-ip>

5. Start the stack:
     bash scripts/deploy.sh

==========================================================================
EOF
