#!/bin/bash

# --- НАСТРОЙКИ ---
DEFAULT_YAML_URL="https://raw.githubusercontent.com/FluentBusiness/aio-nextcloud-docker/refs/heads/master/docker-compose.yaml"
COMPOSE_FILE="docker-compose.yaml"
REPORT_FILE="install_report.txt"
PLACEHOLDER="YOUR_DOMAIN" 

YAML_URL="${1:-$DEFAULT_YAML_URL}"

set -e

# Цвета
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Глобальные переменные
STATUS_SSH="Не изменялось"
SSH_BACKUP_NAME="Нет"
STATUS_UFW="Не активирован"
STATUS_F2B="Не установлен"
STATUS_AUTOUP="Не установлено"
CHOSEN_MEM="Не задано"
GENERATED_PRIVATE_KEY="" # Переменная для хранения ключа
KEY_CREATED_MSG="Нет"

# --- 1. ОБНОВЛЕНИЕ ---
update_system() {
    info "Обновление сервера..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get -qqy update
    sudo -E apt-get -qqy -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    sudo apt-get -y autoremove
    info "Сервер обновлен."
}

# --- 2. ГЕНЕРАЦИЯ КЛЮЧА (НОВОЕ) ---
generate_auto_key() {
    echo ""
    info "--- АВТО-СОЗДАНИЕ КЛЮЧА ДОСТУПА ---"
    echo "Скрипт может создать новый SSH-ключ прямо сейчас и добавить его в разрешенные."
    echo "Приватный ключ будет показан В КОНЦЕ установки, чтобы вы его скопировали."
    echo "Это гарантирует, что вы не потеряете доступ к серверу."
    read -p "Создать ключ доступа? (y/N): " CONFIRM < /dev/tty

    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        info "Генерация ключа Ed25519..."
        # Генерируем во временный файл без пароля
        ssh-keygen -t ed25519 -C "generated-by-install-script" -f ./temp_access_key -N "" -q
        
        # Создаем папку ssh если нет
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        
        # Добавляем публичный ключ в авторизованные
        cat ./temp_access_key.pub >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        
        # Читаем приватный ключ в переменную
        GENERATED_PRIVATE_KEY=$(cat ./temp_access_key)
        KEY_CREATED_MSG="Да (См. конец отчета)"
        
        # Удаляем файлы с диска (безопасность)
        rm ./temp_access_key ./temp_access_key.pub
        
        info "✅ Ключ создан и добавлен в авторизованные."
    else
        warn "Пропуск создания ключа."
    fi
}

# --- 3. НАСТРОЙКА ФАЕРВОЛА ---
setup_firewall() {
    echo ""
    info "--- НАСТРОЙКА ФАЕРВОЛА (UFW) ---"
    echo "Открытие портов: 22(SSH), 80/443(Web), 8080(AIO), 3478(Talk)"
    read -p "Настроить и включить UFW? (y/N): " CONFIRM < /dev/tty
    
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        info "Настройка UFW..."
        sudo apt-get install -y ufw
        sudo ufw --force reset > /dev/null
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        
        sudo ufw allow 22/tcp comment 'SSH'
        sudo ufw allow 80/tcp comment 'HTTP'
        sudo ufw allow 443/tcp comment 'HTTPS'
        sudo ufw allow 443/udp comment 'HTTP3/QUIC'
        sudo ufw allow 8080/tcp comment 'AIO Master'
        sudo ufw allow 3478/tcp comment 'Talk TURN'
        sudo ufw allow 3478/udp comment 'Talk TURN'

        echo "y" | sudo ufw enable
        STATUS_UFW="Активен"
        info "✅ Фаервол настроен."
    else
        warn "Пропуск UFW."
    fi
}

