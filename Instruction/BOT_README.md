# VLESS Telegram Bot – Admin‑only control

Бот управляет VLESS/Xray через CLI `vless`. Доступ строго для админов (по `TELEGRAM_ADMINS`).

## Быстрый старт (онлайн, одной командой)

По умолчанию тянет файлы из репозитория `vladkolchik/vless-reality-installer`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/main/install_vless_bot.sh)
```

Без вопросов (после — отредактируйте `/etc/vless-bot.env` и перезапустите):
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/main/install_vless_bot.sh) --non-interactive
sudo nano /etc/vless-bot.env
sudo systemctl restart vless-bot
```

Проверка:
```bash
systemctl is-enabled vless-bot
systemctl status vless-bot | cat
vless list
```

## Локальная установка из репозитория

Структура (важно наличие этих файлов):
- `bot/telegram_bot.py`
- `bot/requirements.txt`
- `bot/scripts/setup_vless_bot.sh`
- `bot/scripts/vless`

Установка:
```bash
cd /path/to/repo
sudo bash bot/scripts/setup_vless_bot.sh
```

## Переменные окружения (`/etc/vless-bot.env`)

- `TELEGRAM_BOT_TOKEN` — токен бота (из @BotFather)
- `TELEGRAM_ADMINS` — список Telegram user id (числа), через запятую/пробел
- `VLESS_BIN` — путь до CLI `vless` (по умолчанию `/usr/local/bin/vless`)
- `VLESS_OUTPUT_DIR` — куда сохранять QR/URL (по умолчанию `/root/vless-configs`)

Безопасность: не храните секреты в репозитории; используйте `/etc/vless-bot.env` (600, root:root).

## Команды бота (только админы)

- `/add name` — создать клиента
- `/list` — вывести список
- `/show name_or_uuid` — показать URL и отправить QR
- `/del name_or_uuid` — удалить клиента
- `/restart` — перезапуск Xray
- `/doctor` — короткая диагностика

## CLI `vless`

- `sudo vless add <name>`
- `vless list`
- `vless show <name|uuid>`
- `sudo vless del <name|uuid>`
- `sudo vless restart`
- `vless doctor`

## Systemd управление

```bash
sudo systemctl enable --now vless-bot
sudo systemctl status vless-bot | cat
sudo journalctl -u vless-bot -f
sudo systemctl restart vless-bot
```

## Частые вопросы

- Бот молчит — проверьте, что ваш `user id` есть в `TELEGRAM_ADMINS` и сервис запущен.
- Нет QR — установите `qrencode` и проверьте `VLESS_OUTPUT_DIR`.
- CLI не находится — задайте `VLESS_BIN` в `/etc/vless-bot.env` и перезапустите сервис.

---
Репозиторий: `https://github.com/vladkolchik/vless-reality-installer`
Папка бота: `https://github.com/vladkolchik/vless-reality-installer/tree/main/bot`


