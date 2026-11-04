# Jitsi Meet в Docker через Ansible

[English](README.md) | **Русский**

Разворачивает [Jitsi Meet](https://jitsi.org/) из официального
[docker-jitsi-meet](https://github.com/jitsi/docker-jitsi-meet) на один сервер и добавляет то, чего нет
в стандартной установке:

- **обмен файлами в чате** — вкладка «Файлы», перетаскивание мышью, скачивание остальными участниками;
  без JWT, загрузка для всех участников или только для модераторов;
- **автоочистка** файлов из чата и записей конференций (Jibri) — по сроку хранения и общему объёму;
- **мониторинг** — Prometheus и Grafana с дашбордами: комнаты и участники, видеомост, сервер;
- **настройки по файлам**: основное в `vars.yml`, каждая функция — в своём файле в `plugins/`.

## Требования

- Сервер на Linux с Docker и Docker Compose v2, доступ по SSH (проверено на Ubuntu);
- домен и обратный прокси с HTTPS перед Jitsi (например, [Nginx Proxy Manager](https://nginxproxymanager.com/)):
  Jitsi слушает HTTP на порту `jitsi_http_port` (по умолчанию 8000), прокси делает `https://<домен>` → `http://<сервер>:8000`;
- открытый UDP-порт 10000 для видео (JVB);
- на своей машине: Python 3.10+, `openssl`.

## Быстрый старт

```bash
git clone https://github.com/BaldejAleksandr/Baldej-Jitsi-Meet.git && cd Baldej-Jitsi-Meet

# Ansible и коллекции — в каталоге проекта
python3 -m venv .venv
.venv/bin/pip install 'ansible-core>=2.17,<2.19'
.venv/bin/ansible-galaxy collection install -r requirements.yml -p ./collections
source .venv/bin/activate

# Свой сервер и домен
cp inventory/hosts.yml.example inventory/hosts.yml                                  # IP, пользователь, SSH-ключ
cp inventory/group_vars/jitsi/site.yml.example inventory/group_vars/jitsi/site.yml  # jitsi_public_url, monitoring_grafana_url

# Пароли сервисов: ключ vault + случайные пароли, сразу зашифровать
openssl rand -base64 32 > .vault_pass && chmod 600 .vault_pass
for k in jicofo_auth jvb_auth jigasi_xmpp jigasi_transcriber jibri_recorder jibri_xmpp; do
  echo "vault_jitsi_${k}_password: $(openssl rand -hex 16)"
done > inventory/group_vars/jitsi/vault.yml
echo "vault_monitoring_grafana_admin_password: $(openssl rand -hex 16)" >> inventory/group_vars/jitsi/vault.yml
ansible-vault encrypt inventory/group_vars/jitsi/vault.yml

# Проверить и развернуть
ansible-playbook playbooks/deploy.yml --check --diff
ansible-playbook playbooks/deploy.yml --diff
```

`.vault_pass` — единственный ключ к `vault.yml`: храните копию в менеджере паролей, без него пароли
не расшифровать. Пароль vault Ansible берёт из этого файла сам (см. `ansible.cfg`).

## Структура

```text
ansible.cfg                       настройки Ansible: инвентарь, роли, коллекции, файл пароля vault
requirements.yml                  коллекции: community.docker, ansible.posix
playbooks/deploy.yml              установка и обновление
inventory/
├── hosts.yml(.example)           сервер (hosts.yml не в git)
└── group_vars/jitsi/             Ansible читает все .yml отсюда, включая подкаталоги
    ├── vars.yml                  основное: версия Jitsi, порты, ссылки на пароли
    ├── site.yml(.example)        адрес Jitsi (site.yml не в git)
    ├── vault.yml(.example)       пароли сервисов, ansible-vault (vault.yml не в git)
    └── plugins/
        ├── recordings.yml        запись конференций и автоочистка записей
        ├── file_sharing.yml      обмен файлами в чате
        └── monitoring.yml        Prometheus и Grafana
roles/
├── jitsi/                        docker-jitsi-meet: релиз, .env, compose, очистка записей
├── jitsi_file_sharing/           сервис файлов и подключение его к Jitsi
└── monitoring/                   Prometheus, node-exporter, json-exporter, Grafana и дашборды
docs/                             заметки по эксплуатации
```

Одну переменную задавайте только в одном файле: при повторе молча победит файл, прочитанный позже.
Итоговые значения: `ansible-inventory --host <имя хоста> --yaml`.

На сервере:

| Путь | Что там |
|---|---|
| `/opt/jitsi-meet/releases/<версия>`, `/opt/jitsi-meet/current` | файлы релиза docker-jitsi-meet и симлинк на активный |
| `/opt/jitsi-meet-cfg` | конфиги и данные контейнеров Jitsi |
| `/opt/jitsi-meet-cfg/storage/jibri/recordings` | записи конференций |
| `/opt/jitsi-file-sharing` | сервис файлов: исходники, ключи, `uploads/` |
| `/opt/monitoring` | мониторинг: конфиги, `data/prometheus`, `data/grafana` |

Compose-проекты: `jitsi`, `jitsi-file-sharing` и `monitoring`.

## Настройка

### Основное — `vars.yml` и `site.yml`

| Переменная | По умолчанию | Что задаёт |
|---|---|---|
| `jitsi_public_url` | — (обязательно, в `site.yml`) | адрес, по которому Jitsi открывается в браузере |
| `jitsi_version` | `stable-11248-2` | тег [docker-jitsi-meet](https://github.com/jitsi/docker-jitsi-meet/releases) |
| `jitsi_http_port` / `jitsi_https_port` | `8000` / `8443` | порты веб-контейнера |
| `jitsi_advertise_ips` | `ansible_host` | публичный IP для видео (JVB) |
| `jitsi_tz` | `UTC` | часовой пояс контейнеров |
| `jitsi_enable_auth` | `false` | вход по логину для создания комнат |
| `jitsi_extra_env` | `{}` | любые переменные из `env.example` релиза |

```yaml
jitsi_extra_env:
  ENABLE_LOBBY: 1
  JIBRI_RECORDING_RESOLUTION: 1920x1080
```

Обновление Jitsi: поменять `jitsi_version` и запустить `deploy.yml`.

### Записи конференций — `plugins/recordings.yml`

```yaml
jitsi_enable_recording: true
jitsi_recordings_retention_days: 30       # сколько дней хранить запись
jitsi_recordings_max_total_size_gb: 15    # общий объём; сверх него удаляются самые старые
jitsi_recordings_cleanup_minute: "0"      # расписание очистки, поля cron
jitsi_recordings_cleanup_hour: "*/4"
```

Очистку выполняет `/usr/local/sbin/jitsi-recordings-cleanup` по cron. Идущую запись она не трогает:
пропускаются записи, менявшиеся за последние 10 минут. Журнал: `journalctl -t jitsi-recordings-cleanup`.

Ориентир по размеру при настройках Jibri по умолчанию (720p, 30 кадров/с, H.264 CRF 25):
от ~2 ГБ (статичная картинка) до ~15 ГБ (активная демонстрация экрана) за 8 часов.

### Обмен файлами — `plugins/file_sharing.yml`

```yaml
jitsi_file_sharing_enabled: true          # false — роль удалит сервис и отключит вкладку
jitsi_file_sharing_upload_for_all: true   # false — загружать могут только модераторы
jitsi_file_sharing_max_file_size_mb: 10
jitsi_file_sharing_max_total_size_gb: 5   # перед загрузкой сервис удаляет самые старые файлы сверх лимита
jitsi_file_sharing_retention_hours: 24
jitsi_file_sharing_cleanup_minute: "*/10" # расписание удаления по сроку, поля cron
jitsi_file_sharing_cleanup_hour: "*"
jitsi_file_sharing_allowed_extensions:    # расширения без точки
  - pdf
  - xlsx
  - ods
```

Как это устроено:

- хранилище — официальный пример [jitsi-meet-file-sharing-service](https://github.com/jitsi/jitsi-meet-file-sharing-service)
  на зафиксированном коммите (`jitsi_file_sharing_service_version`). Образ собирается на сервере;
  перед сборкой `roles/jitsi_file_sharing/files/patch.sh` вносит правки: лимит размера и список расширений
  из переменных, общий лимит объёма, учёт обратного прокси при ограничении частоты запросов;
- Prosody: `conf.d/file-sharing.cfg.lua` (короткоживущие токены, права, компонент `filesharing`), модули через
  `XMPP_MODULES` / `XMPP_MUC_MODULES` в `.env` — не задавайте их в `jitsi_extra_env`;
  модуль `mod_file_sharing_everyone.lua` выдаёт право загрузки участникам без прав модератора;
- web: `nginx-custom/file-sharing.conf` проксирует `/file-service/` в сервис, блок `config.fileSharing` в `custom-config.js`.

Безопасность: тип файла определяется по расширению из списка, исполняемые файлы (ELF, PE, Mach-O) отклоняются
по содержимому; файлы отдаются на скачивание (`Content-Disposition: attachment`), а не открываются в браузере;
ссылка на скачивание подписана и живёт 1 час. Антивирусной проверки нет — держите список расширений коротким.

Ограничения: список файлов комнаты хранится в памяти сервиса и теряется при его перезапуске
(файлы на диске удалит очистка); удалить файл может любой участник с правом загрузки.

### Мониторинг — `plugins/monitoring.yml`

```yaml
monitoring_enabled: true                  # false — роль удалит стек вместе с метриками и данными Grafana
monitoring_grafana_proxy_network: nginx_proxy_default
monitoring_prometheus_retention_time: 30d # сколько хранить метрики
monitoring_prometheus_retention_size: 2GB # лимит на диске
monitoring_scrape_interval: 15s
```

В `site.yml` — `monitoring_grafana_url: https://grafana.example.com`, в `vault.yml` —
`vault_monitoring_grafana_admin_password` (пользователь `admin`; пароль из vault задаётся при каждом прогоне).

Подключение Grafana: DNS-запись поддомена на сервер, затем в Nginx Proxy Manager — Proxy Host
`grafana.example.com` → `http` `grafana` `3000`, сертификат Let's Encrypt, Websockets Support включить.
Grafana подключена к docker-сети NPM (`monitoring_grafana_proxy_network`) и наружу портов не открывает;
с пустым значением она слушает `127.0.0.1:3001`.

Дашборды (папка Jitsi):

- **Jitsi — комнаты** — комнаты прямо сейчас (участники, сколько идёт), участники по каждой комнате во времени,
  пик за период;
- **Jitsi — видеомост и сервисы** — конференции, участники, трафик, потери пакетов, нагрузка и ошибки подключения JVB, Jicofo;
- **Сервер** — процессор, память, диски, сеть, load average.

Как это устроено:

- комнаты: модуль Prosody `muc_census` отдаёт список комнат на `http://prosody:5280/room-census` (только внутри
  docker-сети), `json-exporter` превращает его в метрики `jitsi_room_participants{room}` и `jitsi_room_created_time{room}`;
- JVB отдаёт метрики на `jvb:8080/metrics`, Jicofo — на `jicofo:8888/metrics` (роль jitsi включает `JICOFO_ENABLE_REST`);
- `node-exporter` работает в сети хоста, чтобы видеть настоящие сетевые интерфейсы, и слушает только шлюз
  сети мониторинга (`monitoring_gateway`), поэтому порт 9100 снаружи недоступен;
- дашборды лежат в `roles/monitoring/files/dashboards/`; правки в интерфейсе Grafana не сохраняются —
  меняйте JSON в репозитории (можно отредактировать в Grafana, затем Export → JSON и заменить файл).

## Полезное

- `ansible-playbook playbooks/deploy.yml --check --diff` — посмотреть изменения без применения;
- `ansible-vault edit inventory/group_vars/jitsi/vault.yml` — изменить пароли;
- `ansible-config validate -t all` — проверить `ansible.cfg` на опечатки;
- [docs/filesystems-df.md](docs/filesystems-df.md) — как читать `df -h` на сервере с Docker.

## Сторонние компоненты

В репозиторий они не копируются — всё скачивается при развёртывании:

- [docker-jitsi-meet](https://github.com/jitsi/docker-jitsi-meet) и образы Jitsi — Apache-2.0;
- [jitsi-meet-file-sharing-service](https://github.com/jitsi/jitsi-meet-file-sharing-service) — Apache-2.0,
  собирается с правками из `patch.sh`;
- [Prometheus](https://prometheus.io/), [node-exporter](https://github.com/prometheus/node_exporter),
  [json-exporter](https://github.com/prometheus-community/json_exporter) — Apache-2.0;
  [Grafana](https://grafana.com/) — AGPL-3.0; используются официальные образы;
- коллекции Ansible `community.docker` и `ansible.posix` — GPL-3.0.

## Лицензия

[MIT](LICENSE)