# --- 4. НАСТРОЙКА SSH ---
harden_ssh() {
    echo ""
    info "--- БЕЗОПАСНОСТЬ SSH ---"
    echo "Отключение входа по паролю (Только ключи)."
    
    # Если мы только что создали ключ, говорим об этом
    if [[ -n "$GENERATED_PRIVATE_KEY" ]]; then
        info "💡 Вы создали ключ на предыдущем шаге, так что отключать пароли безопасно."
    fi

    read -p "Отключить вход по паролю? (y/N): " CONFIRM < /dev/tty
    
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        if [ ! -s ~/.ssh/authorized_keys ]; then
            error "ОШИБКА: Нет SSH ключей! Отмена."
            return
        fi
        
        SSH_BACKUP_NAME="/etc/ssh/sshd_config.bak.$(date +%F_%R)"
        info "Бэкап конфига: $SSH_BACKUP_NAME"
        sudo cp /etc/ssh/sshd_config "$SSH_BACKUP_NAME"
        
        sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config
        
        sudo service ssh restart
        STATUS_SSH="Вход по паролю ОТКЛЮЧЕН"
        info "✅ SSH настроен."
    fi
}

# --- 5. ДОП. ЗАЩИТА ---
install_security_tools() {
    echo ""
    info "--- АВТОМАТИЧЕСКАЯ ЗАЩИТА ---"
    echo "Fail2Ban + Unattended Upgrades"
    read -p "Установить? (y/N): " CONFIRM < /dev/tty

    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        info "Установка Fail2Ban..."
        sudo apt-get install -y fail2ban
        cat <<EOF | sudo tee /etc/fail2ban/jail.local > /dev/null
[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOF
        sudo systemctl restart fail2ban
        sudo systemctl enable fail2ban
        STATUS_F2B="Активен"

        info "Настройка авто-обновлений..."
        sudo apt-get install -y unattended-upgrades
        cat <<EOF | sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
        sudo systemctl restart unattended-upgrades
        STATUS_AUTOUP="Включено"
        info "✅ Защита установлена."
    else
        warn "Пропуск."
    fi
}

# --- 6. ПРОВЕРКА ЖЕЛЕЗА ---
check_hardware() {
    info "Проверка железа..."
    CURRENT_CPU=$(nproc)
    REQ_CPU=4
    if [ "$CURRENT_CPU" -lt "$REQ_CPU" ]; then
        warn "CPU: $CURRENT_CPU (Реком.: $REQ_CPU)."
        read -p "Продолжить? (y/N): " C < /dev/tty
        if [[ "$C" != "y" ]]; then exit 1; fi
    fi
}

configure_memory() {
    info "Настройка памяти..."
    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_RAM" -lt 3800 ]; then
        CHOSEN_MEM="512M"
    else
        echo "RAM: ${TOTAL_RAM}MB. Выбор лимита:"
        echo " 1) 1024M"
        echo " 2) 2048M"
        read -p "Выбор: " M < /dev/tty
        case "$M" in
            2) CHOSEN_MEM="2048M" ;;
            *) CHOSEN_MEM="1024M" ;;
        esac
    fi
    if grep -q "NEXTCLOUD_MEMORY_LIMIT:" "$COMPOSE_FILE"; then
        sed -i "s/NEXTCLOUD_MEMORY_LIMIT: .*/NEXTCLOUD_MEMORY_LIMIT: $CHOSEN_MEM/" "$COMPOSE_FILE"
    fi
}

# --- ВЫПОЛНЕНИЕ ---
update_system
generate_auto_key  # <-- Генерируем ключ ПЕРЕД настройкой SSH
setup_firewall
harden_ssh         # <-- Теперь здесь безопасно отключать пароли
install_security_tools
check_hardware

# --- 7. DOCKER ---
info "Установка Docker..."
if ! command -v curl &> /dev/null; then sudo apt-get install -y curl; fi
PACKAGES="apt-transport-https ca-certificates software-properties-common gnupg dnsutils"
if ! dpkg -s $PACKAGES >/dev/null 2>&1; then sudo apt-get install -y $PACKAGES; fi

if ! command -v docker &> /dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    [ ! -f /etc/apt/keyrings/docker.gpg ] && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=""$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ""$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo ln -sfv /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
fi

# --- 8. ЗАГРУЗКА И НАСТРОЙКА ---
info "Загрузка конфига..."
if curl --output /dev/null --silent --head --fail "$YAML_URL"; then
    curl -L "$YAML_URL" -o "$COMPOSE_FILE"
