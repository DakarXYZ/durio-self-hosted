# Развёртывание сервера dur.io на Contabo VPS

Пошаговая инструкция «с нуля» для боевого сервера dur.io: VPS Contabo, Ubuntu 24.04 LTS, адрес — бесплатный
поддомен DuckDNS, TLS — Let's Encrypt через Caddy, файлы — MinIO на этом же сервере. Краткая справка по
настройкам — в [README](../README.md); безопасность хоста подробнее — в [host-security.md](host-security.md).

Обозначения в тексте:

| Обозначение | Что это | Где хранится |
| --- | --- | --- |
| `<SERVER_IP>` | постоянный публичный IPv4 VPS из панели Contabo | только `.env` на сервере (`SERVER_IP`) и ваши личные заметки; **никогда** не в git и не в документах |
| `duri0.duckdns.org` | адрес нашего сервера (`STOAT_DOMAIN`) | `.env` |
| `<admin>` | имя администратора на VPS | — |
| `<DUCKDNS_TOKEN>` | токен учётной записи DuckDNS | менеджер паролей; на сервере — только если нужен контейнер обновления IP |
| `0.16.0-fork.N` | тег образов бэкенда (`APP_TAG`); в `GET /api/` он виден как `0.16.0+fork.N` | `.env` |

> [!NOTE]
> Порядок и команды сверены с кодом репозитория (`scripts/*.sh`, `compose.yml`, `Caddyfile`). Стек целиком
> проверен локально (режим `lan`, локально собранные образы). Шаги, помеченные **«не проверено на боевом
> сервере»**, на реальном VPS ещё не выполнялись — при первом деплое отметьте результат в журнале деплоя.

## Содержание

