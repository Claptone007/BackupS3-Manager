# BackupS3 Manager Server 25.0 (первый прототип)

Центральный веб-сервис для Debian 13 LXC. Совместим с маршрутами регистрации и heartbeat существующего Windows Agent.

## Рекомендуемый LXC

- Debian 13, unprivileged container;
- 2 vCPU, 2 ГБ RAM, 8–16 ГБ диска;
- статический IP или DNS-имя;
- TCP 8080 только из административной сети и сетей агентов.

## Установка

```bash
tar -xzf BackupS3Manager-Server-v25.0-linux-x64.tar.gz
cd BackupS3Manager-Server-v25.0-linux-x64
chmod +x install.sh
sudo ./install.sh
```

После установки откройте `http://IP-КОНТЕЙНЕРА:8080`. Установщик показывает случайный пароль администратора один раз. Код регистрации агента отображается после входа.

## Проверка

```bash
systemctl status backups3-manager
curl http://127.0.0.1:8080/api/health
journalctl -u backups3-manager -f
```

Перед эксплуатацией через интернет необходимо поставить reverse proxy (Caddy/Nginx) с HTTPS. Прямой HTTP-порт предназначен только для доверенной локальной сети и первичного теста.
