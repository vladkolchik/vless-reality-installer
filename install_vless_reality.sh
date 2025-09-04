#!/bin/bash

# VLESS+Reality VPN Automatic Installation Script
# Автоматическая установка и настройка VLESS+Reality VPN сервера
# Основано на проверенной методике из статьи: https://habr.com/ru/articles/869340/
# 
# Версия: 1.2 (исправлены проблемы совместимости с X-ray 25.8.31+)
# Изменения:
# - Исправлена синтаксическая ошибка JSON в конфигурации
# - Исправлена проблема с генерацией privateKey для Reality
# - Генерация ключей перенесена после установки X-ray
# - Добавлена валидация конфигурации перед запуском
# - Исправлены предупреждения systemd
# - Улучшена диагностика ошибок и отладка ключей
# 
# Использование:
# bash <(curl -s https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_reality.sh)

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
        print_status "Попробуйте: sudo bash <(curl -s https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_reality.sh)"
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
        apt install -y curl wget unzip openssl qrencode python3
    else
        yum install -y curl wget unzip openssl qrencode python3
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

# Функция генерации основных параметров
generate_basic_config() {
    print_step "Генерация базовых параметров конфигурации..."
    
    # Генерация UUID
    USER_UUID=$(generate_uuid)
    print_status "UUID: $USER_UUID"
    
    # Генерация коротких ID (как в статье Habr)
    SHORT_ID1=$(openssl rand -hex 6)
    SHORT_ID2=$(openssl rand -hex 6)
    SHORT_ID3=$(openssl rand -hex 6)
    
    print_status "Short IDs: $SHORT_ID1, $SHORT_ID2, $SHORT_ID3"
    
    # Получение внешнего IP
    SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || curl -s icanhazip.com)
    print_status "IP сервера: $SERVER_IP"
    
    # Выбор сайта для маскировки (apple.com по умолчанию как проверенный)
    DEST_SITES=("apple.com" "microsoft.com" "cloudflare.com" "discord.com")
    DEST_SITE="apple.com"  # По умолчанию используем apple.com
    print_status "Сайт для маскировки: $DEST_SITE"
}