1. [Что подготовить](#1-что-подготовить)
2. [Заказ VPS](#2-заказ-vps)
3. [Первый вход и укрепление системы](#3-первый-вход-и-укрепление-системы)
4. [Файрвол](#4-файрвол)
5. [Docker](#5-docker)
6. [DuckDNS](#6-duckdns)
7. [Репозиторий и конфигурация](#7-репозиторий-и-конфигурация)
8. [Push (FCM)](#8-push-fcm)
9. [Запуск и проверки](#9-запуск-и-проверки)
10. [Первый аккаунт, администратор, приглашения](#10-первый-аккаунт-администратор-приглашения)
11. [Выпуск клиентов](#11-выпуск-клиентов)
12. [Включение E2EE](#12-включение-e2ee)
13. [Мониторинг и логи](#13-мониторинг-и-логи)
14. [Обновление и откат](#14-обновление-и-откат)
15. [Бэкапы](#15-бэкапы)
16. [Неполадки](#16-неполадки)
17. [Чек-лист](#17-чек-лист)

## 1. Что подготовить

До заказа сервера:

- **SSH-ключ** на своей машине (`ssh-keygen -t ed25519 -C <admin>`), публичная часть — `~/.ssh/id_ed25519.pub`.
- **DuckDNS**: вход на duckdns.org (через GitHub/Google), поддомен `duri0` (у нас уже занят), токен со страницы
  учётной записи → в менеджер паролей. Токен даёт право менять запись — не публиковать.
- **GitHub [DakarXYZ](https://github.com/DakarXYZ)** с включённой 2FA (обязательно: установщик Windows выходит без
  подписи кода, целостность обновлений держится на защите аккаунта). Репозитории `durio-*` созданы.
- **Firebase** — проект `durio-617f5`: ключ сервисного аккаунта (JSON) для отправки push через FCM. Ключ кладётся
  только на наши серверы. Где хранится у разработчика — в его локальной папке секретов; в git и в чаты не попадает.
- **Android release keystore** (подпись APK) и секреты GitHub Actions для `durio-for-android` — см.
  [§11](#11-выпуск-клиентов).
- **Почта для Let's Encrypt** (`ACME_EMAIL`) — уведомления о сертификатах.
- **Менеджер паролей** — для `secrets.env` (его зашифрованной копии), пароля restic (когда включите бэкапы),
  токена DuckDNS.
- (Опционально) **SignPath** — подпись Windows-установщика, если пользователи упрутся в Smart App Control. Не
  обязательно для первого выпуска.
- (Опционально) **age** на своей машине (`age-keygen -o key.txt`) — для зашифрованной копии `secrets.env`.

## 2. Заказ VPS

- **Тариф**: Cloud VPS. Минимум по плану — 2 vCPU / 4 ГБ RAM / 40 ГБ SSD + место под файлы. Лимиты памяти
  контейнеров в `compose.yml` в сумме около 8 ГБ (Mongo и autumn по 1,5 ГБ, LiveKit 1 ГБ …) — это потолки, а не
  резерв, но **рекомендуется 8 ГБ RAM**; на 4 ГБ стек работает только при малой нагрузке (не проверено на боевом
  сервере). Процессор x86-64 с AVX (нужно MongoDB 5+), у Contabo это так. Образы собираются только для amd64.
- **ОС**: Ubuntu 24.04 LTS (чистый образ; если образ не чистый — переустановить из панели).
- **Регион**: ближайший к пользователям (для Европы и СНГ — Германия).
- **Доступ**: при заказе добавить свой публичный SSH-ключ (если панель предлагает) и задать пароль root.
- После выдачи: записать `<SERVER_IP>` в менеджер паролей (не в репозиторий), проверить в панели, есть ли у
  тарифа снапшоты и включён ли файрвол панели (см. [§4](#4-файрвол)).

## 3. Первый вход и укрепление системы

```bash
ssh root@<SERVER_IP>
apt update && apt full-upgrade -y && reboot
```

Пользователь-администратор и вход по ключу:

```bash
adduser <admin>
usermod -aG sudo <admin>
mkdir -p /home/<admin>/.ssh
cp /root/.ssh/authorized_keys /home/<admin>/.ssh/   # или вставить свой .pub
chown -R <admin>:<admin> /home/<admin>/.ssh && chmod 700 /home/<admin>/.ssh && chmod 600 /home/<admin>/.ssh/authorized_keys
```

**В отдельной сессии** проверить `ssh <admin>@<SERVER_IP>` и `sudo -v`. Только после этого — закрыть пароли и root:

```bash
sudo tee /etc/ssh/sshd_config.d/10-durio.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers <admin>
EOF
sudo sshd -t && sudo systemctl restart ssh
sudo apt install -y fail2ban    # jail sshd включён по умолчанию
```

Обновления, время, swap, утилиты:

```bash
sudo apt install -y unattended-upgrades needrestart chrony git jq curl openssl age
sudo dpkg-reconfigure -plow unattended-upgrades       # без автоперезагрузки (по умолчанию она выключена)
sudo timedatectl set-timezone UTC
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Снапшот в панели Contabo — «чистая система» (точка отката, пока бэкапы выключены).

## 4. Файрвол

**ufw не фильтрует порты, опубликованные Docker** (DNAT в цепочке `DOCKER` раньше `INPUT`). Поэтому наружу
публикуют порты только два контейнера — это задано в `compose.yml` и проверяется `scripts/check-ports.sh`
(CI и `preflight.sh`):

| Порт | Кто | Зачем |
| --- | --- | --- |
| 22/tcp | sshd хоста | администрирование; по возможности только с доверенных адресов |
| 80/tcp | caddy | ACME HTTP-01 (выпуск сертификата) и редирект на HTTPS |
| 443/tcp | caddy | HTTPS: API, WebSocket `/ws`, файлы, LiveKit-сигналинг `/livekit` |
| 443/udp | caddy | HTTP/3 |
| 7881/tcp | livekit | ICE/TCP (медиа, если UDP недоступен) |
| 7882/udp | livekit | медиа звонков, один мультиплексный UDP-порт (`livekit.yml`: `rtc.udp_port`) |

Mongo, Valkey, RabbitMQ, MinIO, api, events и остальное — только во внутренней сети `durio_default`.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp            # лучше: sudo ufw allow from <ваш адрес> to any port 22 proto tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw allow 7881/tcp
sudo ufw allow 7882/udp
sudo ufw status                  # правило для SSH на месте?
sudo ufw enable
```

**Файрвол в панели Contabo**: если он включён для VPS — продублировать там те же правила (22, 80, 443/tcp+udp,
7881/tcp, 7882/udp). Если выключен — не нужен. Ограничение доступа к docker-портам по IP — только через цепочку
`DOCKER-USER` (или `ufw-docker`), не через ufw.

Внешняя проверка — после запуска стека ([§9](#9-запуск-и-проверки)).

## 5. Docker

Docker Engine и compose plugin ≥ 2.24 — из официального репозитория `download.docker.com`:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
docker compose version           # >= 2.24
```

Настройки демона (шаблон — [daemon.json](daemon.json)):

```bash
echo '{"log-driver":"local","live-restore":true,"userland-proxy":false}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
sudo usermod -aG docker <admin>  # перелогиниться; группа docker = фактически root
```

## 6. DuckDNS

IP у VPS Contabo постоянный, поэтому контейнер обновления IP не нужен (флаг `--no-ddns` в [§7](#7-репозиторий-и-конфигурация)).
Запись `duri0.duckdns.org` → `<SERVER_IP>` выставляется один раз — на странице duckdns.org или запросом:

```bash
# с любой машины; токен не попадает в историю, если начать строку с пробела (HISTCONTROL=ignorespace)
 curl -fsS "https://www.duckdns.org/update?domains=duri0&token=<DUCKDNS_TOKEN>&ip=<SERVER_IP>"   # ответ OK
dig +short duri0.duckdns.org                                                                       # = <SERVER_IP>
```

Если IP когда-нибудь станет динамическим — генератор без `--no-ddns` и с `export DUCKDNS_TOKEN=...` включит
профиль `duckdns` (контейнер `linuxserver/duckdns` обновляет запись сам). Отдельный cron тогда не нужен.

**Смена адреса сервера = все пользователи заново добавляют аккаунт** (клиенты привязывают аккаунт, токены и
кэш к адресу). Поддомен выбирается один раз.

## 7. Репозиторий и конфигурация

```bash
sudo mkdir -p /srv/durio && sudo chown <admin>: /srv/durio && cd /srv/durio
git clone --branch <тег релиза> https://github.com/DakarXYZ/durio-self-hosted
cd durio-self-hosted
git config core.hooksPath .githooks          # pre-commit: запрет IPv4-адресов в коммитах
```

Тег релиза репозитория развёртывания должен соответствовать тегу образов (`DEFAULT_APP_TAG` в `scripts/lib.sh`).
Пока теги `durio-self-hosted` не заведены — клонировать `main` и явно передать `--app-tag`.

Генератор пишет `.env`, `secrets.env`, `Revolt.toml`, `Revolt.overrides.toml`, `livekit.yml`, `stoat.json` и
сниппеты Caddy. **`.env` руками заранее не создавать**: если он есть, генератор без `--overwrite` откажется.
IP передаётся через переменную окружения и попадает только в `.env`:

```bash
read -rp 'SERVER_IP: ' SERVER_IP && export SERVER_IP          # ввод не попадает в историю shell
scripts/generate_config.sh --yes \
    --address-mode duckdns --address duri0 --no-ddns \
    --acme-email <почта> \
    --app-tag 0.16.0-fork.N \
    --storage minio \
    --max-file-size 100
```

Опции, которые стоит знать (полный список — `scripts/generate_config.sh --help`):

| Опция | Что делает |
| --- | --- |
| `--address-mode duckdns --address duri0` | адрес `duri0.duckdns.org`, TLS от Let's Encrypt |
| `--no-ddns` | без контейнера обновления IP (постоянный IP) |
| `--storage minio` + `--minio-data-path PATH` | файлы в MinIO на этом сервере; путь можно вынести на отдельный диск |
| `--max-file-size MB` | лимит вложений (по умолчанию 100); тело запроса = лимит + 5 МБ |
| `--admins ID[,ID...]` | администраторы сервера (завершают сеансы пользователей из клиента); задаётся после первого входа, [§10](#10-первый-аккаунт-администратор-приглашения) |
| `--fcm-json FILE` | ключ сервисного аккаунта Firebase → `REVOLT__PUSHD__FCM__*` в `secrets.env` |
| `--video` / `--no-video` | камера и демонстрация экрана, до 1920×1080 (по умолчанию включено) |
| `--name NAME` | отображаемое имя сервера в `/.well-known/stoat` (по умолчанию `dur.io`) |
| `--overwrite` | перегенерировать `.env`/`Revolt.toml`/… с бэкапом `*.<дата>.bak`; `secrets.env` и `Revolt.overrides.toml` не трогаются никогда |

Что получилось:

- `Revolt.overrides.toml` — ручные политики, создаётся один раз: `invite_only = true`, `trust_cloudflare = true`
  (Caddy передаёт реальный IP клиента), `[features.e2ee] enabled = false`. **E2EE здесь руками не включать** —
  только скриптом в [§12](#12-включение-e2ee).
- `[api.security.captcha]` пустая — **hCaptcha не включать**: CSP Windows-клиента её блокирует, регистрация и
  вход там сломаются. Генератор откажется работать, если найдёт ключ hCaptcha.
- `production = false` всегда (при `true` бэкенд шлёт письма с брендом Stoat и включает Discover).

**Сразу** сохранить `secrets.env` вне сервера: без `REVOLT__FILES__ENCRYPTION_KEY` все загруженные файлы
нечитаемы, ключ не ротируется, а бэкапов пока нет.

```bash
age -r <публичный age-ключ> secrets.env > secrets.env.age
# скопировать secrets.env.age к себе (scp) и в менеджер паролей, затем удалить с сервера:
rm secrets.env.age
```

SMTP по умолчанию не настроен: тогда почта при регистрации не подтверждается (аккаунт активен сразу), сброс
пароля по почте не работает. Если понадобится — `[api.smtp]` в `Revolt.overrides.toml`, пароль —
`REVOLT__API__SMTP__PASSWORD` в `secrets.env`, затем рестарт бэкенда (команда в [§10](#10-первый-аккаунт-администратор-приглашения)).

## 8. Push (FCM)

Push на Android работает только через сервер, у которого есть ключ нашего Firebase-проекта `durio-617f5`.
Скопировать JSON сервисного аккаунта на сервер (`scp`), подключить и удалить файл:

```bash
scripts/generate_config.sh --overwrite --yes --fcm-json ~/firebase-sa.json
shred -u ~/firebase-sa.json
grep -c '^REVOLT__PUSHD__FCM__' secrets.env       # 10 строк
```

Ключ уже есть в `secrets.env` → генератор его не меняет (ротация — правкой `secrets.env` руками, затем
`scripts/compose up -d pushd` и удаление старого ключа в Google Cloud). Проверка доставки — push на тестовый
телефон в [§9](#9-запуск-и-проверки) (не проверено на боевом сервере).

## 9. Запуск и проверки

Все команды compose — через `scripts/compose` (обычный `docker compose` не подставит пароли из `secrets.env`).

```bash
scripts/preflight.sh                              # конфиг на месте, нет публичных дефолтных ключей, порты
scripts/compose pull
scripts/compose up -d
scripts/compose ps                                # все сервисы running/healthy; createbuckets и database-init — exited (0)
scripts/smoke.sh --expect-version 0.16.0+fork.N
```

Первый старт: Mongo создаёт replica set `rs0` (сервис `database-init`), `api` выполняет миграции БД, Caddy
получает сертификат Let's Encrypt (порт 80 должен быть открыт снаружи). Это может занять пару минут.

`scripts/smoke.sh` проверяет: `/`, `/e2ee.html` и страницу приглашения `/invite/<код>` (200), `/ingress` (404), `/autumn/`, `/january/`,
`/.well-known/stoat` с полем `api`, `GET /api/` с ожидаемой версией, что тело 3 МиБ доходит до API, WebSocket `/ws`.

Ручные проверки:

```bash
curl -fsS https://duri0.duckdns.org/.well-known/stoat         # {"api":"https://duri0.duckdns.org/api","name":"dur.io"}
curl -fsS https://duri0.duckdns.org/api/ | jq '.revolt, .features.e2ee'
curl -sI http://duri0.duckdns.org/ | head -1                  # редирект на https
scripts/compose logs caddy | grep -iE 'certificate obtained|error'
```

Снаружи (с другой машины):

```bash
nmap -sS -p- <SERVER_IP>              # открыты только 22, 80, 443, 7881
nmap -sU -p 443,7882 <SERVER_IP>      # 443, 7882
```

Вживую (после [§10](#10-первый-аккаунт-администратор-приглашения)): вход с телефона, отправка файла (MinIO),
звонок и демонстрация экрана (LiveKit), push на телефон при закрытом приложении. Результаты — в журнал деплоя
(вне публичного репозитория). Затем снапшот VPS — «стек развёрнут».

## 10. Первый аккаунт, администратор, приглашения

Регистрация только по приглашению (`invite_only = true`). Пропуском служит обычное приглашение на сервер
(`/invite/<код>`), но для него нужен аккаунт с сервером, а его ещё нет. Поэтому порядок такой: ручное
приглашение → первый аккаунт → `--admins` → TOTP → свой сервер и обычные приглашения на него.

**1. Ручное приглашение для первого аккаунта:**

```bash
CODE=$(openssl rand -hex 8); echo "$CODE"
scripts/compose exec database mongosh -u root -p --authenticationDatabase admin revolt --quiet     --eval "db.account_invites.insertOne({_id: '$CODE'})"
# пароль root Mongo — MONGO_ROOT_PASSWORD в secrets.env
```

Ручной код бессрочный и одноразовый: после регистрации бэкенд помечает его `used` и второй раз не принимает.
Неиспользованный можно удалить: `db.account_invites.deleteOne({_id: '<код>'})`.

**2. Первый аккаунт.** В приложении (Android или Windows) добавить сервер `duri0.duckdns.org`, перейти к
регистрации и вставить в поле приглашения код. Без SMTP аккаунт
сразу подтверждён; при первом входе приложение попросит выбрать имя пользователя.

**3. Назначить администратором.** Узнать id пользователя:

```bash
scripts/compose exec database mongosh -u root -p --authenticationDatabase admin revolt --quiet     --eval 'db.users.findOne({username: "<имя>", discriminator: "<1234>"})._id'
```

Назначить и перезапустить бэкенд (конфиг читается только при старте):

```bash
scripts/generate_config.sh --overwrite --yes --admins <id>        # несколько — через запятую; '' снимает всех
scripts/compose up -d --force-recreate api events autumn january crond pushd voice-ingress
```

**4. Включить TOTP.** Действия администратора доступны только с включённой в аккаунте двухфакторной
аутентификацией приложением-аутентификатором (настройки безопасности аккаунта в приложении). Перед действием
приложение спрашивает код и включает режим администратора для текущего сеанса на 60 минут
(`[api.admins] elevation_minutes`); выход из сеанса или его завершение режим снимает.

**5. Приглашения друзьям.** Создать свой сервер («+» → «Создать сервер») и пригласить на него обычным
приглашением Stoat: настройки сервера → «Приглашения» (или «Пригласить» у канала) → ссылка
`https://duri0.duckdns.org/invite/<код>`. Эта же ссылка — пропуск на регистрацию: бэкенд принимает код
приглашения на сервер в поле приглашения, пока оно не истекло и у него остались использования (использование
засчитывается при входе на сервер). Человек:
- **без аккаунта** — ставит приложение, добавляет сервер `duri0.duckdns.org`, при регистрации вставляет ссылку
  или код; после выбора имени приложение сразу заводит его на сервер;
- **с аккаунтом** — «+» → «Присоединиться к серверу» → ссылка или код.

В браузере ссылка открывает статическую страницу сервера (браузерного клиента нет) с адресом, кодом, кнопками
«Копировать», ссылками на APK и установщик Windows и этими двумя путями.

В **«Администрировании»** (настройки, видно только администратору) можно найти пользователя (id или
`имя#1234`) и завершить один или все его сеансы — например, после потери телефона. Вместе с сеансом удаляется его устройство E2EE. Действия пишутся в лог `api`
(`scripts/compose logs api | grep 'Admin '`).

Ручные коды через `mongosh` (шаг 1) по-прежнему работают — запасной путь, если, например, у единственного
администратора пропал доступ к аутентификатору.

## 11. Выпуск клиентов

Порядок важен: следующий шаг собирается из артефактов предыдущего.

1. **durio-crypt `v0.2.1`** (крипто-ядро). Тег `v0.2.1` на коммите сборки пина → workflow `aar.yml` прикладывает к
   релизу `stoat-crypto-0.2.1.aar`, `.aar.sha256`, `.pom`; `wasm.yml` — npm-архив для Windows-клиента.
   **Сверка:** `.aar.sha256` релиза = пин в `durio-for-android/gradle/verification-metadata.xml`. Не совпало —
   APK не публиковать, сначала обновить пин и прогнать тесты Android.
2. **durio-for-android.** Секреты Actions: `DURIO_KEYSTORE_BASE64` (keystore в base64), `DURIO_KEYSTORE_PASSWORD`,
   `DURIO_KEY_ALIAS`, `DURIO_KEY_PASSWORD`, `DURIO_GOOGLE_SERVICES_JSON_BASE64` (release `google-services.json`).
   Переменные: `DURIO_LINK_HOST=duri0.duckdns.org` (App Links), `DURIO_DEFAULT_SERVER` — пусто (сервера по
   умолчанию нет). Push в основную ветку → `durio-android.yml` зелёный (AAR качается из релиза ядра и проходит
   проверку SHA-256); тег `v<versionName>` → `durio-release.yml` публикует подписанные APK по ABI, `SHA256SUMS` и
   `update.json` (для проверки обновлений в приложении).
   App Links (по желанию): `config/well-known/assetlinks.json` по образцу `assetlinks.json.example` с отпечатком
   SHA-256 ключа подписи APK; Caddy отдаёт его на `/.well-known/assetlinks.json`.
3. **durio-for-desktop `v0.1.0`** (Windows): сначала запушить for-web и обновить пин сборки, затем тег → CI
   создаёт черновик релиза с установщиком без подписи и `SHA256SUMS`; опубликовать вручную после сверки.
   Подпись через SignPath — по желанию, позже.

Ссылки на APK и установщик уже есть на странице сервера `https://duri0.duckdns.org/` (`config/site/index.html`),
памятка по E2EE — `https://duri0.duckdns.org/e2ee.html`.

## 12. Включение E2EE

Только **после** выпуска APK с E2EE и проверок на устройствах; до этого флаг выключен. Снапшот VPS перед включением.

```bash
scripts/e2ee-enable.sh --check      # всё на одном теге, флаг пока выключен
scripts/e2ee-enable.sh              # проверки → enabled = true в overrides → рестарт бэкенда → GET /api/
scripts/smoke.sh                    # теперь падает, если E2EE когда-нибудь окажется выключенным
```

**Обратно не выключается**: выключение делает зашифрованные чаты «только для чтения», `--disable` скрипт
отклоняет. При проблемах — откат тега образов или исправление, флаг не трогать. Проверка вживую: два телефона,
включить шифрование в ЛС, сообщение, файл, сверка эмодзи.

Через 1–2 месяца, когда активные пользователи обновятся, — шифрование новых ЛС по умолчанию (этот флаг
можно вернуть):

```bash
scripts/e2ee-enable.sh --default-for-new-dms
```

Мониторинг E2EE-коллекций и ящиков `to_device` — в README, раздел «Сквозное шифрование».

## 13. Мониторинг и логи

- **Внешний мониторинг** (UptimeRobot / healthchecks.io, не на этом сервере): HTTPS
  `https://duri0.duckdns.org/api/` с ключевым словом `revolt`, TCP 7881, срок сертификата (< 14 дней — тревога).
- **Состояние**: `scripts/compose ps` (нет `restarting`/`unhealthy`), `docker stats --no-stream` (память autumn,
  mongo, livekit), `df -h` (место под `data/`).
- **Логи**: `scripts/compose logs -f --tail=200 api` (так же `events`, `autumn`, `pushd`, `caddy`, `livekit`).
  Драйвер `local` в `daemon.json` ротирует их сам. Открытый текст сообщений и ключи бэкенд в лог не пишет.
- Обновления ОС ставит `unattended-upgrades`; перезагрузку, если её просит `needrestart`, — вручную в тихое время.

## 14. Обновление и откат

Перед каждым обновлением — снапшот VPS в панели Contabo (пока бэкапы выключены).

```bash
cd /srv/durio/durio-self-hosted
git fetch --tags && git checkout <новый тег репозитория>   # compose.yml, скрипты, migrations/
scripts/upgrade.sh 0.16.0-fork.N+1
```

`upgrade.sh`: preflight → **всегда** локальный `mongodump --oplog` в `backups/pre-upgrade/` (хранятся 3
последних) → полный бэкап, если включён → `pull` → невыполненные `migrations/*.sh` → `api` (миграции БД) →
остальные сервисы → `smoke.sh`. Журнал — `logs/`.

- Сбой **без** миграций БД — автоматический откат на прежний тег.
- Сбой **после** миграций — сервисы останавливаются, скрипт печатает команду восстановления дампа
  (`scripts/restore.sh --from-archive backups/pre-upgrade/<файл>.archive.gz`). Либо — откат снапшота VPS.
- Ручной откат тега без миграций: `scripts/upgrade.sh <прежний тег>`.

## 15. Бэкапы

Скрипты готовы, но **выключены** (`BACKUP_ENABLED=false`): потеря диска = потеря данных. Пока цели нет —
снапшоты VPS вручную и копия `secrets.env` вне сервера. Включение одной командой (root), когда появится цель:

```bash
sudo apt install -y restic
sudo scripts/backup-enable.sh --target local:/srv/backup [--hc-url https://hc-ping.com/<uuid>]
# позже: --target s3:https://<endpoint>/<bucket>  или  --target rclone:<remote>:<path>
```

restic, таймер 03:30 UTC, 7 дневных / 4 недельных / 6 месячных. Пароль restic (`/root/.config/restic/password`)
сразу унести в менеджер паролей. Локальная цель спасает от ошибок администратора, но не от потери диска.
Проверка восстановления — `scripts/restore.sh --dry-run`. Не проверено на боевом сервере.

## 16. Неполадки

**Сертификат не выдаётся.** `scripts/compose logs caddy`. Проверить: `dig +short duri0.duckdns.org` = `<SERVER_IP>`;
порт 80 открыт снаружи (ufw и файрвол панели); в логах нет `rateLimited`. Let's Encrypt ограничивает выпуск
(5 одинаковых сертификатов в неделю) — при переустановке сохранять `data/caddy-data`, не удалять его «на всякий
случай». `duckdns.org` в Public Suffix List, так что лимит у поддомена свой.

**WebSocket не подключается / клиент «бесконечно подключается».** `scripts/smoke.sh` (проверка `/ws`),
`scripts/compose ps events` (healthy), `scripts/compose logs events`. Путь — ровно `/ws`. Проверить, что ничего
не стоит перед Caddy (если стоит — генератор с `--behind-proxy`).

**Звонки: нет звука/видео, сигналинг есть.** Медиа идут мимо Caddy: открыты ли 7882/udp и 7881/tcp (ufw, файрвол
Contabo, `nmap -sU -p 7882`). LiveKit узнаёт внешний IP через STUN (`use_external_ip: true`) — нужен исходящий
UDP; после смены IP — `scripts/compose restart livekit`. TURN выключен: у пользователей в сетях, где закрыт и UDP,
и произвольный TCP (корпоративные сети), звонки могут не работать. `scripts/compose logs livekit`.

**Файлы до 100 МБ не загружаются.** Ответ 413 — лимит в `Revolt.toml` меньше файла: `--max-file-size` и рестарт
бэкенда. Контейнер autumn перезапускается (`OOMKilled` в `docker inspect`) — autumn держит файл в памяти при
шифровании, лимит контейнера 1536 МБ рассчитан на 100 МБ; больший лимит файлов требует больше памяти
(`compose.override.yml`) или меньший `--max-file-size`. В зашифрованных чатах на телефоне предел ниже: файл
шифруется в памяти телефона, приложение скажет об этом само.

**Push не приходят.** `grep -c '^REVOLT__PUSHD__FCM__' secrets.env`, `scripts/compose logs pushd` при отправке
сообщения. На чужих серверах (без нашего ключа FCM) push нет — так задумано.

**Сервис в `restarting`.** `scripts/compose logs <сервис>`; частые причины — нет места на диске, не смонтирован
`MINIO_DATA_PATH`, правка `Revolt.overrides.toml` с ошибкой TOML.

**Потерян `secrets.env`.** Без `REVOLT__FILES__ENCRYPTION_KEY` загруженные файлы не восстановить. Вернуть файл из
зашифрованной копии (`age -d`), а не генерировать заново.

## 17. Чек-лист

- [ ] VPS Ubuntu 24.04 LTS, вход только по ключу под `<admin>`, root и пароли закрыты, fail2ban
- [ ] unattended-upgrades, UTC, chrony, swap 2 ГБ; снапшот «чистая система»
- [ ] ufw: 22, 80, 443/tcp+udp, 7881/tcp, 7882/udp; файрвол панели Contabo — те же правила или выключен
- [ ] Docker из `download.docker.com`, compose ≥ 2.24, `daemon.json`
- [ ] `duri0.duckdns.org` → `<SERVER_IP>`
- [ ] `generate_config.sh` с `--no-ddns --acme-email --app-tag`; `secrets.env` зашифрован и унесён с сервера
- [ ] FCM-ключ подключён (`--fcm-json`), JSON удалён с сервера
- [ ] `scripts/compose ps` — всё healthy; `smoke.sh --expect-version` зелёный; внешний `nmap` совпадает с таблицей
- [ ] Первый аккаунт создан, назначен администратором (`--admins`), рестарт бэкенда; у админа включён TOTP,
  свой сервер создан, ссылка `/invite/<код>` открывает страницу приглашения и годится для регистрации
- [ ] Вживую: вход, файл, звонок, push; снапшот «стек развёрнут»
- [ ] Релизы: durio-crypt `v0.2.1` (`.sha256` = пин Android) → APK → Windows `v0.1.0`
- [ ] E2EE включено `scripts/e2ee-enable.sh` только после релиза APK с E2EE; `smoke.sh` зелёный
- [ ] Через 1–2 месяца — `--default-for-new-dms` (в календарь)
- [ ] Внешний мониторинг настроен; бэкапы — когда появится цель
