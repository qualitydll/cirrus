<div align="center">

# Cirrus.

**Меньше шума. Больше связи.**

Минималистичный VPN-клиент для **Windows и Android** на Flutter с сетевым ядром Mihomo.

[Скачать сборки](https://github.com/qualitydll/cirrus/actions) · [Сообщить об ошибке](https://github.com/qualitydll/cirrus/issues) · [История изменений](https://github.com/qualitydll/cirrus/commits/main)

![Платформы](https://img.shields.io/badge/platforms-Windows%20%7C%20Android-1F4E79?style=flat-square)
![Flutter](https://img.shields.io/badge/UI-Flutter-02569B?style=flat-square&logo=flutter&logoColor=white)
![Core](https://img.shields.io/badge/core-Mihomo-1E1410?style=flat-square)

</div>

---

## О проекте

**Cirrus.** — компактный VPN-клиент с собственным интерфейсом, управлением профилями и серверами. Flutter отвечает за приложение, а Mihomo — за обработку сетевого трафика.

Визуальный стиль проекта строится на тёмном фоне и тёплом зелёном акценте и простом интерфейсе без лишних элементов.

> Проект находится в разработке. Возможности отдельных функций и стабильность соединения зависят от текущей версии, платформы и конфигурации.

## Возможности

- **Подключение:** системный VPN на Android; доступные системные сетевые режимы на Windows.
- **Подписки и профили:** импорт поддерживаемых ссылок и конфигураций Mihomo/Clash.
- **Серверы:** выбор узла, группы серверов и проверка задержки там, где это поддерживается.
- **Маршрутизация:** режимы маршрутизации и пользовательские правила в рамках текущей реализации.
- **Диагностика:** журнал приложения и ядра, экспериментальные инструменты диагностики.
- **Внешний вид:** темы и настройка акцентного цвета.

Список возможностей отражает реализацию проекта, но не является гарантией поддержки каждого протокола, устройства или провайдера.

## Aegis — собственный VPN-протокол

**Aegis** — это собственный зашифрованный протокол, разработанный с нуля на Go. В отличие от обычных VPN-клиентов, которые используют готовые протоколы (VLESS, Hysteria2), Aegis реализует собственный wire-формат с шифрованием ChaCha20-Poly1305 и обфускацией.

### Возможности протокола

- **Шифрование**: ChaCha20-Poly1305 (AEAD) с HKDF-SHA3-256
- **Обфускация**: random padding, timing jitter, fake packets
- **Транспорты**: TCP (текущая версия), UDP (в разработке)
- **Интерфейс**: SOCKS5 прокси для mihomo/других клиентов

### Установка сервера

```bash
# Скачать и запустить установщик
curl -fsSL https://raw.githubusercontent.com/qualitydll/cirrus/main/aegis-install.sh | bash
```

Или вручную:

```bash
# Скачать бинарь с GitHub Releases
wget https://github.com/qualitydll/aegis/releases/download/aegis-v1/aegis-linux-amd64
chmod +x aegis-linux-amd64

# Запустить сервер
./aegis-linux-amd64 server -listen :8443 -secret your_secret
```

### Использование в приложении

1. **Добавить профиль**: «Добавить» → «AEGIS Native»
2. **Указать данные**: сервер, порт, секрет
3. **Подключиться**: приложение автоматически запустит Aegis daemon и настроит mihomo

### Авто-развёртывание

В диалоге «Добавить» есть пункт **«Развернуть Aegis на VPS»** — приложение подключается по SSH, устанавливает демон и возвращает данные для подключения в один клик.

### Бинарные файлы

Сборки доступны в [GitHub Releases](https://github.com/qualitydll/aegis/releases):
- `aegis-linux-amd64` — Linux x86_64
- `aegis-windows-amd64.exe` — Windows x86_64
- `aegis-darwin-amd64` — macOS Intel
- `aegis-darwin-arm64` — macOS Apple Silicon

## Платформы

| Платформа | Статус |
| --- | --- |
| Windows | Сборка через GitHub Actions |
| Android | APK для ARM64 (arm64-v8a) через GitHub Actions |
| macOS / Linux | Не заявлены как готовые платформы |

## Скачать

1. Откройте [GitHub Actions](https://github.com/qualitydll/cirrus/actions/workflows/build.yml).
2. Выберите успешный запуск сборки.
3. В разделе **Artifacts** скачайте артефакт для своей платформы: windows-release или android-release-arm64.

Если артефакты отсутствуют, проверьте, что запуск завершился успешно. Успешная сборка подтверждает прохождение настроенных шагов CI, но не заменяет тестирование на реальном устройстве.

## Запуск из исходников

Понадобятся Flutter stable и инструменты сборки для целевой платформы. Для Windows также требуется Visual Studio 2022 с компонентом **Desktop development with C++**; для Android — Android SDK.

В корне проекта выполните:

```bash
flutter pub get
flutter analyze
flutter test
```

Запуск приложения для Windows:

```bash
flutter run -d windows
```

Сборка Windows:

```bash
flutter build windows --release
```

## Структура проекта

| Путь | Назначение |
| --- | --- |
| lib/core | Сетевое ядро, API, конфигурации и разбор ссылок |
| aegis-go/ | AEGIS: собственный VPN-протокол на Go |
| lib/state | Состояние приложения, профили и настройки |
| lib/ui | Экраны, тема и компоненты интерфейса |
| android/ | Android-приложение и VPN-служба |
| windows/ | Windows runner |
| .github/workflows/ | Автоматические сборки и проверки |
| test/ | Тесты |

## Безопасность

- Не публикуйте личные ссылки на подписки, токены, пароли и другие секреты в issues.
- Перед отправкой логов удаляйте личные данные и конфиденциальные параметры конфигурации.
- Используйте только серверы и подписки, к которым у вас есть разрешённый доступ.

## Сообщить об ошибке

Создайте [Issue](https://github.com/qualitydll/cirrus/issues) и укажите платформу, версию, шаги воспроизведения и текст ошибки. Не прикладывайте секретные ссылки или учётные данные.

## Лицензия и сторонние компоненты

Информация о лицензии и сторонних компонентах находится в файлах [LICENSE](LICENSE) и [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

<div align="center">

**Cirrus — меньше шума. больше связи.**

</div>
