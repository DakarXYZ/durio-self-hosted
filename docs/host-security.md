# Безопасность хоста и файрвол

Выполняется на сервере при деплое (runbook `docs/plan/60-deploy.md` §3–4 в воркспейсе разработки). Здесь —
что и почему. IP сервера в этом репозитории не пишем: ниже везде `$SERVER_IP` из `.env`.

## Главное: ufw не фильтрует порты Docker

Docker пробрасывает опубликованные порты через DNAT в цепочке `DOCKER`, раньше `INPUT`, где работает ufw.
Любой `ports:` в compose открыт в интернет независимо от ufw. Поэтому два уровня:

1. **Контейнеры** — наружу публикуют порты только `caddy` и `livekit`. Это гарантирует `compose.yml` и
   проверка `scripts/check-ports.sh` (CI и `preflight.sh`):

   | Сервис | Порты |
   | --- | --- |
   | caddy | 80/tcp (ACME HTTP-01 + редирект), 443/tcp, 443/udp (HTTP/3) |
   | livekit | 7881/tcp (ICE/TCP), 7882/udp (один мультиплексный UDP-порт) |

   Mongo, Valkey, RabbitMQ, MinIO, api, events и прочие — только во внутренней сети `durio_default`.
   Для отладки — только `127.0.0.1:` в `compose.override.yml`. Фильтрация по IP — в цепочке `DOCKER-USER`
   (или `ufw-docker`).
2. **Хост (ufw)** — для портов самого хоста:

   ```bash
   sudo ufw default deny incoming
   sudo ufw default allow outgoing
   sudo ufw allow 22/tcp            # лучше: from <доверенный адрес> to any port 22
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   sudo ufw allow 443/udp
   sudo ufw allow 7881/tcp
   sudo ufw allow 7882/udp
   sudo ufw status                  # убедиться, что правило для SSH есть
   sudo ufw enable
   ```

   Если в панели хостера включён свой файрвол — те же правила там. Сервер за домашним NAT — пробросить на
   роутере 80, 443/tcp+udp, 7881/tcp, 7882/udp (не 22).

## Docker

`/etc/docker/daemon.json` (шаблон — `docs/daemon.json`):

```json
{"log-driver": "local", "live-restore": true, "userland-proxy": false}
```

Docker Engine — из `download.docker.com`, compose plugin ≥ 2.24 (`docker compose version`).
Пользователь в группе `docker` фактически root (видит `secrets.env` через `docker inspect`).

## SSH и система

- Вход только по ключу: `PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers <admin>`; fail2ban
  `sshd`. Проверить вход по ключу в отдельной сессии **до** закрытия root-доступа.
- `unattended-upgrades` без автоперезагрузки + `needrestart`; UTC, `chrony`; swap 2 ГБ.

## Проверка снаружи

С другой машины после запуска стека:

```bash
nmap -sS -p- "$SERVER_IP"            # открыты только 22, 80, 443, 7881
nmap -sU -p 443,7882 "$SERVER_IP"    # 443, 7882
```

Результат — в журнал деплоя (вне публичного репозитория).
