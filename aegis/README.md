<div align="center">

# ✳ AEGIS

**Протокол-профили для обхода блокировок** — слой именованных транспортов поверх Mihomo/sing-box.

![panel](https://img.shields.io/badge/panel-python%203-stdlib-38bdf8?style=flat-square)
![backend](https://img.shields.io/badge/backend-sing--box-0ea5e9?style=flat-square)
![client](https://img.shields.io/badge/cirrus-7dd3fc?style=flat-square)

</div>

---

## Что такое Aegis

Aegis — не новый wire-протокол, а **набор готовых профилей** с единой маркировкой `AEGIS · <профиль>`. Каждый профиль разворачивается в реальный outbound, который умеет и клиент (Cirrus / Mihomo), и сервер (sing-box):

| Профиль | Метка | Транспорт | Для кого |
|---|---|---|---|
| `turbo` | `AEGIS · UDP · FEC` | Hysteria2, UDP, obfs | ПК, ТВ, ноутбуки — максимум скорости |
| `eco` | `AEGIS · TCP · TLS · REALITY` | VLESS + REALITY | Телефоны — минимум нагрузки |
| `cfws` | `AEGIS · WS · CF` | VLESS + WebSocket за Cloudflare | Обход ТСПУ по IP через CDN |
| `cfgrpc` | `AEGIS · gRPC · CF` | VLESS + gRPC за Cloudflare | То же, альтернативный транспорт |

Ссылка имеет вид:

```
aegis://<preset>.<auth>@<host>:<port>?<params>#<name>
```

Например:

```
aegis://turbo.s3cret@203.0.113.7:443?sni=www.bing.com&obfs=salamander&obfs-password=ob1&insecure=1#Germany
```

Клиент Cirrus понимает `aegis://` нативно и превращает её в корректный конфиг Mihomo. Панель выдаёт также «сырые» `hy2://`/`vless://` ссылки для других клиентов.

## Установка на VPS (Ubuntu/Debian)

**Из приложения Cirrus:** «Добавить подписку» → «Развернуть Aegis на VPS» — приложение само подключится по SSH, зальёт этот установщик и вернёт subscription-ссылку.

**Вручную:**

```bash
curl -fsSL https://raw.githubusercontent.com/qualitydll/brew/main/aegis/install.sh | bash
```

или из клона репозитория:

```bash
git clone https://github.com/qualitydll/brew && cd brew/aegis
bash install.sh
```

Инсталлятор:

- ставит **sing-box** (бинарь + systemd-сервис),
- ставит **Aegis Panel** — веб-панель на Python 3 stdlib (порт `8901`),
- генерирует самоподписанный origin-сертификат,
- создаёт меню **`aegis`** на VPS (статус, логи, перезапуск, ссылки).

После установки вы увидите:

```
Panel:        http://<IP>:8901/?k=<token>
Subscription: http://<IP>:8901/sub/<sub_token>
```

## Панель

Открывается в браузере, тёмная тема, логотип `*`.

- **Server** — публичный хост/IP, подставляется в ссылки.
- **New node** — выбор пресета, имя, порт, домен для CF-режимов. Ключи (UUID, REALITY keypair, пароли) генерируются автоматически.
- **Nodes** — каждая нода показывает готовые `aegis://` и raw-ссылки с кнопкой копирования.
- **Subscription** — URL подписки (base64, формат, совместимый с Cirrus и большинством клиентов).

### Ограничения CF-пресетов

`WS · CF` и `gRPC · CF` требуют домен, проксируемый через Cloudflare (оранжевое облако). CF подключается к origin только на TCP/443, поэтому **одновременно может существовать только одна CF-нода** на сервер — панель это контролирует. Для режима «Full» (не strict) подойдёт самоподписанный сертификат, который генерирует инсталлятор.

### Открытие портов

```bash
ufw allow 443/tcp && ufw allow 8443/tcp && ufw allow 443/udp
```

Точные порты зависят от созданных нод — видны в панели.

## Файлы

| Путь | Назначение |
|---|---|
| `install.sh` | Автоустановка sing-box + панели + меню `aegis` |
| `aegis_panel.py` | Single-file панель (Python 3 stdlib, без зависимостей) |

## Приватность

- Панель доступна по токену в URL; subscription-токен отдельный.
- Не публикуйте ссылки с токенами — это полный доступ к вашим нодам.
- Используйте только серверы, к которым у вас есть право доступа.
