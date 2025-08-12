#!/bin/bash

# Скрипт для исправления ошибки VLESS Vision
# Fix for: "vision: not a valid supported TLS connection"

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Проверка root прав
if [[ $EUID -ne 0 ]]; then
    print_error "Запустите скрипт с правами root!"
    exit 1
fi

echo "🔧 Исправление ошибки VLESS Vision"
echo "=================================="
echo ""

# 1. Проверка текущего статуса
print_step "Проверка текущего статуса X-ray..."
if systemctl is-active --quiet xray; then
    print_status "X-ray сервис запущен"
else
    print_warning "X-ray сервис не запущен"
fi

# 2. Создание резервной копии
print_step "Создание резервной копии конфигурации..."
cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.backup.$(date +%Y%m%d_%H%M%S)
print_status "Резервная копия создана"

# 3. Получение текущих параметров из конфигурации
print_step "Извлечение параметров из текущей конфигурации..."
USER_UUID=$(grep -o '"id": "[^"]*"' /usr/local/etc/xray/config.json | head -1 | cut -d'"' -f4)
PRIVATE_KEY=$(grep -o '"privateKey": "[^"]*"' /usr/local/etc/xray/config.json | cut -d'"' -f4)
DEST_SITE=$(grep -o '"dest": "[^"]*"' /usr/local/etc/xray/config.json | cut -d'"' -f4 | cut -d':' -f1)

print_status "UUID: $USER_UUID"
print_status "Сайт маскировки: $DEST_SITE"

# 4. Улучшенная конфигурация
print_step "Создание улучшенной конфигурации..."
cat > /usr/local/etc/xray/config.json << EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$USER_UUID",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none",
                "fallbacks": [
                    {
                        "dest": "80"
                    }
                ]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$DEST_SITE:443",
                    "xver": 0,
                    "serverNames": [
                        "$DEST_SITE"
                    ],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": [
                        ""
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls"
                ],
                "metadataOnly": false
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "blocked"
        }
    ],
    "routing": {
        "rules": [
            {
                "type": "field",
                "ip": [
                    "geoip:private"
                ],
                "outboundTag": "blocked"
            }
        ]
    }
}
EOF

# 5. Проверка конфигурации
print_step "Проверка новой конфигурации..."
if xray -test -config /usr/local/etc/xray/config.json; then
    print_status "Конфигурация корректна"
else
    print_error "Ошибка в конфигурации! Восстанавливаем резервную копию..."
    cp /usr/local/etc/xray/config.json.backup.* /usr/local/etc/xray/config.json
    exit 1
fi

# 6. Перезапуск сервиса
print_step "Перезапуск X-ray сервиса..."
systemctl restart xray
sleep 3

if systemctl is-active --quiet xray; then
    print_status "X-ray успешно перезапущен"
else
    print_error "Ошибка перезапуска X-ray! Проверьте логи: journalctl -u xray -n 50"
    exit 1
fi

# 7. Проверка логов на ошибки
print_step "Проверка логов на ошибки Vision..."
if journalctl -u xray --since "1 minute ago" | grep -q "vision.*not a valid"; then
    print_warning "Ошибки Vision все еще присутствуют в логах"
    echo ""
    echo "Попробуйте следующие решения:"
    echo "1. Смените сайт маскировки: nano /usr/local/etc/xray/config.json"
    echo "2. Обновите клиентские приложения до последней версии"
    echo "3. Проверьте, что клиент поддерживает XTLS-Vision"
else
    print_status "Ошибки Vision больше не обнаружены"
fi

# 8. Дополнительные рекомендации
echo ""
echo "🔧 Дополнительные рекомендации:"
echo "================================"
echo ""
echo "1. 📱 Обновите клиентские приложения:"
echo "   • Hiddify: проверьте обновления в магазине приложений"
echo "   • v2rayNG: обновите до версии 1.8.0+"
echo "   • NekoBox: используйте последнюю версию"
echo ""
echo "2. 🔄 Если ошибки продолжаются:"
echo "   • Смените сайт маскировки в конфигурации"
echo "   • Используйте другой flow (например, без xtls-rprx-vision)"
echo "   • Проверьте совместимость клиента с Reality"
echo ""
echo "3. 📊 Мониторинг:"
echo "   • journalctl -u xray -f  # Просмотр логов в реальном времени"
echo "   • systemctl status xray  # Статус сервиса"
echo ""

print_status "Исправление завершено! Попробуйте переподключиться к VPN."
