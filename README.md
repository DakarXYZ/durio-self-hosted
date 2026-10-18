# durio-self-hosted

Развёртывание сервера мессенджера **dur.io** (Docker Compose, Ubuntu Server). Форк
[stoatchat/self-hosted](https://github.com/stoatchat/self-hosted), запускает **наши** образы
`ghcr.io/dakarxyz/durio-*`. dur.io основан на Stoat и не связан с ним; «Stoat» — товарный знак его владельцев.

> [!WARNING]
> **Бэкапов нет.** По умолчанию резервное копирование выключено (`BACKUP_ENABLED=false`, цель не задана).
> Потеря диска = потеря всех данных и `secrets.env`, а без `REVOLT__FILES__ENCRYPTION_KEY` из `secrets.env`
> нечитаемы **все** файлы. Сразу после установки сохраните зашифрованную копию `secrets.env` вне сервера и
> включите бэкапы, как только появится цель (см. [Бэкапы](#бэкапы)).

## Состав

| Сервис | Образ | Назначение |
| --- | --- | --- |
| api, events, autumn, january, crond, pushd, voice-ingress | `durio-api`, `durio-events`, `durio-file-server`, `durio-proxy`, `durio-crond`, `durio-pushd`, `durio-voice-ingress` | бэкенд |
| gifbox | `durio-gifbox` | профиль `gifbox`, по умолчанию выключен |
| database + database-init | `mongo:8.0` | replica set `rs0` из одного узла, с авторизацией |
| redis, rabbit | `valkey`, `rabbitmq` | брокеры (без бэкапа, эфемерны) |
| minio + createbuckets | `pgsty/silo`, `pgsty/mc` | профиль `minio`: файлы на сервере |
| caddy | `caddy:2.10` | TLS, прокси, discovery `/.well-known/stoat`, статическая страница `/` |
| livekit | `livekit-server` | голос и видео |
| duckdns | `linuxserver/duckdns` | профиль `duckdns`: обновление IP |

Браузерного клиента нет: на `/` — страница со ссылками на приложения и исходники (`config/site/`), на
`/e2ee.html` (`/e2ee-en.html`) — памятка пользователю о сквозном шифровании.
Наружу открыты только `caddy` (80, 443/tcp+udp) и `livekit` (7881/tcp, 7882/udp) — см.
[docs/host-security.md](docs/host-security.md).

## Файлы

| Файл | В git | Кто пишет |
| --- | --- | --- |
| `compose.yml`, `Caddyfile`, `config/site/`, `config/mongo/` | да | мы |
| `.env` — адрес, режимы, профили, тег образов, `SERVER_IP` | нет | `generate_config.sh` (`--overwrite`) |
| `secrets.env` (0600) — все секреты как `REVOLT__…` | нет | `generate_config.sh`, только дописывает |
| `Revolt.toml` — производное от адреса и хранилища | нет | `generate_config.sh` (`--overwrite`) |
| `Revolt.overrides.toml` — ручные политики | нет | создаётся один раз, дальше только вы |
| `livekit.yml`, `stoat.json`, `config/caddy/*.caddy` | нет | `generate_config.sh` |
| `images.lock.env` — дайджесты образов (необязательно) | нет | `upgrade.sh --pin-digests` |
| `data/.e2ee-enabled` — отметка «E2EE включено» (дата, тег) | нет | `e2ee-enable.sh` |

Все команды compose — через `scripts/compose` (= `docker compose --env-file .env --env-file secrets.env`):
сторонние контейнеры получают пароли подстановкой из `secrets.env`.

## Быстрый старт локально (режим `lan`)

Нужны Docker (compose ≥ 2.24), bash, `openssl`, `jq`. Образы бэкенда собираются локально из
[durio-chat](https://github.com/DakarXYZ/durio-chat) с именами `durio-api:local` и т. д.

```bash
git config core.hooksPath .githooks          # pre-commit: запрет IPv4-адресов в коммитах
scripts/generate_config.sh --address-mode lan --dev --local-images --address durio.lan \
    [--server-ip <LAN-IP>]                   # IP нужен LiveKit, чтобы голос шёл с других устройств
scripts/compose up -d
scripts/compose ps
scripts/smoke.sh --local
```

`durio.lan` → IP машины в `hosts` клиента. TLS — самоподписанный корень Caddy
`data/caddy-data/caddy/pki/authorities/local/root.crt`: установить на тестовые устройства (Android доверяет
пользовательским CA только в debug-сборке).

## Боевой сервер

Пошагово — runbook деплоя (`docs/plan/60-deploy.md` в воркспейсе разработки): подготовка VPS, файрвол,
затем:

```bash
git clone https://github.com/DakarXYZ/durio-self-hosted && cd durio-self-hosted
git config core.hooksPath .githooks
export SERVER_IP=...                         # только в окружении/.env, не в git
scripts/generate_config.sh --address-mode duckdns --address <name>.duckdns.org --no-ddns \
    --acme-email <почта> --app-tag 0.16.0-fork.N --storage minio --yes
# сразу: age -r <ключ> secrets.env > secrets.env.age  и унести копию с сервера
scripts/preflight.sh
scripts/compose pull && scripts/compose up -d
scripts/smoke.sh --expect-version 0.16.0+fork.N
```

`--no-ddns` — для постоянного IP (контейнер DuckDNS не запускается). Для динамического IP — без флага и с
`export DUCKDNS_TOKEN=...`.

### Режимы адреса (`--address-mode`)

| Режим | Адрес | TLS | Заметки |
| --- | --- | --- | --- |
| `duckdns` (по умолчанию) | `<name>.duckdns.org` | Let's Encrypt | профиль `duckdns`, если не `--no-ddns` |
| `sslip` | `<ip-через-дефисы>.sslip.io` из `--server-ip` | Let's Encrypt | лимит LE общий со всеми пользователями sslip.io |
| `domain` | свой домен | Let's Encrypt | |
| `ip` | голый IPv4 | LE `shortlived` | **не проверено** |
| `lan` | `durio.lan` / локальный IP | `tls internal` | только разработка, требует `--dev` |

**Смена адреса = все пользователи заново добавляют аккаунт.** Поэтому адрес выбирают один раз; смена —
`generate_config.sh --overwrite --confirm-address-change` и рестарт всех сервисов. `data/caddy-data`
(аккаунт ACME и сертификаты) при переустановке сохранять — иначе можно упереться в лимиты Let's Encrypt.
`--behind-proxy` — Caddy слушает `:80` за другим TLS-прокси.

### Хранилище файлов (`--storage`)

| | MinIO (по умолчанию) | MinIO на отдельном диске / NAS | Внешний S3 |
| --- | --- | --- | --- |
| Настройка | ничего | `--minio-data-path /mnt/files/minio` | `--storage s3 --s3-endpoint … --s3-region … --s3-bucket …` + `S3_ACCESS_KEY_ID`/`S3_SECRET_ACCESS_KEY` в env |
| Бэкап | `mc mirror` | `mc mirror` | версионирование бакета у провайдера |

Файлы шифрует autumn до записи — провайдер видит шифротекст. Переезд между хранилищами:
`scripts/migrate-storage.sh --to s3|minio …` (зеркалирование, остановка autumn, дельта, сверка, переключение;
старое хранилище не удаляется).

## Конфигурация

- Ручные настройки — `Revolt.overrides.toml` (генератор его не трогает): `invite_only = true`,
  `trust_cloudflare = true` (Caddy передаёт реальный IP клиента в `CF-Connecting-IP`), `[features.e2ee]`.
  SMTP: `[api.smtp]` в overrides, пароль — `REVOLT__API__SMTP__PASSWORD` в `secrets.env`.
- Конфиг читается при старте: после правок — рестарт **всех** бэкенд-сервисов:
  `scripts/compose up -d --force-recreate api events autumn january crond pushd voice-ingress`.
- `production = false` всегда (при `true` бэкенд шлёт письма с брендом Stoat и включает Discover).
- **E2EE:** включается только скриптом `scripts/e2ee-enable.sh` и только когда все сервисы и клиенты на версии с
  E2EE; **выключать нельзя** — см. [Сквозное шифрование (E2EE)](#сквозное-шифрование-e2ee).
- Инвайт: `scripts/compose exec database mongosh -u root -p --authenticationDatabase admin revolt --eval
  'db.account_invites.insertOne({_id: "<код>"})'`, код — `openssl rand -hex 8`.
- Push (FCM): `generate_config.sh --overwrite --fcm-json service-account.json`.

## Сквозное шифрование (E2EE)

> [!IMPORTANT]
> **Notice (0.16.0-fork.N с E2EE):** после обновления до версии с E2EE шифрование остаётся выключенным. Включать —
> `scripts/e2ee-enable.sh`, когда клиенты с E2EE уже выпущены. **Обратно не выключается.**

```bash
scripts/e2ee-enable.sh --check                 # состояние: overrides, GET /api/, отметка data/.e2ee-enabled
scripts/e2ee-enable.sh                         # включить (спросит подтверждение; --yes — без вопроса)
scripts/e2ee-enable.sh --default-for-new-dms   # через 1–2 месяца (O6): новые ЛС шифруются сразу
```

Скрипт идемпотентен: проверяет, что `GET /api/` отдаёт `features.e2ee` и нашу версию, что все бэкенд-контейнеры
запущены из образа тега `APP_TAG` (тот же тег и тот же образ после `pull`), пишет `enabled = true` в секцию
`[features.e2ee]` файла `Revolt.overrides.toml` (остальное не трогает; ключи в другом виде или
`REVOLT__FEATURES__E2EE__*` в env — отказ), перезапускает **все** бэкенд-сервисы, проверяет `GET /api/` →
`features.e2ee.enabled = true` и ставит отметку `data/.e2ee-enabled`. С отметкой `scripts/smoke.sh` (и значит
`upgrade.sh`) падает, если E2EE снова выключено. `--no-restart` только правит файл (без проверок и рестарта).

### Порядок включения

1. Все сервисы обновлены до версии с E2EE (`scripts/upgrade.sh`), `scripts/smoke.sh` зелёный.
2. Клиенты с E2EE **выпущены** (APK в релизах), активные пользователи обновились — старые клиенты вместо
   зашифрованных сообщений показывают «🔒 Зашифрованное сообщение. Обновите приложение.»
   (`legacy_placeholder`).
3. `scripts/e2ee-enable.sh` → в приложении «Устройства и шифрование» показывает, что шифрование включено.
4. Через 1–2 месяца (O6) — `scripts/e2ee-enable.sh --default-for-new-dms`: новые ЛС шифруются сразу. Этот флаг
   можно вернуть в `false` (правка overrides + рестарт всех бэкенд-сервисов): он влияет только на новые ЛС.
   Группы шифруют сами участники.

Пользователям — памятка `/e2ee.html` на странице сервера.

### Выключать нельзя

`enabled = false` после включения ломает зашифрованные чаты: `/e2ee/*` отвечают 404, зашифрованные сообщения не
принимаются, устройства не получают ключи, бэкап ключей недоступен — чаты становятся «только для чтения» (Q59), а
флаг шифрования канала необратим, так что вернуться к открытому тексту они тоже не могут. `scripts/e2ee-enable.sh
--disable` отказывается. При проблемах с E2EE — откат тега образов (`scripts/upgrade.sh <прежний тег>`, пока
миграции те же) или исправление вперёд, флаг не трогать. Перенос `Revolt.overrides.toml` при переустановке или
восстановлении — обязательно (он в бэкапе вместе с `.env`).

### Миграция 56

Ревизия БД 55 → 56 создаёт 7 коллекций `e2ee_*` с индексами; выполняет её `api` при первом старте новой версии
(`upgrade.sh` пишет ревизию до/после). Ручных шагов нет, на выключенном E2EE коллекции просто пустые. Откат тега
после миграции — только через восстановление `backups/pre-upgrade/` (см. [Обновление](#обновление)). Не задавать
`REDIS_PAYLOAD_TYPE=bincode`: E2EE-события в этом формате bonfire не декодирует. Caddy тело запроса не
ограничивает; лимит JSON у api — 4 МиБ (`max_request_bytes`), `scripts/smoke.sh` проверяет, что 3 МиБ доходят.

### Мониторинг

Размер E2EE-коллекций (документы, байты):

```bash
scripts/compose exec database mongosh -u root -p --authenticationDatabase admin revolt --quiet --eval '
  db.getCollectionNames().filter(c => c.startsWith("e2ee_")).sort().forEach(c => {
    const s = db.getCollection(c).stats(); print(c, s.count, s.size) })'
```

Самые полные ящики `to_device` (лимит `max_pending_to_device` = 10 000 на устройство, срок 30 дней — TTL-индекс):

```bash
scripts/compose exec database mongosh -u root -p --authenticationDatabase admin revolt --quiet --eval '
  db.e2ee_to_device.aggregate([{$group: {_id: "$recipient_device", n: {$sum: 1}}},
    {$sort: {n: -1}}, {$limit: 10}]).forEach(d => print(d._id, d.n))'
```

- Ожидаемо: `e2ee_devices` ≈ число сессий с E2EE; `e2ee_one_time_keys` ≤ 100 на устройство; `e2ee_backup_keys`
  растёт с числом зашифрованных чатов (сессия Megolm ≤ 4 КиБ).
- Тревожно: ящик устройства у предела (клиент «не получает ключи», в приложении — предупреждение) — обычно
  заброшенная установка: пользователю выйти на ней; быстрый рост `e2ee_to_device` при неизменном числе
  пользователей — сломанный клиент шлёт повторы (логи api, отчёт диагностики от пользователя).
- Брошенные устройства, ключи и версии бэкапа без владельца удаляет `crond` (задача `prune_e2ee`); просроченные
  сообщения ящика — TTL Mongo.

### Что сервер хранит для E2EE

Сервер — только почтальон. В базе: публичные ключи устройств (Curve25519/Ed25519) и их подписи, одноразовые и
резервные ключи, ящик `to_device` (зашифрованные сообщения между устройствами, до доставки или 30 дней),
**зашифрованный** бэкап ключей и зашифрованное секретное хранилище (ключа восстановления у сервера нет), флаг
шифрования каналов, у сообщений — шифротекст конверта вместо текста. Вложения зашифрованы клиентом до загрузки
(autumn хранит `file.bin` без превью и метаданных, а затем ещё раз шифрует своим ключом). Открытого текста,
закрытых ключей и ключа восстановления на сервере нет; бэкапы сервера (`restic`) содержат то же самое.
Метаданные открыты: кто с кем и когда, размеры, реакции, ответы, закрепления, состав групп, системные сообщения,
число и размеры файлов, устройства и время их активности. Звонки (LiveKit) не E2EE.

## Обновление

```bash
scripts/upgrade.sh 0.16.0-fork.N [--pin-digests]
```

preflight → **всегда** локальный `mongodump --oplog` в `backups/pre-upgrade/` (хранятся 3 последних) →
полный бэкап, если включён → `pull` → новые `migrations/*.sh` → `api` (миграции БД) → остальные → `smoke.sh`.
При сбое без миграций БД — автоматический откат тега; если миграции прошли — сервисы останавливаются и
печатается команда восстановления (`scripts/restore.sh --from-archive …`). Журнал — `logs/`.

## Бэкапы

Скрипты готовы, но **выключены**. Включение — одной командой (root), когда будет цель:

```bash
scripts/backup-enable.sh --target local:/srv/backup [--hc-url https://hc-ping.com/<uuid>]
# позже: --target s3:https://<endpoint>/<bucket>  или  --target rclone:<remote>:<path>
scripts/backup-enable.sh --disable
```

restic (шифрование, дедупликация, 7 дневных / 4 недельных / 6 месячных), systemd-таймер 03:30 UTC.
Состав: дамп Mongo, зеркало бакета MinIO, `secrets.env`, `.env`, конфиги, `data/caddy-data`. Пароль restic —
сохранить вне сервера. Локальная цель спасает от ошибок, но не от потери диска. Восстановление —
`scripts/restore.sh` (`--dry-run` для проверки). Пока бэкапов нет — снапшоты VPS у хостера вручную.

## Разработка репозитория

- CI (`.github/workflows/ci.yml`): shellcheck, `scripts/check-no-ip.sh`, и для каждой пары режим × хранилище —
  `scripts/ci/test-config.sh` (генерация, `docker compose config -q`, `check-ports.sh`, `caddy validate`,
  проверки `--overwrite`).
- IP сервера никогда не коммитим: только `.env`. Хук: `git config core.hooksPath .githooks`. Разрешены
  `*.example`, частные и документационные диапазоны, строки с пометкой `ip-check: allow`.
- `migrations/<YYYYMMDD>-<что>.sh` — идемпотентные ручные шаги, выполняет `upgrade.sh`
  (учёт в `data/.applied-migrations`). `migrations/upstream/` — история upstream, не выполняется.

## Исходный код (AGPL-3.0)

[durio-chat](https://github.com/DakarXYZ/durio-chat) (сервер) ·
[durio-self-hosted](https://github.com/DakarXYZ/durio-self-hosted) ·
[durio-for-android](https://github.com/DakarXYZ/durio-for-android) ·
[durio-for-desktop](https://github.com/DakarXYZ/durio-for-desktop) ·
[durio-for-web](https://github.com/DakarXYZ/durio-for-web) ·
[durio-javascript-client-sdk](https://github.com/DakarXYZ/durio-javascript-client-sdk)

Лицензия — [AGPL-3.0](LICENSE), как у upstream.
