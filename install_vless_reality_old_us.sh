#!/bin/bash

# VLESS+Reality VPN Automatic Installation Script
# Автоматическая установка и настройка VLESS+Reality VPN сервера
# Основано на проверенной методике из статьи: https://habr.com/ru/articles/869340/
# 
# Использование:
# bash <(curl -s https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_reality_old_us.sh)

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Функция для вывода цветного текста
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

# Функция для генерации случайных строк
generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

generate_short_id() {
    openssl rand -hex 6
}

# Функция для проверки root прав
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Этот скрипт должен запускаться с правами root!"
        print_status "Попробуйте: sudo bash <(curl -s https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_reality_old_us.sh)"
        exit 1
    fi
}

# Функция определения операционной системы
detect_os() {
    if [[ -f /etc/debian_version ]]; then
        OS="debian"
        PACKAGE_MANAGER="apt"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
        PACKAGE_MANAGER="yum"
    else
        print_error "Неподдерживаемая операционная система!"
        exit 1
    fi
    print_status "Обнаружена ОС: $OS"
}

# Функция установки необходимых пакетов
install_packages() {
    print_step "Установка необходимых пакетов..."
    if [[ $OS == "debian" ]]; then
        apt update -y
        apt install -y sudo passwd curl wget unzip openssl qrencode
    else
        yum install -y sudo passwd curl wget unzip openssl qrencode
    fi
}

# Функция установки X-ray
install_xray() {
    print_step "Установка X-ray сервера..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    # Проверка установки
    if systemctl is-active --quiet xray; then
        print_status "X-ray успешно установлен и запущен"
    else
        print_warning "X-ray установлен, но не запущен. Будет настроен позже."
    fi
}

# Функция генерации ключей и конфигурации
generate_config() {
    print_step "Генерация ключей и конфигурации..."
    
    # Генерация UUID
    USER_UUID=$(generate_uuid)
    print_status "UUID: $USER_UUID"
    
    # Генерация X25519 ключей
    KEY_PAIR=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "Private key:" | cut -d' ' -f3)
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "Public key:" | cut -d' ' -f3)
    
    print_status "Private key: $PRIVATE_KEY"
    print_status "Public key: $PUBLIC_KEY"
    
    # Генерация коротких ID (как в статье Habr)
    SHORT_ID1=$(openssl rand -hex 6)
    SHORT_ID2=$(openssl rand -hex 6)
    SHORT_ID3=$(openssl rand -hex 6)
    
    print_status "Short IDs: $SHORT_ID1, $SHORT_ID2, $SHORT_ID3"
    
    # Получение внешнего IP
    SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || curl -s icanhazip.com)
    print_status "IP сервера: $SERVER_IP"
    
    # Выбор сайта для маскировки (nu.nl по умолчанию как проверенный)
    DEST_SITES=("microsoft.com" "nu.nl" "cloudflare.com" "discord.com" "apple.com")
    DEST_SITE="microsoft.com"  # По умолчанию используем nu.nl
    print_status "Сайт для маскировки: $DEST_SITE"
}

# Функция создания конфигурации X-ray
create_xray_config() {
    print_step "Создание конфигурации X-ray..."
    
    # Резервная копия оригинальной конфигурации
    if [[ -f /usr/local/etc/xray/config.json ]]; then
        cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.backup
    fi
    
    # Создание новой конфигурации (точно по статье Habr)
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
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$DEST_SITE:443",
                    "serverNames": [
                        "$DEST_SITE",
                        "www.$DEST_SITE"
                    ],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": [   
                        "$SHORT_ID1",
                        "$SHORT_ID2",
                        "$SHORT_ID3"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}
EOF
    
    print_status "Конфигурация X-ray создана"
}



