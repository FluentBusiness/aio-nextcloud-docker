#!/bin/bash

# --- НАСТРОЙКИ ---
# Ссылка на репозиторий
DEFAULT_YAML_URL="https://raw.githubusercontent.com/FluentBusiness/aio-nextcloud-docker/refs/heads/master/docker-compose.yaml"
COMPOSE_FILENAME="docker-compose.yaml"
REPORT_FILE="install_report.txt"
PLACEHOLDER="YOUR_DOMAIN" 
NC_USER="nextcloud" 

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

# Глобальные переменные состояния
SSH_BACKUP_NAME="Не создавался"
GENERATED_PRIVATE_KEY=""
KEY_CREATED_MSG="Нет"
LOG_USER="Без изменений"
LOG_SSH="Без изменений"
LOG_UFW="Без изменений"
LOG_TOOLS="Без изменений"
LOG_DOCKER_CFG="Без изменений"

# Переменные путей (Default values)
INSTALL_HOME="/root"
PROJECT_DIR="/root"
DATA_DIR="/mnt/ncdata"
MOUNT_DIR="/mnt/"

# --- 1. ОБНОВЛЕНИЕ ---
update_system() {
    info "Обновление сервера..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get -qqy update
    sudo -E apt-get -qqy -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    sudo apt-get -y autoremove
    info "Сервер обновлен."
}

# --- 2. ГЕНЕРАЦИЯ КЛЮЧА ---
generate_auto_key() {
    echo ""
    info "--- АВТО-СОЗДАНИЕ КЛЮЧА ДОСТУПА ---"
    read -p "Создать новый SSH-ключ? (y/N): " CONFIRM < /dev/tty

    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        # Генерируем во временный файл
        ssh-keygen -t ed25519 -C "generated-by-install-script" -f ./temp_access_key -N "" -q
        
        # Добавляем текущему пользователю (root)
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        cat ./temp_access_key.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        
        # Сохраняем в переменную для вывода в конце
        GENERATED_PRIVATE_KEY=$(cat ./temp_access_key)
        KEY_CREATED_MSG="Да"
        
        # Удаляем временные файлы с диска
        rm ./temp_access_key ./temp_access_key.pub
        info "✅ Ключ создан и временно добавлен текущему пользователю."
    fi
}

# --- 3. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ И ПУТЕЙ ---
setup_new_user() {
    echo ""
    info "--- БЕЗОПАСНОСТЬ И ПУТИ ---"
    echo "Рекомендуется: создать пользователя '$NC_USER' и установить Nextcloud в /home/$NC_USER."
    read -p "Выполнить? (y/N): " CONFIRM < /dev/tty
    
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        if id "$NC_USER" &>/dev/null; then
            warn "Пользователь $NC_USER уже существует."
            LOG_USER="Пользователь $NC_USER уже существовал."
        else
            info "Создание $NC_USER..."
            adduser --gecos "" "$NC_USER"
            usermod -aG sudo "$NC_USER"
            
            # Копируем ключи (включая только что созданный) новому юзеру
            mkdir -p "/home/$NC_USER/.ssh"
            if [ -f ~/.ssh/authorized_keys ]; then
                cp ~/.ssh/authorized_keys "/home/$NC_USER/.ssh/"
                chmod 700 "/home/$NC_USER/.ssh"
                chmod 600 "/home/$NC_USER/.ssh/authorized_keys"
                chown -R "$NC_USER:$NC_USER" "/home/$NC_USER/.ssh"
            fi
            
            # Блокируем пароль root
            passwd -l root
            
            LOG_USER="1. Пользователь: $NC_USER\n   2. Root отключен\n   3. Пути изменены на /home/$NC_USER"
            info "✅ Пользователь создан, ключи скопированы."
        fi
        
        # ОБНОВЛЕНИЕ ПУТЕЙ (Переключаемся на структуру /home)
        INSTALL_HOME="/home/$NC_USER"
        PROJECT_DIR="$INSTALL_HOME/aio-config"
        DATA_DIR="$INSTALL_HOME/ncdata"
        MOUNT_DIR="$INSTALL_HOME/mnt/" 
        
    else
        warn "Выбрана установка от имени Root."
        INSTALL_HOME=$(pwd)
        PROJECT_DIR=$(pwd)
        DATA_DIR="/mnt/ncdata"
        MOUNT_DIR="/mnt/"
    fi
    
    info "📂 Config Dir: $PROJECT_DIR"
    info "📂 Data Dir:   $DATA_DIR"
    info "📂 Mount Dir:  $MOUNT_DIR"
}

