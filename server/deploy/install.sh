#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запустите установку от root: sudo ./install.sh" >&2
  exit 1
fi
if [[ ! -f ./BackupS3Manager.Server ]]; then
  echo "Рядом с install.sh отсутствует BackupS3Manager.Server" >&2
  exit 1
fi

apt-get update
apt-get install -y ca-certificates libc6 libgcc-s1 libgssapi-krb5-2 libicu76 libssl3t64 libstdc++6 tzdata zlib1g
id backups3 >/dev/null 2>&1 || useradd --system --home /var/lib/backups3-manager --shell /usr/sbin/nologin backups3
install -d -o backups3 -g backups3 -m 0750 /var/lib/backups3-manager
install -d -o root -g root -m 0755 /opt/backups3-manager /etc/backups3-manager
cp -a ./BackupS3Manager.Server ./wwwroot /opt/backups3-manager/
chmod 0755 /opt/backups3-manager/BackupS3Manager.Server
install -m 0644 ./backups3-manager.service /etc/systemd/system/backups3-manager.service

if [[ ! -f /etc/backups3-manager/server.env ]]; then
  admin_password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  printf 'BS3_DATA_DIR=/var/lib/backups3-manager\nBS3_ADMIN_PASSWORD=%s\n' "$admin_password" >/etc/backups3-manager/server.env
  chmod 0600 /etc/backups3-manager/server.env
  echo "Пароль администратора: $admin_password"
  echo "Сохраните пароль сейчас. Позже он доступен только root в /etc/backups3-manager/server.env"
fi

systemctl daemon-reload
systemctl enable --now backups3-manager
echo "BackupS3 Manager Server установлен: http://$(hostname -I | awk '{print $1}'):8080"