# Функция настройки firewall
setup_firewall() {
    print_step "Настройка firewall..."
    
    if [[ $OS == "debian" ]]; then
        # UFW для Debian/Ubuntu
        if ! command -v ufw >/dev/null 2>&1; then
            apt install -y ufw
        fi
        
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow ssh
        ufw allow 443/tcp
        ufw allow 80/tcp
        ufw --force enable
        
        print_status "UFW firewall настроен"
    else
        # Firewalld для CentOS/RHEL
        if ! systemctl is-active --quiet firewalld; then
            systemctl start firewalld
            systemctl enable firewalld
        fi
        
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --reload
        
        print_status "Firewalld настроен"
    fi
}

# Функция запуска и проверки X-ray
start_xray() {
    print_step "Запуск X-ray сервиса..."
    
    systemctl enable xray
    systemctl restart xray
    sleep 3
    
    if systemctl is-active --quiet xray; then
        print_status "X-ray успешно запущен и работает"
    else
        print_error "Ошибка запуска X-ray! Проверьте логи: journalctl -u xray"
        exit 1
    fi
    
    # Проверка порта
    if ss -tulpn | grep -q ":443"; then
        print_status "Порт 443 прослушивается"
    else
        print_warning "Порт 443 не прослушивается. Проверьте конфигурацию."
    fi
}

# Функция генерации клиентских конфигураций
generate_client_configs() {
    print_step "Генерация клиентских конфигураций..."
    
    # Создание директории для конфигураций
    mkdir -p /root/vless-configs
    
    # Генерация VLESS URL для каждого shortId
    for i in {1..3}; do
        SHORT_ID_VAR="SHORT_ID$i"
        SHORT_ID_VALUE=${!SHORT_ID_VAR}
        CONFIG_NAME="config_$i"
        
        VLESS_URL="vless://$USER_UUID@$SERVER_IP:443?type=tcp&security=reality&pbk=$PUBLIC_KEY&fp=chrome&sni=$DEST_SITE&sid=$SHORT_ID_VALUE&flow=xtls-rprx-vision#$CONFIG_NAME"
        
        # Сохранение URL в файл
        echo "$VLESS_URL" > "/root/vless-configs/$CONFIG_NAME.txt"
        
        # Генерация QR кода в файл
        qrencode -o "/root/vless-configs/$CONFIG_NAME.png" "$VLESS_URL"
        
        print_status "Конфигурация $CONFIG_NAME создана"
    done
    
    # Создание сводного файла
    cat > /root/vless-configs/README.txt << EOF
VLESS+Reality VPN Конфигурации
=============================

Сервер: $SERVER_IP:443
UUID: $USER_UUID
Public Key: $PUBLIC_KEY
Сайт маскировки: $DEST_SITE

Конфигурации:
1. config_1 (ShortID: $SHORT_ID1)
2. config_2 (ShortID: $SHORT_ID2)  
3. config_3 (ShortID: $SHORT_ID3)

Клиентские приложения:
- Android: Hiddify, v2rayNG, NekoBox
- iOS: Hiddify, FoXray, Streisand
- Windows: Hiddify, NekoBox, InvisibleMan-XRay
- Linux: Hiddify, NekoBox

Инструкции:
1. Скачайте QR код или скопируйте URL из соответствующего .txt файла
2. Импортируйте в ваше VPN приложение
3. Подключитесь и проверьте работу

Проверка работы:
- Откройте https://ifconfig.me - должен показать IP вашего сервера
- Проверьте доступ к заблокированным сайтам

Поддержка: проверьте логи X-ray командой 'journalctl -u xray'
EOF
}