# --- 4. ФАЕРВОЛ ---
setup_firewall() {
    echo ""
    info "--- ФАЕРВОЛ (UFW) ---"
    read -p "Настроить UFW? (y/N): " CONFIRM < /dev/tty
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        sudo apt-get install -y ufw
        sudo ufw --force reset > /dev/null
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        # Открываем порты
        for port in 22 80 443 8080 3478; do sudo ufw allow "$port"/tcp; done
        sudo ufw allow 443/udp
        sudo ufw allow 3478/udp
        echo "y" | sudo ufw enable
        LOG_UFW="Активен"
        info "✅ UFW активен."
    fi
}

# --- 5. SSH HARDENING ---
harden_ssh() {
    echo ""
    info "--- SSH ---"
    read -p "Отключить вход по паролю и Root Login? (y/N): " CONFIRM < /dev/tty
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        # Проверяем наличие ключей в ЦЕЛЕВОЙ папке
        TARGET_SSH_DIR="/root/.ssh"
        if [[ "$INSTALL_HOME" == "/home/$NC_USER" ]]; then TARGET_SSH_DIR="/home/$NC_USER/.ssh"; fi
        
        if [ ! -s "$TARGET_SSH_DIR/authorized_keys" ]; then
            error "ОШИБКА: Нет ключей в $TARGET_SSH_DIR! Отмена действия."
            return
        fi
        
        SSH_BACKUP_NAME="/etc/ssh/sshd_config.bak.$(date +%F_%R)"
        sudo cp /etc/ssh/sshd_config "$SSH_BACKUP_NAME"
        
        # Отключаем пароли
        sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config
        
        # Если мы переехали в /home, можно смело отключать Root Login в SSH
        if [[ "$INSTALL_HOME" == "/home/$NC_USER" ]]; then
             sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
             if ! grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then echo "PermitRootLogin no" | sudo tee -a /etc/ssh/sshd_config; fi
        fi
        
        sudo service ssh restart
        LOG_SSH="Защищен (No Password, No Root)"
        info "✅ SSH защищен."
    fi
}

# --- 6. TOOLS ---
install_security_tools() {
    echo ""
    info "--- SECURITY TOOLS ---"
    read -p "Установить Fail2Ban и Auto-Updates? (y/N): " CONFIRM < /dev/tty
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        # Fail2Ban
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

        # Auto-Updates
        sudo apt-get install -y unattended-upgrades
        cat <<EOF | sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
        sudo systemctl restart unattended-upgrades
        LOG_TOOLS="Установлены"
        info "✅ Инструменты установлены."
    fi
}

# --- 7. ЖЕЛЕЗО ---
check_hardware() {
    CURRENT_CPU=$(nproc)
    REQ_CPU=4
    if [ "$CURRENT_CPU" -lt "$REQ_CPU" ]; then
        warn "CPU < 4 ядер. Продолжить? (y/N): "
        read C < /dev/tty; if [[ "$C" != "y" ]]; then exit 1; fi
    fi
}

configure_memory() {
    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    COMPOSE_FULL_PATH="$PROJECT_DIR/$COMPOSE_FILENAME"
    if [ "$TOTAL_RAM" -lt 3800 ]; then CHOSEN_MEM="512M"; else
        CHOSEN_MEM="1024M" 
        echo "RAM: ${TOTAL_RAM}MB. 1) 1024M 2) 2048M"
        read -p "Выбор: " M < /dev/tty
        if [[ "$M" == "2" ]]; then CHOSEN_MEM="2048M"; fi
    fi
    if grep -q "NEXTCLOUD_MEMORY_LIMIT:" "$COMPOSE_FULL_PATH"; then
        sed -i "s/NEXTCLOUD_MEMORY_LIMIT: .*/NEXTCLOUD_MEMORY_LIMIT: $CHOSEN_MEM/" "$COMPOSE_FULL_PATH"
    fi
    LOG_DOCKER_CFG="$LOG_DOCKER_CFG\n   - Память: $CHOSEN_MEM"
}

# --- ИСПОЛНЕНИЕ ---
update_system

# Устанавливаем Docker СРАЗУ, чтобы usermod -aG docker сработал
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

generate_auto_key
setup_new_user      
setup_firewall
harden_ssh
install_security_tools
check_hardware

# --- ЗАГРУЗКА И НАСТРОЙКА ---
info "Подготовка папок..."
mkdir -p "$PROJECT_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$MOUNT_DIR"

info "Загрузка конфига в $PROJECT_DIR..."
COMPOSE_FULL_PATH="$PROJECT_DIR/$COMPOSE_FILENAME"

if curl --output /dev/null --silent --head --fail "$YAML_URL"; then
    curl -L "$YAML_URL" -o "$COMPOSE_FULL_PATH"
else error "Ошибка загрузки!"; fi

# --- НАСТРОЙКА ПУТЕЙ В YAML ---
info "Настройка путей в docker-compose..."

# Замена NEXTCLOUD_DATADIR
sed -i "s|NEXTCLOUD_DATADIR: /mnt/ncdata|NEXTCLOUD_DATADIR: $DATA_DIR|g" "$COMPOSE_FULL_PATH"
LOG_DOCKER_CFG="$LOG_DOCKER_CFG\n   - DATADIR: $DATA_DIR"

