#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "run as root (sudo)" >&2
  exit 1
fi

if [[ -z "${ROOT_PASS:-}" ]]; then
  while true; do
    read -r -s -p "New root password: " p1; echo
    read -r -s -p "Repeat root password: " p2; echo
    [[ -n "$p1" && "$p1" == "$p2" ]] && break
  done
  ROOT_PASS="$p1"
fi

if ! dpkg -s openssh-server >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y openssh-server
fi

echo "root:${ROOT_PASS}" | chpasswd
passwd -u root >/dev/null 2>&1 || true

CONF_DIR="/etc/ssh/sshd_config.d"
mkdir -p "$CONF_DIR"

ts="$(date +%F_%H%M%S)"
for f in /etc/ssh/sshd_config "$CONF_DIR"/*; do
  [[ -e "$f" ]] || continue
  cp -a "$f" "${f}.bak.${ts}" || true
done

shopt -s nullglob
for f in "$CONF_DIR"/*.conf; do
  [[ "$(basename "$f")" == "99-root-password-login.conf" ]] && continue
  mv -f "$f" "${f}.disabled"
done
shopt -u nullglob

sed -i \
  -e 's/^[[:space:]]*#\?[[:space:]]*Include[[:space:]].*sshd_config\.d\/\*\.conf.*$/Include \/etc\/ssh\/sshd_config.d\/\*\.conf/' \
  -e '/^[[:space:]]*Include[[:space:]].*sshd_config\.d\/\*\.conf/!b;:a' \
  /etc/ssh/sshd_config || true

if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf[[:space:]]*$' /etc/ssh/sshd_config; then
  echo "Include /etc/ssh/sshd_config.d/*.conf" >> /etc/ssh/sshd_config
fi

cat > "$CONF_DIR/99-root-password-login.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF
chmod 0644 "$CONF_DIR/99-root-password-login.conf"

sshd -t
systemctl restart ssh || systemctl restart sshd

sshd -T | egrep -i 'permitrootlogin|passwordauthentication|kbdinteractiveauthentication|usepam' || true
