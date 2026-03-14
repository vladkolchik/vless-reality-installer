# 🔒 VLESS+Reality VPN Auto-Install

Автоматическая установка и настройка VLESS+Reality VPN сервера одной командой + опциональный Telegram-бот для удобного управления.

## 🚀 Быстрая установка

### Одной командой (рекомендуется):

```bash
bash <(curl -s https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_reality.sh)
```

### Или скачайте и проверьте код:

```bash
wget https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_reality.sh
nano install_vless_reality.sh  # Просмотр кода
chmod +x install_vless_reality.sh
./install_vless_reality.sh
```

## 📋 Что делает скрипт

- 🔄 **Автоматически обновляет систему**
- 📦 **Устанавливает X-ray сервер** с GitHub
- 🔑 **Генерирует все ключи** (UUID, X25519, shortIDs)
- ⚙️ **Создает конфигурацию XHTTP + Reality** с меньшим числом TLS-хендшейков
- 🛡️ **Настраивает firewall** (UFW/Firewalld)
- 📱 **Генерирует QR коды** для всех клиентов
- ✅ **Проверяет работоспособность** сервиса
- 🔧 **Устанавливает CLI `vless`** для управления клиентами
- 👥 **Создаёт sudo-пользователя** для безопасности

## 🖥️ Поддерживаемые системы

- ✅ **Ubuntu** 18.04+ / Debian 9+
- ✅ **CentOS** 7+ / RHEL 7+
- ✅ **Fedora** 30+

## ⏱️ Время установки

**5-10 минут** - полная автоматическая настройка без участия пользователя.

## 📱 Результат установки

После завершения вы получите:

```
📂 /root/vless-configs/
├── 📄 README.txt          # Подробная информация
├── 🖼️ config_1.png        # QR код #1
├── 📝 config_1.txt        # URL конфигурации #1  
├── 🖼️ config_2.png        # QR код #2
├── 📝 config_2.txt        # URL конфигурации #2
├── 🖼️ config_3.png        # QR код #3
└── 📝 config_3.txt        # URL конфигурации #3
```

## 📲 Клиентские приложения

### Android
- [Hiddify](https://github.com/hiddify/hiddify-next) (рекомендуется)
- [v2rayNG](https://github.com/2dust/v2rayNG)
- [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid)

### iOS / macOS
- [Hiddify](https://apps.apple.com/app/hiddify/id6596777532) (рекомендуется)
- [FoXray](https://apps.apple.com/app/foxray/id6448898396)
- [Streisand](https://apps.apple.com/app/streisand/id6450128312)

### Windows
- [Hiddify](https://github.com/hiddify/hiddify-next) (рекомендуется)
- [NekoBox](https://github.com/MatsuriDayo/NekoBoxForPC)
- [InvisibleMan-XRay](https://github.com/InvisibleManVPN/InvisibleMan-XRayClient)

### Linux
- [Hiddify](https://github.com/hiddify/hiddify-next)
- [NekoBox](https://github.com/MatsuriDayo/NekoBoxForPC)

## 🔧 Ручная настройка

Если предпочитаете пошаговую ручную настройку, воспользуйтесь подробными руководствами:

- 📖 [**Полное руководство по установке и безопасности**](Instruction/server_security_guide.html)
- 🌍 [**Настройка исключений для RU сайтов**](Instruction/vpn_ru_geosite_exclusions.html)

## 🛡️ Безопасность

Скрипт автоматически:
- 🚫 Запрещает root вход по SSH
- 🔥 Настраивает firewall с минимальными правами
- 🔒 Генерирует криптографически стойкие ключи
- 🎭 Настраивает маскировку трафика под HTTPS
- 📊 Использует XHTTP с `xmux.maxConnections = 1`, чтобы не плодить нижележащие TLS-сессии

## ⚡ Быстрый старт

1. **Арендуйте VPS сервер** (любой провайдер)
2. **Подключитесь по SSH** под root
3. **Выполните команду установки:**
   ```bash
   bash <(curl -s https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_reality.sh)
   ```
4. **Скачайте QR код:**
   ```bash
   scp root@your-server-ip:/root/vless-configs/config_1.png .
   ```
5. **Импортируйте в VPN приложение** и подключайтесь!

## 🔍 Проверка работы

```bash
# Проверить статус сервиса
systemctl status xray

# Посмотреть логи
journalctl -u xray -f

# Проверить порт
ss -tulpn | grep :443

# Показать конфигурации
cat /root/vless-configs/README.txt

# CLI для управления (установлен автоматически)
vless list                    # список клиентов
vless doctor                  # диагностика
sudo vless add MyPhone        # добавить клиента
sudo vless restart            # перезапуск
sudo vless fix                # исправить права доступа
```

## 🤖 Telegram-бот (опционально)

Для удобного управления VPN прямо из Telegram:

```bash
# Установка бота (интерактивно)
bash <(curl -fsSL https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_bot.sh)

# Обновление бота
bash <(curl -fsSL https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_bot.sh) update
```

**Возможности бота:**
- 📱 Создание клиентов `/add` с автоматическими QR-кодами
- 📋 Список всех клиентов `/list` с копируемыми ссылками  
- 🔍 Просмотр конфигурации `/show` конкретного клиента
- ❌ Удаление клиентов `/del` с подтверждением
- 🔄 Перезапуск сервиса `/restart`
- 🔧 Исправление проблем `/fix` (права доступа)
- 🩺 Диагностика сервера `/doctor`

**Безопасность:** Доступ только для админов (Telegram ID), остальные игнорируются.

## 🌍 Что такое VLESS+Reality?

- **VLESS** - современный протокол с минимальными накладными расходами
- **Reality** - технология маскировки трафика под реальные HTTPS сайты
- **XHTTP** - транспорт, который помогает переживать блокировки по всплескам TLS-хендшейков
- **Высокая скорость** - оптимизация для максимальной производительности
- **Устойчивость к блокировкам** - сложно обнаружить и заблокировать

## 📞 Поддержка

Если возникли проблемы:

1. Проверьте логи: `journalctl -u xray`
2. Убедитесь что порт 443 открыт: `ufw status` или `firewall-cmd --list-all`
3. Проверьте конфигурацию: `cat /usr/local/etc/xray/config.json`

## 📄 Лицензия

MIT License - используйте свободно для личных и коммерческих целей.

---

⭐ **Поставьте звезду**, если проект оказался полезным!

🔒 **Безопасность превыше всего** - регулярно обновляйте сервер и меняйте конфигурации.