# Функция отображения QR кодов в консоли
show_qr_codes() {
    print_step "Отображение QR кодов конфигураций..."
    echo ""
    
    for i in {1..3}; do
        CONFIG_NAME="config_$i"
        SHORT_ID_VAR="SHORT_ID$i"
        SHORT_ID_VALUE=${!SHORT_ID_VAR}
        
        VLESS_URL="vless://$USER_UUID@$SERVER_IP:443?type=tcp&security=reality&pbk=$PUBLIC_KEY&fp=chrome&sni=$DEST_SITE&sid=$SHORT_ID_VALUE&flow=xtls-rprx-vision#$CONFIG_NAME"
        
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}📱 QR код для конфигурации: ${YELLOW}$CONFIG_NAME${NC} ${GREEN}(ShortID: $SHORT_ID_VALUE)${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        
        # Генерация QR кода в консоль
        qrencode -t ANSIUTF8 "$VLESS_URL"
        
        echo ""
        echo -e "${PURPLE}📋 URL для ручного ввода:${NC}"
        echo "$VLESS_URL"
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        
        # Пауза между QR кодами для удобства просмотра
        if [[ $i -lt 3 ]]; then
            echo -e "${YELLOW}⏳ Нажмите Enter для показа следующего QR кода...${NC}"
            read -r
            echo ""
        fi
    done
}

# Функция вывода итоговой информации
show_results() {
    clear
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                    УСТАНОВКА ЗАВЕРШЕНА!                        ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${BLUE}📋 Информация о сервере:${NC}"
    echo "   🌐 IP: $SERVER_IP"
    echo "   🔐 Порт: 443"
    echo "   🎭 Маскировка: $DEST_SITE"
    echo ""
    
    echo -e "${BLUE}🔑 Данные для подключения:${NC}"
    echo "   UUID: $USER_UUID"
    echo "   Public Key: $PUBLIC_KEY"
    echo ""
    
    echo -e "${BLUE}📱 Конфигурации сохранены в:${NC}"
    echo "   📂 /root/vless-configs/"
    echo "   📄 README.txt - подробная информация"
    echo "   🖼️  config_*.png - QR коды"
    echo "   📝 config_*.txt - URL конфигурации"
    echo ""
    
    echo -e "${BLUE}🚀 Клиентские приложения:${NC}"
    echo "   📱 Android: Hiddify, v2rayNG, NekoBox"
    echo "   🍎 iOS: Hiddify, FoXray, Streisand" 
    echo "   💻 Windows: Hiddify, NekoBox, InvisibleMan-XRay"
    echo "   🐧 Linux: Hiddify, NekoBox"
    echo ""
    
    echo -e "${YELLOW}⚡ Быстрый старт:${NC}"
    echo "   1. Скачайте QR код: scp root@$SERVER_IP:/root/vless-configs/config_1.png ."
    echo "   2. Отсканируйте QR код в VPN приложении"
    echo "   3. Подключитесь и проверьте IP: https://ifconfig.me"
    echo ""
    
    echo -e "${GREEN}✅ Ваш VLESS+Reality VPN сервер готов к работе!${NC}"
    echo ""
    
    # Показать одну конфигурацию для быстрого копирования
    echo -e "${PURPLE}📋 Конфигурация для копирования:${NC}"
    echo "$(cat /root/vless-configs/config_1.txt)"
    echo ""
    
    echo -e "${YELLOW}⚠️  Сохраните эти данные в безопасном месте!${NC}"
}

# Главная функция
main() {
    clear
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║            VLESS+Reality VPN Автоматическая Установка          ║"
    echo "║                                                                ║"
    echo "║  Этот скрипт автоматически установит и настроит VPN сервер     ║"
    echo "║  с протоколом VLESS и технологией Reality для обхода блокировок║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    print_warning "Скрипт потребует около 5-10 минут для выполнения."
    print_warning "Убедитесь, что у вас есть root права и стабильное интернет-соединение."
    echo ""
    
    read -p "Продолжить установку? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Установка отменена пользователем."
        exit 0
    fi
    
    print_step "Начинаем установку VLESS+Reality VPN..."
    
    # Выполнение всех этапов
    check_root
    detect_os
    install_packages
    install_xray
    generate_config
    create_xray_config
    setup_firewall
    start_xray
    generate_client_configs
    
    # Вывод результатов
    show_results
    
    # Отображение QR кодов в консоли
    show_qr_codes
}

# Обработка ошибок
trap 'print_error "Произошла ошибка на строке $LINENO. Установка прервана."; exit 1' ERR

# Запуск скрипта
main "$@"