# Замена NEXTCLOUD_MOUNT
sed -i "s|NEXTCLOUD_MOUNT: /mnt/|NEXTCLOUD_MOUNT: $MOUNT_DIR|g" "$COMPOSE_FULL_PATH"
LOG_DOCKER_CFG="$LOG_DOCKER_CFG\n   - MOUNT: $MOUNT_DIR"

configure_memory

echo ""
read -p "Введите домен: " USER_DOMAIN < /dev/tty
if [[ -z "$USER_DOMAIN" ]]; then error "Пусто."; fi

SERVER_IP=$(curl -s4 https://ifconfig.me)
DOMAIN_IP=$(dig +short A "$USER_DOMAIN" | tail -n1)
if [[ -z "$DOMAIN_IP" ]]; then warn "DNS не найден! Продолжить? (y/N)"; read C < /dev/tty; if [[ "$C" != "y" ]]; then exit 1; fi
elif [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then warn "IP отличаются. Продолжить? (y/N)"; read C < /dev/tty; if [[ "$C" != "y" ]]; then exit 1; fi; fi

if grep -q "$PLACEHOLDER" "$COMPOSE_FULL_PATH"; then
    sed -i "s/$PLACEHOLDER/$USER_DOMAIN/g" "$COMPOSE_FULL_PATH"
    LOG_DOCKER_CFG="$LOG_DOCKER_CFG\n   - Домен: $USER_DOMAIN"
fi

# Назначение прав пользователю
if [[ "$INSTALL_HOME" == "/home/$NC_USER" ]]; then
    info "Назначение прав владельца пользователю $NC_USER..."
    usermod -aG docker "$NC_USER" || true
    # Рекурсивно отдаем всю домашнюю папку
    chown -R "$NC_USER:$NC_USER" "$INSTALL_HOME"
fi

info "Запуск контейнеров..."
cd "$PROJECT_DIR"
sudo docker compose up -d

# --- ОТЧЕТ ---
CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")
KEY_SECTION=""
if [[ -n "$GENERATED_PRIVATE_KEY" ]]; then
KEY_SECTION="
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!! ВАШ НОВЫЙ ПРИВАТНЫЙ КЛЮЧ (ID_ED25519)              !!!
!!! СКОПИРУЙТЕ ЕГО СЕЙЧАС!                             !!!
!!! Вход: ssh -i key_file $NC_USER@$SERVER_IP
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
$GENERATED_PRIVATE_KEY
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
"
fi

REPORT_TEXT="
==========================================================
ОТЧЕТ ОБ УСТАНОВКЕ NEXTCLOUD AIO
Дата: $CURRENT_DATE
==========================================================

1. ЛОКАЦИЯ УСТАНОВКИ
--------------------
Пользователь: $NC_USER
Конфиги:      $PROJECT_DIR/$COMPOSE_FILENAME
Данные:       $DATA_DIR
Mount Point:  $MOUNT_DIR

2. ЖУРНАЛ ИЗМЕНЕНИЙ
-------------------
[A] ПОЛЬЗОВАТЕЛИ: $LOG_USER
[B] SSH:          $LOG_SSH
[C] ФАЕРВОЛ:      $LOG_UFW
[D] CONFIG:       $LOG_DOCKER_CFG
[E] НОВЫЙ КЛЮЧ:   $KEY_CREATED_MSG

3. РЕКОМЕНДАЦИИ ПО БЕЗОПАСНОСТИ (NEXTCLOUD APPS)
------------------------------------------------
1. Two-Factor TOTP Provider
2. Password Policy
3. Antivirus for Files (ClamAV)
4. Suspicious Login Detection
5. Ransomware protection

==========================================================
!!! ФИНАЛЬНЫЙ ШАГ (ВХОД В СИСТЕМУ) !!!
==========================================================
Адрес панели: https://$USER_DOMAIN:8080

ВАЖНАЯ РЕКОМЕНДАЦИЯ:
Открывайте эту ссылку в режиме ИНКОГНИТО (PRIVATE MODE) браузера!
Это необходимо, чтобы избежать ошибок кэширования и SSL при первом входе.
==========================================================
"

echo "$REPORT_TEXT" > "$PROJECT_DIR/$REPORT_FILE"
if [[ "$(pwd)" != "$PROJECT_DIR" ]]; then ln -sf "$PROJECT_DIR/$REPORT_FILE" ./$REPORT_FILE; fi

clear
echo -e "${GREEN}$REPORT_TEXT${NC}"
if [[ -n "$KEY_SECTION" ]]; then echo -e "${YELLOW}$KEY_SECTION${NC}"; fi
echo ""
info "✅ Отчет сохранен в: $PROJECT_DIR/$REPORT_FILE"