# durio-self-hosted

**English summary.** Deployment of a **dur.io** messenger server (Docker Compose on Ubuntu Server): our backend
images `ghcr.io/dakarxyz/durio-*`, Caddy with Let's Encrypt on a free DuckDNS subdomain, MinIO for files,
LiveKit for calls, the browser client at `/web/app/` (image `durio-web`), optional end-to-end encryption (beta)
for DMs and groups. Step-by-step guide (Russian):
[docs/deploy-contabo.md](docs/deploy-contabo.md). Licensed under AGPL-3.0.

Развёртывание сервера мессенджера **dur.io**: Docker Compose на Ubuntu Server, запускает **наши** образы
`ghcr.io/dakarxyz/durio-*`. Автор и владелец — DakarX ([GitHub DakarXYZ](https://github.com/DakarXYZ)).

Основано на [stoatchat/self-hosted](https://github.com/stoatchat/self-hosted). dur.io — независимый форк и не
связан с проектом Stoat; название и логотип Stoat — товарные знаки их владельцев.

> [!WARNING]
> **Бэкапов нет.** По умолчанию резервное копирование выключено (`BACKUP_ENABLED=false`, цель не задана).
> Потеря диска = потеря всех данных и `secrets.env`, а без `REVOLT__FILES__ENCRYPTION_KEY` из `secrets.env`
> нечитаемы **все** файлы. Сразу после установки сохраните зашифрованную копию `secrets.env` вне сервера и
> включите бэкапы, как только появится цель (см. [Бэкапы](#бэкапы)).

## Чем отличается от оригинала

- Свои образы бэкенда ([durio-chat](https://github.com/DakarXYZ/durio-chat)) с тегом `0.16.0-fork.N`, все
  сторонние образы закреплены по версии; веб-клиент — отдельный образ `durio-web` со своим тегом (`WEB_TAG`).
- Неинтерактивный генератор конфигурации: режимы адреса (DuckDNS, sslip.io, свой домен, IP, LAN), хранилище
  (MinIO или внешний S3), секреты только в `secrets.env`, ручные настройки в `Revolt.overrides.toml`, которые
  переживают перегенерацию.
- MongoDB — replica set из одного узла с авторизацией; healthcheck у всех сервисов; лимиты памяти; наружу
  открыты только Caddy и LiveKit.
- Сквозное шифрование (E2EE, бета) личных сообщений и групп — включается одной проверенной командой
  `scripts/e2ee-enable.sh`, обратно не выключается.
- Администраторы сервера (`--admins`) завершают сеансы пользователей из клиента (например, при потере телефона).
- Регистрация только по приглашению, и пропуском служит обычное приглашение Stoat на сервер
  (`https://<домен>/invite/<код>`): друг регистрируется с ним и сразу оказывается на этом сервере.
- Вложения до 100 МБ (`--max-file-size`), видео и демонстрация экрана до 1920×1080.
- Скрипты обновления с автоматическим откатом, бэкапы restic (заложены, выключены), переезд хранилища,
  страница-инструкция сервера (`/web/info`) со ссылками на веб-версию и приложения и памяткой по E2EE.

## Как развернуть свой сервер

Подробно, с нуля (VPS, укрепление системы, файрвол, DuckDNS, push, первый администратор, выпуск клиентов,
включение E2EE): **[docs/deploy-contabo.md](docs/deploy-contabo.md)**. Коротко:

```bash
git clone https://github.com/DakarXYZ/durio-self-hosted && cd durio-self-hosted
git config core.hooksPath .githooks               # pre-commit: запрет IPv4-адресов в коммитах
read -rp 'SERVER_IP: ' SERVER_IP && export SERVER_IP   # IP хранится только в .env, никогда в git
scripts/generate_config.sh --yes --address-mode duckdns --address <name> --no-ddns \
    --acme-email <почта> --app-tag 0.16.0-fork.N --storage minio
# сразу: age -r <ключ> secrets.env > secrets.env.age  и унести копию с сервера
scripts/generate_config.sh --overwrite --yes --fcm-json <service-account.json>   # push (только наши серверы)
scripts/preflight.sh
scripts/compose pull && scripts/compose up -d
scripts/smoke.sh --expect-version 0.16.0+fork.N
```

Требования: x86-64 с AVX, 2 vCPU / 4 ГБ RAM (лучше 8 ГБ) / 40 ГБ SSD + место под файлы, публичный IPv4,
открытые 80, 443/tcp+udp, 7881/tcp, 7882/udp. Docker с compose ≥ 2.24, bash, `openssl`, `jq`.

`--no-ddns` — для постоянного IP (контейнер DuckDNS не запускается). Для динамического IP — без флага и с
`export DUCKDNS_TOKEN=...`.

## Состав

| Сервис | Образ | Назначение |
| --- | --- | --- |
| api, events, autumn, january, crond, pushd, voice-ingress | `durio-api`, `durio-events`, `durio-file-server`, `durio-proxy`, `durio-crond`, `durio-pushd`, `durio-voice-ingress` | бэкенд |
| gifbox | `durio-gifbox` | профиль `gifbox`, по умолчанию выключен |
| database + database-init | `mongo:8.0` | replica set `rs0` из одного узла, с авторизацией |
| redis, rabbit | `valkey`, `rabbitmq` | брокеры (без бэкапа, эфемерны) |
| minio + createbuckets | `pgsty/silo`, `pgsty/mc` | профиль `minio`: файлы на сервере |
| caddy | `caddy:2.10` | TLS, прокси, discovery `/.well-known/stoat`, статические страницы (`config/site/`) |
| web | `durio-web` | веб-клиент на `/web/app/` (Caddy внутри образа, порт 8080 только во внутренней сети) |
| livekit | `livekit-server` | голос и видео |
| duckdns | `linuxserver/duckdns` | профиль `duckdns`: обновление IP |

Веб-клиент ([durio-for-web](https://github.com/DakarXYZ/durio-for-web)) — на `/web/app/`: Caddy проксирует сервис
`web` без изменения пути и задаёт CSP; кэширование и SPA-fallback — внутри образа. Тег образа `WEB_TAG` в
`.env` меняется отдельно от бэкенда (`scripts/web-upgrade.sh`). `/` перенаправляет на `/web/info` — инструкцию
(`config/site/info.html`): адрес сервера, веб-версия, APK и установщик Windows, регистрация по приглашению,
E2EE, исходники. На `/e2ee.html` (`/e2ee-en.html`) — памятка пользователю о сквозном шифровании, на
`/invite/<код>` — страница приглашения (кнопка «Открыть в браузере», адрес сервера, код, как зарегистрироваться
или войти на сервер). Ключи E2EE веб-версия хранит в браузере, а её код каждый раз приходит с сервера, поэтому
для зашифрованных чатов надёжнее приложения — так и сказано на `/web/info`.
Наружу открыты только `caddy` (80, 443/tcp+udp) и `livekit` (7881/tcp, 7882/udp) — см.
[docs/host-security.md](docs/host-security.md).

## Файлы

| Файл | В git | Кто пишет |
| --- | --- | --- |
| `compose.yml`, `Caddyfile`, `config/site/`, `config/mongo/` | да | мы |
| `.env` — адрес, режимы, профили, тег образов, `SERVER_IP` | нет | `generate_config.sh` (`--overwrite`) |
| `secrets.env` (0600) — все секреты как `REVOLT__…` | нет | `generate_config.sh`, только дописывает |
| `Revolt.toml` — производное от адреса, хранилища и настроек генератора | нет | `generate_config.sh` (`--overwrite`) |
| `Revolt.overrides.toml` — ручные политики | нет | создаётся один раз, дальше только вы |
| `livekit.yml`, `stoat.json`, `config/caddy/*.caddy` | нет | `generate_config.sh` |
| `images.lock.env` — дайджесты образов (необязательно) | нет | `upgrade.sh --pin-digests` |
| `data/.e2ee-enabled` — отметка «E2EE включено» (дата, тег) | нет | `e2ee-enable.sh` |

Все команды compose — через `scripts/compose` (= `docker compose --env-file .env --env-file secrets.env`):
сторонние контейнеры получают пароли подстановкой из `secrets.env`.

## Настройки

### Генератор (`scripts/generate_config.sh`)

Значение берётся из флага, иначе из прежнего `.env`, иначе по умолчанию. Повторный запуск — только с
`--overwrite` (бэкап `*.<дата>.bak`); `secrets.env` и `Revolt.overrides.toml` он не переписывает никогда.
После любой перегенерации — рестарт бэкенда (ниже). Полный список — `--help`.

| Опция | По умолчанию | Что делает |
| --- | --- | --- |
| `--address-mode`, `--address` | `duckdns` | адрес сервера, см. [Режимы адреса](#режимы-адреса---address-mode) |
| `--no-ddns` | — | DuckDNS без контейнера обновления IP |
| `--acme-email` | — | почта аккаунта Let's Encrypt |
| `--storage`, `--minio-data-path`, `--s3-*` | `minio`, `./data/minio` | хранилище файлов, см. [ниже](#хранилище-файлов---storage) |
| `--max-file-size MB` | `100` | лимит вложений (`MAX_FILE_SIZE_MB` в `.env`) |
| `--admins ID[,ID...]` | пусто | администраторы сервера (`ADMIN_USER_IDS`); `''` снимает всех |
| `--video` / `--no-video` | включено | камера и демонстрация экрана до 1920×1080 |
| `--fcm-json FILE` | — | ключ сервисного аккаунта Firebase для push |
| `--name NAME` | `dur.io` | имя сервера в `/.well-known/stoat` |
| `--app-tag TAG` | тег релиза репозитория | тег образов бэкенда |
| `--web-tag TAG` | `DEFAULT_WEB_TAG` (`scripts/lib.sh`) | тег образа веб-клиента `durio-web` (`WEB_TAG`) |
| `--behind-proxy` | выкл. | Caddy слушает `:80` за другим TLS-прокси |
| `--confirm-address-change` | — | разрешает `--overwrite` сменить адрес (пользователи заново добавят аккаунты) |

- **Размер файлов:** `--max-file-size` пишет в `Revolt.toml`
  `[features.limits.new_user.file_upload_size_limit] attachments` и
  `[features.limits.default.file_upload_size_limit] attachments` (= МБ × 1 000 000) и
  `[features.limits.global] body_limit_size` (+5 МБ на multipart). Caddy и MinIO тело не ограничивают; autumn
  держит файл в памяти при шифровании — лимит памяти контейнера 1536M рассчитан на 100 МБ.
- **Администраторы:** в `Revolt.toml` — `[api.admins] users`; админы также все пользователи с `privileged: true`
  в базе. Админ в клиенте находит пользователя (id или `имя#1234`) и завершает его сеансы — один или все
  (потерян телефон, другого устройства нет); вместе с сеансом удаляется его устройство E2EE, сокеты
  закрываются. Действия пишутся в лог `api` (`Admin <id> ended ...`, `Admin <id> created invite ...`).
  Id пользователя: `scripts/compose exec database mongosh -u root -p --authenticationDatabase admin revolt
  --quiet --eval 'db.users.findOne({username: "<имя>", discriminator: "<1234>"})._id'`.
- **2FA для админов:** действия администратора требуют включённого в аккаунте TOTP (приложение-аутентификатор):
  админ подтверждает себя кодом, и сеанс получает права на `[api.admins] elevation_minutes` (60 минут); выход
  из сеанса права снимает.
- **Приглашения:** стандартные приглашения Stoat на сервер (настройки сервера → «Приглашения», или «Пригласить»
  у канала). При `invite_only = true` их код принимается и при регистрации (если приглашение не истекло и у него
  остались использования; использование засчитывается при входе на сервер, не при регистрации). Ссылка
  `https://<домен>/invite/<код>`, открытая в браузере, показывает страницу Caddy (`config/site/invite.html`) с
  кнопкой «Открыть в браузере» (веб-клиент, `/web/app/invite/<код>`), адресом сервера, кодом и ссылками на
  приложения.
- **Демонстрация экрана:** с `--video` лимит видео — 1920×1080 при соотношении сторон 0.3–10; частоту кадров и
  битрейт сервер не ограничивает, 1080p 60 fps задаёт клиент. Дорожка больше 1920×1080 по площади отключается
  voice-ingress.
- **hCaptcha выключена и включать её нельзя:** CSP Windows-клиента блокирует hCaptcha, регистрация и вход там
  сломаются. Генератор пишет пустые `[api.security.captcha]` и отказывается работать, если ключ найден в
  `secrets.env` (`REVOLT__API__SECURITY__CAPTCHA__HCAPTCHA_KEY`) или в `Revolt.overrides.toml`.

### Ручные настройки (`Revolt.overrides.toml`)

- Создаётся один раз: `invite_only = true`, `trust_cloudflare = true` (Caddy передаёт реальный IP клиента в
  `CF-Connecting-IP`), `[features.e2ee] enabled = false` (включать — только `scripts/e2ee-enable.sh`).
- SMTP: `[api.smtp]` в overrides, пароль — `REVOLT__API__SMTP__PASSWORD` в `secrets.env`. Без SMTP почта при
  регистрации не подтверждается (аккаунт активен сразу).
- Конфиг читается при старте: после правок — рестарт **всех** бэкенд-сервисов:
  `scripts/compose up -d --force-recreate api events autumn january crond pushd voice-ingress`.
- `production = false` всегда (при `true` бэкенд шлёт письма с брендом Stoat и включает Discover).
- Инвайт вручную (только для первого аккаунта, пока нет админа, или как запасной путь админа):
  `scripts/compose exec database mongosh -u root -p --authenticationDatabase admin revolt --eval
  'db.account_invites.insertOne({_id: "<код>"})'`, код — `openssl rand -hex 8`. Такой код бессрочный и
  одноразовый; человек вставляет его в поле приглашения при регистрации. Дальше — обычные приглашения на сервер
  (см. «Приглашения» выше), порядок первого запуска —
  [deploy-contabo.md §10](docs/deploy-contabo.md#10-первый-аккаунт-администратор-приглашения).

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

### Хранилище файлов (`--storage`)

| | MinIO (по умолчанию) | MinIO на отдельном диске / NAS | Внешний S3 |
| --- | --- | --- | --- |
| Настройка | ничего | `--minio-data-path /mnt/files/minio` | `--storage s3 --s3-endpoint … --s3-region … --s3-bucket …` + `S3_ACCESS_KEY_ID`/`S3_SECRET_ACCESS_KEY` в env |
| Бэкап | `mc mirror` | `mc mirror` | версионирование бакета у провайдера |

Файлы шифрует autumn до записи — провайдер видит шифротекст. Переезд между хранилищами:
`scripts/migrate-storage.sh --to s3|minio …` (зеркалирование, остановка autumn, дельта, сверка, переключение;
старое хранилище не удаляется).

## Сквозное шифрование (E2EE)

> [!IMPORTANT]
> **Notice (0.16.0-fork.N с E2EE):** после обновления до версии с E2EE шифрование остаётся выключенным. Включать —
> `scripts/e2ee-enable.sh`, когда клиенты с E2EE уже выпущены. **Обратно не выключается.** E2EE — бета:
> внешнего аудита не было.

```bash
scripts/e2ee-enable.sh --check                 # состояние: overrides, GET /api/, отметка data/.e2ee-enabled
scripts/e2ee-enable.sh                         # включить (спросит подтверждение; --yes — без вопроса)
scripts/e2ee-enable.sh --default-for-new-dms   # через 1–2 месяца: новые ЛС шифруются сразу
```

Скрипт идемпотентен: проверяет, что `GET /api/` отдаёт `features.e2ee` и нашу версию, что все бэкенд-контейнеры
запущены из образа тега `APP_TAG`, пишет `enabled = true` в секцию `[features.e2ee]` файла
`Revolt.overrides.toml` (остальное не трогает; ключи в другом виде или `REVOLT__FEATURES__E2EE__*` в env —
отказ), перезапускает **все** бэкенд-сервисы, проверяет `GET /api/` → `features.e2ee.enabled = true` и ставит
отметку `data/.e2ee-enabled`. С отметкой `scripts/smoke.sh` (и значит `upgrade.sh`) падает, если E2EE снова
выключено. `--no-restart` только правит файл (без проверок и рестарта).

### Порядок включения

1. Все сервисы обновлены до версии с E2EE (`scripts/upgrade.sh`), `scripts/smoke.sh` зелёный.
2. Клиенты с E2EE **выпущены** (APK в релизах), активные пользователи обновились — старые клиенты вместо
   зашифрованных сообщений показывают «🔒 Зашифрованное сообщение. Обновите приложение.»
   (`legacy_placeholder`).
3. `scripts/e2ee-enable.sh` → в приложении «Устройства и шифрование» показывает, что шифрование включено.
4. Через 1–2 месяца — `scripts/e2ee-enable.sh --default-for-new-dms`: новые ЛС шифруются сразу. Этот флаг
   можно вернуть в `false` (правка overrides + рестарт всех бэкенд-сервисов): он влияет только на новые ЛС.
   Группы шифруют сами участники.

Пользователям — памятка `/e2ee.html` на странице сервера.

### Выключать нельзя

`enabled = false` после включения ломает зашифрованные чаты: `/e2ee/*` отвечают 404, зашифрованные сообщения не
принимаются, устройства не получают ключи, бэкап ключей недоступен — чаты становятся «только для чтения», а
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
git fetch --tags && git checkout <новый тег репозитория>
scripts/upgrade.sh 0.16.0-fork.N [--pin-digests]
```

preflight → **всегда** локальный `mongodump --oplog` в `backups/pre-upgrade/` (хранятся 3 последних) →
полный бэкап, если включён → `pull` → новые `migrations/*.sh` → `api` (миграции БД) → остальные → `smoke.sh`.
При сбое без миграций БД — автоматический откат тега; если миграции прошли — сервисы останавливаются и
печатается команда восстановления (`scripts/restore.sh --from-archive …`). Журнал — `logs/`. Пока бэкапы
выключены — перед обновлением снапшот VPS у хостера.

Веб-клиент обновляется вместе с бэкендом (`scripts/upgrade.sh <тег> --web-tag <тег веба>`) или отдельно, без
дампа и без остановки бэкенда:

```bash
scripts/web-upgrade.sh 0.1.N            # WEB_TAG → pull → up web → healthy → smoke.sh; при сбое — прежний WEB_TAG
```

В `.env` старых установок `WEB_TAG` нет: `upgrade.sh` и `web-upgrade.sh` дописывают `DEFAULT_WEB_TAG`
(`preflight.sh` до этого останавливается с подсказкой). С `images.lock.env` закрепляется и дайджест `WEB_DIGEST`.

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

## Локальный стенд (режим `lan`)

Образы бэкенда собираются локально из [durio-chat](https://github.com/DakarXYZ/durio-chat)
(`scripts/durio/build-images.sh` → `durio-api:local` и т. д.), веб-клиент — из
[durio-for-web](https://github.com/DakarXYZ/durio-for-web) как `durio-web:local` (`--local-images` ставит и
`WEB_TAG=local`).

```bash
scripts/generate_config.sh --address-mode lan --dev --local-images --address durio.lan \
    [--server-ip <LAN-IP>]                   # IP нужен LiveKit, чтобы голос шёл с других устройств
scripts/compose up -d
scripts/compose ps
scripts/smoke.sh --local
```

`durio.lan` → IP машины в `hosts` клиента. TLS — самоподписанный корень Caddy
`data/caddy-data/caddy/pki/authorities/local/root.crt`: установить на тестовые устройства (Android доверяет
пользовательским CA только в debug-сборке).

## Клиенты

Серверного адреса по умолчанию в клиентах нет: пользователь вводит адрес сервера (например,
`<name>.duckdns.org`), клиент находит API через `/.well-known/stoat`.

- **Браузер** — `https://<домен>/web/app/`, отдаёт сам сервер (сервис `web`, образ из
  [durio-for-web](https://github.com/DakarXYZ/durio-for-web)); инструкция для пользователей — `/web/info`.

- **Android** — [durio-for-android](https://github.com/DakarXYZ/durio-for-android): APK в GitHub Releases,
  инструкция для пользователей — в README репозитория.
- **Windows** — [durio-for-desktop](https://github.com/DakarXYZ/durio-for-desktop): установщик в GitHub Releases,
  инструкция — в README репозитория.

Push-уведомления на Android работают только на серверах с ключом нашего Firebase-проекта; на других серверах
приложения работают без фоновых уведомлений.

## Импорт из Discord

Перенос истории каналов Discord (экспорт DiscordChatExporter, JSON) в каналы сервера dur.io — авторы,
даты, ответы, файлы: [tools/discord-import/README.md](tools/discord-import/README.md).

## Разработка репозитория

- CI (`.github/workflows/ci.yml`): shellcheck, `scripts/check-no-ip.sh`, и для каждой пары режим × хранилище —
  `scripts/ci/test-config.sh` (генерация, `docker compose config -q`, `check-ports.sh`, `caddy validate`,
  проверки `--overwrite`).
- IP сервера никогда не коммитим: только `.env`. Хук: `git config core.hooksPath .githooks`. Разрешены
  `*.example`, частные и документационные диапазоны, строки с пометкой `ip-check: allow`.
- `migrations/<YYYYMMDD>-<что>.sh` — идемпотентные ручные шаги, выполняет `upgrade.sh`
  (учёт в `data/.applied-migrations`). `migrations/upstream/` — история upstream, не выполняется.
- Ошибки и предложения — [issues](https://github.com/DakarXYZ/durio-self-hosted/issues).

## Исходный код и лицензия

Исходники всех компонентов dur.io (AGPL-3.0 требует их доступности пользователям сервера):
[durio-chat](https://github.com/DakarXYZ/durio-chat) (сервер) ·
[durio-self-hosted](https://github.com/DakarXYZ/durio-self-hosted) ·
[durio-for-android](https://github.com/DakarXYZ/durio-for-android) ·
[durio-for-desktop](https://github.com/DakarXYZ/durio-for-desktop) ·
[durio-for-web](https://github.com/DakarXYZ/durio-for-web) ·
[durio-javascript-client-sdk](https://github.com/DakarXYZ/durio-javascript-client-sdk) ·
[durio-crypt](https://github.com/DakarXYZ/durio-crypt) (крипто-ядро E2EE, Apache-2.0).

Лицензия — [AGPL-3.0](LICENSE), как у оригинала. Copyright © DakarX для изменений dur.io; исходный код
оригинала — его авторов.