else
    error "Ошибка загрузки файла!"
fi

configure_memory

echo ""
echo "=== Введите домен (напр. cloud.site.com) ==="
read -p "Домен: " USER_DOMAIN < /dev/tty
if [[ -z "$USER_DOMAIN" ]]; then error "Пусто."; fi

info "Проверка DNS..."
SERVER_IP=$(curl -s4 https://ifconfig.me)
DOMAIN_IP=$(dig +short A "$USER_DOMAIN" | tail -n1)

if [[ -z "$DOMAIN_IP" ]]; then
    warn "A-запись не найдена!"
    read -p "Продолжить? (y/N): " C < /dev/tty
    if [[ "$C" != "y" ]]; then exit 1; fi
elif [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
    warn "IP не совпадают."
    read -p "Продолжить? (y/N): " C < /dev/tty
    if [[ "$C" != "y" ]]; then exit 1; fi
fi

if grep -q "$PLACEHOLDER" "$COMPOSE_FILE"; then
    sed -i "s/$PLACEHOLDER/$USER_DOMAIN/g" "$COMPOSE_FILE"
fi

if grep -q "NEXTCLOUD_DATADIR: /mnt/ncdata" "$COMPOSE_FILE"; then
    sudo mkdir -p /mnt/ncdata
fi

# --- 9. ЗАПУСК ---
info "Запуск контейнеров..."
sudo docker compose up -d

# --- 10. ГЕНЕРАЦИЯ ОТЧЕТА ---
CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")
HARDWARE_INFO="CPU: $(nproc) / RAM: $(free -h | awk '/^Mem:/{print $2}')"

# Формируем блок с ключом (если он был создан)
KEY_SECTION=""
if [[ -n "$GENERATED_PRIVATE_KEY" ]]; then
KEY_SECTION="
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!! ВАШ НОВЫЙ ПРИВАТНЫЙ КЛЮЧ (ID_ED25519)              !!!
!!! СКОПИРУЙТЕ ЕГО СЕЙЧАС И СОХРАНИТЕ В ФАЙЛ НА ПК     !!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
$GENERATED_PRIVATE_KEY
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
(Ключ удален с диска сервера и виден только здесь)
"
fi

REPORT_TEXT="
==========================================================
ОТЧЕТ ОБ УСТАНОВКЕ NEXTCLOUD AIO
Дата: $CURRENT_DATE
==========================================================

1. ОСНОВНЫЕ ДАННЫЕ
------------------
Домен:       $USER_DOMAIN
IP сервера:  $SERVER_IP
Панель AIO:  https://$USER_DOMAIN:8080
Путь конфига: $(pwd)/$COMPOSE_FILE

2. СТАТУС БЕЗОПАСНОСТИ
----------------------
Новый ключ создан: $KEY_CREATED_MSG
SSH Вход:          $STATUS_SSH
Firewall (UFW):    $STATUS_UFW
Fail2Ban:          $STATUS_F2B
Auto-Updates:      $STATUS_AUTOUP

3. БЭКАП SSH (Если нужно вернуть пароли)
----------------------------------------
Измененный файл: /etc/ssh/sshd_config
Бэкап конфига:   $SSH_BACKUP_NAME
Чтобы вернуть пароли, отредактируйте файл и перезапустите ssh.

4. ЧТО ДАЛЬШЕ
-------------
1. Зайдите в панель (Инкогнито!): https://$USER_DOMAIN:8080
2. Нажмите 'Download and start containers'.
==========================================================
"

# Сохраняем в файл отчет (БЕЗ приватного ключа, для безопасности)
echo "$REPORT_TEXT" > "$REPORT_FILE"

# Очищаем экран и выводим отчет + КЛЮЧ
clear
echo -e "${GREEN}$REPORT_TEXT${NC}"
if [[ -n "$KEY_SECTION" ]]; then
    echo -e "${YELLOW}$KEY_SECTION${NC}"
fi
echo ""
info "✅ Отчет (без ключа) сохранен в: $(pwd)/$REPORT_FILE"