# Функция генерации X25519 ключей (после установки X-ray)
generate_reality_keys() {
    print_step "Генерация X25519 ключей для Reality..."
    
    # Проверяем, что X-ray установлен
    if [[ ! -f /usr/local/bin/xray ]]; then
        print_error "X-ray не установлен! Генерация ключей невозможна."
        exit 1
    fi
    
    # Генерация X25519 ключей с улучшенной обработкой
    print_status "Выполняем команду: /usr/local/bin/xray x25519"
    KEY_PAIR_OUTPUT=$(/usr/local/bin/xray x25519 2>&1)
    
    if [[ $? -ne 0 ]]; then
        print_error "Ошибка генерации ключей X25519:"
        print_error "$KEY_PAIR_OUTPUT"
        exit 1
    fi
    
    print_status "Вывод команды xray x25519:"
    echo "$KEY_PAIR_OUTPUT"
    
    # Парсинг ключей с более гибким подходом
    PRIVATE_KEY=$(echo "$KEY_PAIR_OUTPUT" | grep -i "private" | sed -E 's/.*[Kk]ey:?\s*([A-Za-z0-9+/=_-]+).*/\1/' | head -1)
    PUBLIC_KEY=$(echo "$KEY_PAIR_OUTPUT" | grep -i "public" | sed -E 's/.*[Kk]ey:?\s*([A-Za-z0-9+/=_-]+).*/\1/' | head -1)
    
    # Проверка корректности ключей
    if [[ -z "$PRIVATE_KEY" || ${#PRIVATE_KEY} -lt 32 ]]; then
        print_error "Не удалось получить корректный приватный ключ!"
        print_error "Полученный приватный ключ: '$PRIVATE_KEY'"
        print_error "Попробуем альтернативный метод парсинга..."
        
        # Альтернативный метод парсинга
        PRIVATE_KEY=$(echo "$KEY_PAIR_OUTPUT" | grep -oE '[A-Za-z0-9+/=_-]{32,}' | head -1)
        PUBLIC_KEY=$(echo "$KEY_PAIR_OUTPUT" | grep -oE '[A-Za-z0-9+/=_-]{32,}' | tail -1)
    fi
    
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        print_error "Не удалось сгенерировать ключи X25519 через xray!"
        print_error "Вывод команды xray x25519:"
        echo "$KEY_PAIR_OUTPUT"
        print_warning "Пробуем резервный метод генерации ключей..."
        
        # Резервный метод - попробуем запустить xray x25519 еще раз с задержкой
        print_status "Ждем 3 секунды и пробуем еще раз..."
        sleep 3
        
        KEY_PAIR_OUTPUT_RETRY=$(/usr/local/bin/xray x25519 2>&1)
        if [[ $? -eq 0 ]]; then
            PRIVATE_KEY=$(echo "$KEY_PAIR_OUTPUT_RETRY" | grep -i "private" | sed -E 's/.*[Kk]ey:?\s*([A-Za-z0-9+/=_-]+).*/\1/' | head -1)
            PUBLIC_KEY=$(echo "$KEY_PAIR_OUTPUT_RETRY" | grep -i "public" | sed -E 's/.*[Kk]ey:?\s*([A-Za-z0-9+/=_-]+).*/\1/' | head -1)
            
            if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]; then
                print_status "Ключи сгенерированы при повторной попытке"
            else
                print_error "Повторная попытка также не дала результата!"
                print_error "Проверьте корректность установки X-ray"
                print_error "Попробуйте запустить вручную: /usr/local/bin/xray x25519"
                exit 1
            fi
        else
            print_error "Повторная генерация ключей также провалилась!"
            print_error "Ошибка: $KEY_PAIR_OUTPUT_RETRY"
            exit 1
        fi
    fi
    
    print_status "Private key: $PRIVATE_KEY"
    print_status "Public key: $PUBLIC_KEY"
    
    # Дополнительная валидация длины ключей
    if [[ ${#PRIVATE_KEY} -lt 32 || ${#PUBLIC_KEY} -lt 32 ]]; then
        print_warning "Ключи кажутся слишком короткими. Проверьте корректность:"
        print_warning "Private key length: ${#PRIVATE_KEY}"
        print_warning "Public key length: ${#PUBLIC_KEY}"
    fi
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
        },
            {
                "port": 80,
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

# Функция исправления systemd сервиса X-ray
fix_xray_systemd_service() {
    print_step "Исправление systemd сервиса X-ray..."
    
    # Проверяем, существует ли файл сервиса
    if [[ -f /etc/systemd/system/xray.service ]]; then
        # Создаем резервную копию
        cp /etc/systemd/system/xray.service /etc/systemd/system/xray.service.backup
        
        # Заменяем User=nobody на DynamicUser=true для безопасности
        if grep -q "User=nobody" /etc/systemd/system/xray.service; then
            sed -i 's/User=nobody/DynamicUser=true/' /etc/systemd/system/xray.service
            print_status "Исправлена настройка пользователя в systemd сервисе"
            
            # Перезагружаем конфигурацию systemd
            systemctl daemon-reload
        else
            print_status "Systemd сервис уже настроен корректно"
        fi
    else
        print_warning "Файл systemd сервиса не найден, возможно будет создан автоматически"
    fi
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

# Функция установки и запуска fail2ban
install_fail2ban() {
	print_step "Установка и запуск fail2ban..."
	if [[ $OS == "debian" ]]; then
		apt install -y fail2ban
		systemctl start fail2ban
		systemctl enable fail2ban
		print_status "fail2ban установлен и запущен"
	else
		# Установка для CentOS/RHEL (через EPEL)
		if ! rpm -q epel-release >/dev/null 2>&1; then
			yum install -y epel-release
		fi
		yum install -y fail2ban || {
			print_warning "Не удалось установить fail2ban через yum"
			return
		}
		systemctl start fail2ban || print_warning "Не удалось запустить fail2ban"
		systemctl enable fail2ban || true
		print_status "fail2ban установлен (если доступен) и запущен"
	fi
}

# Функция установки sudo и инструмента для выдачи прав
install_sudo_and_privilege_tools() {
	print_step "Установка sudo и настройка прав суперпользователя..."

	# Установка sudo
	if [[ $OS == "debian" ]]; then
		apt install -y sudo
	else
		yum install -y sudo
	fi

	# Обеспечить корректную конфигурацию sudoers для групп sudo и wheel
	cat > /etc/sudoers.d/99-sudo-wheel << 'EOF'
%sudo ALL=(ALL) ALL
%wheel ALL=(ALL) ALL
EOF
	chmod 440 /etc/sudoers.d/99-sudo-wheel
	chown root:root /etc/sudoers.d/99-sudo-wheel

	# Утилита grant-sudo: добавление пользователя в группу sudo/wheel
	cat > /usr/local/bin/grant-sudo << 'EOF'
#!/bin/bash
set -e
if [[ $EUID -ne 0 ]]; then
  echo "This tool must be run as root" >&2
  exit 1
fi

if [[ -z "$1" ]]; then
  echo "Usage: grant-sudo <username>" >&2
  exit 1
fi

USERNAME="$1"

if ! id -u "$USERNAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$USERNAME"
  echo "User '$USERNAME' created. Set a password with: passwd $USERNAME"
fi

if [[ -f /etc/debian_version ]]; then
  GROUP_NAME="sudo"
else
  GROUP_NAME="wheel"
fi

usermod -aG "$GROUP_NAME" "$USERNAME"
echo "User '$USERNAME' added to group '$GROUP_NAME' (sudo privileges)."
EOF

	chmod 755 /usr/local/bin/grant-sudo
	chown root:root /usr/local/bin/grant-sudo

	print_status "sudo установлен. Доступна команда 'grant-sudo' для выдачи прав."

	# Предложить сразу выдать права новому пользователю
	read -p "Создать пользователя с sudo-привилегиями сейчас? (y/N): " -n 1 -r
	echo ""
	if [[ $REPLY =~ ^[Yy]$ ]]; then
		read -p "Введите имя нового пользователя: " NEW_USERNAME
		if [[ -n "$NEW_USERNAME" ]]; then
			/usr/local/bin/grant-sudo "$NEW_USERNAME"
			print_status "Пользователь '$NEW_USERNAME' добавлен с sudo-привилегиями."
			read -p "Задать пароль для '$NEW_USERNAME' сейчас? (y/N): " -n 1 -r
			echo ""
			if [[ $REPLY =~ ^[Yy]$ ]]; then
				passwd "$NEW_USERNAME"
			else
				print_warning "Пароль не задан. Вы можете сделать это позже: passwd $NEW_USERNAME"
			fi
		else
			print_warning "Имя пользователя не задано, пропускаем создание."
		fi
	fi
}

# Функция валидации конфигурации X-ray
validate_xray_config() {
    print_step "Валидация конфигурации X-ray..."
    
    # Проверяем существование файла конфигурации
    if [[ ! -f /usr/local/etc/xray/config.json ]]; then
        print_error "Файл конфигурации /usr/local/etc/xray/config.json не найден!"
        exit 1
    fi
    
    # Проверяем права доступа
    if [[ ! -r /usr/local/etc/xray/config.json ]]; then
        print_error "Нет прав на чтение файла конфигурации!"
        print_status "Попытка исправить права доступа..."
        chmod 644 /usr/local/etc/xray/config.json
        chown root:root /usr/local/etc/xray/config.json
    fi
    
    # Валидация JSON синтаксиса
    if ! python3 -m json.tool /usr/local/etc/xray/config.json > /dev/null 2>&1; then
        if ! python -m json.tool /usr/local/etc/xray/config.json > /dev/null 2>&1; then
            print_error "Ошибка JSON синтаксиса в конфигурации X-ray!"
            print_error "Проверьте файл /usr/local/etc/xray/config.json на наличие:"
            print_error "- Лишних или недостающих запятых"
            print_error "- Незакрытых скобок или кавычек"
            print_error "- Неверных символов"
            exit 1
        fi
    fi
    
    # Дополнительная проверка ключей Reality в конфигурации
    if grep -q "privateKey.*empty\|privateKey.*null\|privateKey.*\"\"" /usr/local/etc/xray/config.json; then
        print_error "Обнаружен пустой privateKey в конфигурации!"
        print_error "Проверьте генерацию ключей X25519"
        exit 1
    fi
    
    # Валидация конфигурации X-ray
    print_status "Тестирование конфигурации X-ray..."
    CONFIG_TEST_OUTPUT=$(/usr/local/bin/xray -test -c /usr/local/etc/xray/config.json 2>&1)
    CONFIG_TEST_RESULT=$?
    
    if [[ $CONFIG_TEST_RESULT -eq 0 ]]; then
        print_status "Конфигурация X-ray валидна"
    else
        print_error "Ошибка в конфигурации X-ray!"
        print_error "Вывод теста конфигурации:"
        echo "$CONFIG_TEST_OUTPUT"
        print_error ""
        print_error "Возможные проблемы:"
        print_error "- Неверные параметры протокола"
        print_error "- Некорректные настройки Reality"
        print_error "- Проблемы с ключами шифрования (privateKey/publicKey)"
        print_error "- Неверный формат shortIds"
        print_error ""
        print_error "Проверьте файл: /usr/local/etc/xray/config.json"
        print_error "Особое внимание обратите на секцию realitySettings"
        exit 1
    fi
}

# Функция запуска и проверки X-ray
start_xray() {
    print_step "Запуск X-ray сервиса..."
    
    # Сначала валидируем конфигурацию
    validate_xray_config
    
    systemctl enable xray
    systemctl restart xray
    sleep 3
    
    if systemctl is-active --quiet xray; then
        print_status "X-ray успешно запущен и работает"
    else
        print_error "Ошибка запуска X-ray! Создаем диагностический отчет..."
        
        # Создание диагностического отчета
        DIAG_FILE="/root/xray-diagnostic-$(date +%Y%m%d_%H%M%S).log"
        {
            echo "=== X-ray Diagnostic Report ==="
            echo "Date: $(date)"
            echo "X-ray Version: $(/usr/local/bin/xray version 2>/dev/null || echo 'Not available')"
            echo ""
            
            echo "=== System Info ==="
            echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
            echo "Kernel: $(uname -r)"
            echo ""
            
            echo "=== X-ray Service Status ==="
            systemctl status xray --no-pager || true
            echo ""
            
            echo "=== X-ray Logs (last 20 lines) ==="
            journalctl -u xray -n 20 --no-pager || true
            echo ""
            
            echo "=== Configuration Test ==="
            /usr/local/bin/xray -test -c /usr/local/etc/xray/config.json || true
            echo ""
            
            echo "=== Reality Keys Check ==="
            echo "Private Key in config: $(grep -o '"privateKey": "[^"]*"' /usr/local/etc/xray/config.json || echo 'Not found')"
            echo "Private Key length: $(grep -o '"privateKey": "[^"]*"' /usr/local/etc/xray/config.json | grep -o '"[^"]*"$' | wc -c)"
            echo ""
            
            echo "=== Configuration File Content ==="
            cat /usr/local/etc/xray/config.json || echo "Config file not readable"
            echo ""
            
            echo "=== File Permissions ==="
            ls -la /usr/local/etc/xray/ || true
            ls -la /usr/local/bin/xray || true
            echo ""
            
            echo "=== Network Ports ==="
            ss -tulpn | grep -E ":(443|80)" || echo "Ports 80/443 not listening"
            echo ""
            
            echo "=== Firewall Status ==="
            if command -v ufw >/dev/null 2>&1; then
                ufw status || true
            elif command -v firewall-cmd >/dev/null 2>&1; then
                firewall-cmd --list-all || true
            fi
            
        } > "$DIAG_FILE"
        
        print_error "Диагностический отчет создан: $DIAG_FILE"
        print_error "Отправьте этот файл для анализа проблемы."
        print_error ""
        print_error "Быстрая диагностика:"
        print_error "1. Проверьте логи: journalctl -u xray -f"
        print_error "2. Тест конфигурации: /usr/local/bin/xray -test -c /usr/local/etc/xray/config.json"
        print_error "3. Проверьте права: ls -la /usr/local/etc/xray/"
        print_error "4. Посмотрите отчет: cat $DIAG_FILE"
        
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
        CONFIG_NAME_443="config_${i}_443"
        CONFIG_NAME_80="config_${i}_80"
        
        VLESS_URL_443="vless://$USER_UUID@$SERVER_IP:443?type=tcp&security=reality&pbk=$PUBLIC_KEY&fp=chrome&sni=$DEST_SITE&sid=$SHORT_ID_VALUE&flow=xtls-rprx-vision#$CONFIG_NAME_443"
        VLESS_URL_80="vless://$USER_UUID@$SERVER_IP:80?type=tcp&security=reality&pbk=$PUBLIC_KEY&fp=safari&sni=$DEST_SITE&sid=$SHORT_ID_VALUE&flow=xtls-rprx-vision#$CONFIG_NAME_80"
        
        # Сохранение URL в файл
        echo "$VLESS_URL_443" > "/root/vless-configs/$CONFIG_NAME_443.txt"
        echo "$VLESS_URL_80" > "/root/vless-configs/$CONFIG_NAME_80.txt"
        
        # Генерация QR кода
        qrencode -o "/root/vless-configs/$CONFIG_NAME_443.png" "$VLESS_URL_443"
        qrencode -o "/root/vless-configs/$CONFIG_NAME_80.png" "$VLESS_URL_80"
        
        print_status "Конфигурации $CONFIG_NAME_443 и $CONFIG_NAME_80 созданы"
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
    1. config_1_443 / config_1_80 (ShortID: $SHORT_ID1)
    2. config_2_443 / config_2_80 (ShortID: $SHORT_ID2)  
    3. config_3_443 / config_3_80 (ShortID: $SHORT_ID3)

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

# Функция вывода QR-кодов в консоль
print_qr_codes_console() {
	if ! command -v qrencode >/dev/null 2>&1; then
		print_warning "qrencode не установлен, пропускаем вывод QR-кодов в консоль"
		return
	fi

	echo -e "${BLUE}🖨️  QR коды для конфигураций:${NC}"
    for i in {1..3}; do
        for port_tag in 443 80; do
            CONFIG_PATH="/root/vless-configs/config_${i}_${port_tag}.txt"
            if [[ -f "$CONFIG_PATH" ]]; then
                URL_VALUE=$(cat "$CONFIG_PATH")
				echo -e "${PURPLE}config_${i}_${port_tag}:${NC}"
				# Строка конфигурации для копирования (печатаем до QR, чтобы избежать визуальных разрывов)
				printf '%s\n' "$URL_VALUE"
				# Сброс форматирования терминала перед выводом QR
				tput sgr0 2>/dev/null || true
				qrencode -t ANSIUTF8 -m 1 "$URL_VALUE"
                echo ""
            fi
        done
    done
}

# Функция удаления всех изменений, внесенных скриптом
uninstall_all() {
	print_step "Удаление установленных компонент и настроек..."

	# Опциональные флаги: --yes (без вопросов), --reset-firewall
	AUTO_YES=false
	RESET_FIREWALL=false
	for arg in "$@"; do
		case "$arg" in
			--yes)
				AUTO_YES=true
				;;
			--reset-firewall)
				RESET_FIREWALL=true
				;;
		esac
	done

	if [[ "$AUTO_YES" != true ]]; then
		print_warning "Будут удалены: Xray, его конфигурации и QR, fail2ban, скрипт grant-sudo и sudoers drop-in."
		read -p "Продолжить удаление? (y/N): " -n 1 -r
		echo ""
		if [[ ! $REPLY =~ ^[Yy]$ ]]; then
			print_status "Удаление отменено пользователем."
			return
		fi
	fi

	# Остановка сервисов
	if systemctl list-unit-files | grep -q '^xray\.service'; then
		systemctl stop xray || true
		systemctl disable xray || true
	fi
	if systemctl list-unit-files | grep -q '^fail2ban\.service'; then
		systemctl stop fail2ban || true
		systemctl disable fail2ban || true
	fi

	# Удаление Xray через официальный инсталлер (если доступен)
	if command -v bash >/dev/null 2>&1; then
		bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove || true
	fi

	# Ручная очистка Xray (на случай, если remove не сработал)
	rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service 2>/dev/null || true
	rm -rf /usr/local/etc/xray 2>/dev/null || true
	rm -f /usr/local/bin/xray 2>/dev/null || true
	systemctl daemon-reload || true

	# Удаление конфигов и QR, созданных скриптом
	rm -rf /root/vless-configs 2>/dev/null || true

	# Удаление fail2ban пакета
	if [[ -f /etc/debian_version ]]; then
		apt purge -y fail2ban >/dev/null 2>&1 || apt remove -y fail2ban >/dev/null 2>&1 || true
		apt autoremove -y >/dev/null 2>&1 || true
	else
		yum remove -y fail2ban >/dev/null 2>&1 || true
	fi

	# Удаление артефактов sudo-настройки, внесенных скриптом
	rm -f /etc/sudoers.d/99-sudo-wheel 2>/dev/null || true
	rm -f /usr/local/bin/grant-sudo 2>/dev/null || true

	# Откат настроек firewall по запросу
	if [[ "$RESET_FIREWALL" == true ]]; then
		if [[ -f /etc/debian_version ]]; then
			if command -v ufw >/dev/null 2>&1; then
				ufw --force reset || true
				ufw disable || true
			fi
		else
			if command -v firewall-cmd >/dev/null 2>&1; then
				# ВНИМАНИЕ: удаление ssh/http/https может лишить доступа. Делаем только если явный флаг --reset-firewall
				firewall-cmd --permanent --remove-service=ssh || true
				firewall-cmd --permanent --remove-service=http || true
				firewall-cmd --permanent --remove-service=https || true
				firewall-cmd --reload || true
			fi
		fi
	fi

	print_status "Удаление завершено. Возможно, потребуется перезапуск сервера."
}

# Установка локальной CLI-команды для удаления
install_uninstall_cli() {
	print_step "Установка локальной команды для удаления (vless-uninstall)..."
	cat > /usr/local/bin/vless-uninstall << 'EOF'
#!/bin/bash
set -e

AUTO_YES=false
RESET_FIREWALL=false
for arg in "$@"; do
  case "$arg" in
    --yes) AUTO_YES=true ;;
    --reset-firewall) RESET_FIREWALL=true ;;
  esac
done

if [[ "$AUTO_YES" != true ]]; then
  echo "This will remove Xray, configs (/root/vless-configs), fail2ban, sudo helper and optional firewall rules."
  read -p "Continue? (y/N): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Stop services
if systemctl list-unit-files | grep -q '^xray\.service'; then
  systemctl stop xray || true
  systemctl disable xray || true
fi
if systemctl list-unit-files | grep -q '^fail2ban\.service'; then
  systemctl stop fail2ban || true
  systemctl disable fail2ban || true
fi

# Try official remover
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove || true

# Manual cleanup
rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service 2>/dev/null || true
rm -rf /usr/local/etc/xray 2>/dev/null || true
rm -f /usr/local/bin/xray 2>/dev/null || true
systemctl daemon-reload || true

rm -rf /root/vless-configs 2>/dev/null || true

# Remove fail2ban
if [[ -f /etc/debian_version ]]; then
  apt purge -y fail2ban >/dev/null 2>&1 || apt remove -y fail2ban >/dev/null 2>&1 || true
  apt autoremove -y >/dev/null 2>&1 || true
else
  yum remove -y fail2ban >/dev/null 2>&1 || true
fi

# Remove sudo artifacts
rm -f /etc/sudoers.d/99-sudo-wheel 2>/dev/null || true
rm -f /usr/local/bin/grant-sudo 2>/dev/null || true

# Optional firewall reset
if [[ "$RESET_FIREWALL" == true ]]; then
  if [[ -f /etc/debian_version ]]; then
    if command -v ufw >/dev/null 2>&1; then
      ufw --force reset || true
      ufw disable || true
    fi
  else
    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-service=ssh || true
      firewall-cmd --permanent --remove-service=http || true
      firewall-cmd --permanent --remove-service=https || true
      firewall-cmd --reload || true
    fi
  fi
fi

echo "Done. You may want to reboot the server."
EOF

	chmod 755 /usr/local/bin/vless-uninstall
	chown root:root /usr/local/bin/vless-uninstall
	print_status "Команда 'vless-uninstall' установлена."
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
    echo "   🖼️  config_*_(443|80).png - QR коды"
    echo "   📝 config_*_(443|80).txt - URL конфигурации"
    echo ""
    
    echo -e "${BLUE}🚀 Клиентские приложения:${NC}"
    echo "   📱 Android: Hiddify, v2rayNG, NekoBox"
    echo "   🍎 iOS: Hiddify, FoXray, Streisand" 
    echo "   💻 Windows: Hiddify, NekoBox, InvisibleMan-XRay"
    echo "   🐧 Linux: Hiddify, NekoBox"
    echo ""
    
    echo -e "${YELLOW}⚡ Быстрый старт:${NC}"
    echo "   1. Скачайте QR код: scp root@$SERVER_IP:/root/vless-configs/config_1_443.png . (или config_1_80.png)"
    echo "   2. Отсканируйте QR код в VPN приложении"
    echo "   3. Подключитесь и проверьте IP: https://ifconfig.me"
    echo ""
    
    echo -e "${GREEN}✅ Ваш VLESS+Reality VPN сервер готов к работе!${NC}"
    echo ""

	# Подсказка по удалению
	echo -e "${BLUE}🧹 Удаление:${NC}"
	echo "   Команда: vless-uninstall --yes  (добавьте --reset-firewall при необходимости)"
	echo ""
    
	# Печать QR-кодов в консоль
	print_qr_codes_console
    
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
    
    # Обработка аргумента удаления
    if [[ "$1" == "--uninstall" || "$1" == "uninstall" ]]; then
        uninstall_all "$@"
        return
    fi

    print_step "Начинаем установку VLESS+Reality VPN..."
    
    # Выполнение всех этапов
    check_root
    detect_os
    install_packages
    install_xray
    generate_basic_config
    generate_reality_keys
    create_xray_config
    fix_xray_systemd_service
    setup_firewall
	install_fail2ban
	install_sudo_and_privilege_tools
	install_uninstall_cli
    start_xray
    generate_client_configs
    
    # Вывод результатов
    show_results
}

# Обработка ошибок
trap 'print_error "Произошла ошибка на строке $LINENO. Установка прервана."; exit 1' ERR

# Запуск скрипта
main "$@"
