#!/bin/bash

# --- НАСТРОЙКИ ---
DEFAULT_YAML_URL="https://raw.githubusercontent.com/FluentBusiness/aio-nextcloud-docker/refs/heads/master/docker-compose.yaml"
COMPOSE_FILENAME="docker-compose.yaml"
PLACEHOLDER="YOUR_DOMAIN" 
NC_USER="root" # Работаем от root

YAML_URL="${1:-$DEFAULT_YAML_URL}"

set -e

# --- ЦВЕТА ---
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- ФУНКЦИЯ ПРОВЕРКИ ВВОДА ---
ask_yes_no() {
    local prompt="$1"
    while true; do
        read -p "$prompt (y/n): " INPUT < /dev/tty
        case "$INPUT" in
            [yY]|[yY][eE][sS])
                CONFIRM="y"
                return 0
                ;;
            [nN]|[nN][oO])
                CONFIRM="n"
                return 1
                ;;
            *)
                echo -e "${YELLOW}Ошибка: Пожалуйста, введите 'y' (Да) или 'n' (Нет).${NC}"
                ;;
        esac
    done
}

# --- ПЕРЕМЕННЫЕ ДЛЯ ОТЧЕТА ---
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
REPORT_FILE="report_${TIMESTAMP}.txt"
CHANGELOG_BODY=""
UFW_REPORT_INFO="Фаервол не настраивался в этом запуске (статус неизвестен)."

log_change() {
    local component="$1"
    local file_path="$2"
    local change_desc="$3"
    local revert_instr="$4"

    CHANGELOG_BODY="${CHANGELOG_BODY}
--------------------------------------------------------------------------------
КОМПОНЕНТ:  $component
ФАЙЛ:       $file_path
ИЗМЕНЕНИЕ:  $change_desc
КАК ВЕРНУТЬ:
$revert_instr
"
}

# --- ПУТИ ---
INSTALL_HOME="/root"     
PROJECT_DIR="/root"      
DATA_DIR="/mnt/ncdata"   # <--- СТРОГО КАК В DOCKER-COMPOSE
MOUNT_DIR="/mnt/"        # <--- СТРОГО КАК В DOCKER-COMPOSE

# Глобальные переменные состояния
GENERATED_PRIVATE_KEY=""
GENERATED_PPK_KEY="" 
KEY_CREATED_MSG="Нет"
RCLONE_MOUNT_POINT="Не настроено"

# --- 1. ОБНОВЛЕНИЕ ---
update_system() {
    info "Обновление сервера..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get -qqy update
    sudo -E apt-get -qqy -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    sudo apt-get -y autoremove
    info "Сервер обновлен."
    log_change "SYSTEM UPDATE" "System Packages" "apt update & upgrade" "Откат не требуется"
}

# --- 2. ГЕНЕРАЦИЯ КЛЮЧА ---
generate_auto_key() {
    echo ""
    info "--- АВТО-СОЗДАНИЕ КЛЮЧА ДОСТУПА ---"
    
    ask_yes_no "Создать новый SSH-ключ (OpenSSH + PuTTY)?"

    if [[ "$CONFIRM" == "y" ]]; then
        info "Установка putty-tools..."
        if ! dpkg -s putty-tools >/dev/null 2>&1; then
            sudo apt-get install -y putty-tools
        fi

        ssh-keygen -t ed25519 -C "generated-by-install-script" -f ./temp_access_key -N "" -q
        puttygen ./temp_access_key -o ./temp_access_key.ppk -O private

        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        cat ./temp_access_key.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        
        GENERATED_PRIVATE_KEY=$(cat ./temp_access_key)
        GENERATED_PPK_KEY=$(cat ./temp_access_key.ppk)
        KEY_CREATED_MSG="Да"
        
        rm ./temp_access_key ./temp_access_key.pub ./temp_access_key.ppk
        info "✅ Ключи созданы."
        log_change "SSH KEY" "~/.ssh/authorized_keys" "Добавлен новый ключ" "Удалить строку"
    fi
}

# --- 3. ФАЕРВОЛ ---
setup_firewall() {
    echo ""
    info "--- ФАЕРВОЛ (UFW) ---"
    
    ask_yes_no "Настроить UFW?"
    
    if [[ "$CONFIRM" == "y" ]]; then
        sudo apt-get install -y ufw
        sudo ufw --force reset > /dev/null
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        
        sudo ufw allow 22/tcp comment 'SSH'
        sudo ufw allow 80/tcp comment 'HTTP Nextcloud'
        sudo ufw allow 443/tcp comment 'HTTPS Nextcloud'
        sudo ufw allow 443/udp comment 'HTTP/3 Nextcloud'
        sudo ufw allow 8080/tcp comment 'AIO Interface'
        sudo ufw allow 3478/tcp comment 'Talk TURN TCP'
        sudo ufw allow 3478/udp comment 'Talk TURN UDP'
        
        sudo ufw allow in on docker0 comment 'Allow Docker Bridge Traffic'
        sudo ufw allow from 172.16.0.0/12 comment 'Allow Docker Subnet'
        
        echo "y" | sudo ufw enable
        info "✅ UFW активен."
        UFW_REPORT_INFO="СТАТУС: Активен. DOCKER: Разрешен. ПОРТЫ: 22,80,443,8080,3478"
        log_change "FIREWALL" "UFW" "Включен UFW" "sudo ufw disable"
    fi
}

# --- 4. SSH ---
harden_ssh() {
    echo ""
    info "--- SSH ---"
    ask_yes_no "Отключить вход по паролю?"
    
    if [[ "$CONFIRM" == "y" ]]; then
        TARGET_SSH_DIR="/root/.ssh"
        
        if [ ! -s "$TARGET_SSH_DIR/authorized_keys" ]; then
            error "ОШИБКА: Нет ключей! Отмена."
            return
        fi
        
        SSH_BACKUP_NAME="/etc/ssh/sshd_config.bak.$(date +%F_%R)"
        sudo cp /etc/ssh/sshd_config "$SSH_BACKUP_NAME"
        
        sudo sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        if ! grep -q "^PubkeyAuthentication" /etc/ssh/sshd_config; then echo "PubkeyAuthentication yes" | sudo tee -a /etc/ssh/sshd_config; fi
        
        sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config
        
        # Разрешаем root логин (так как пароли отключены, вход только по ключу)
        sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        if ! grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then echo "PermitRootLogin yes" | sudo tee -a /etc/ssh/sshd_config; fi
        
        sudo service ssh restart
        info "✅ SSH защищен."
        log_change "SSH" "/etc/ssh/sshd_config" "PasswordAuth no, PermitRootLogin yes" "cp backup"
    fi
}

# --- 5. TOOLS ---
install_security_tools() {
    echo ""
    info "--- SECURITY TOOLS ---"
    ask_yes_no "Установить Fail2Ban и Auto-Updates?"
    
    if [[ "$CONFIRM" == "y" ]]; then
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

        sudo apt-get install -y unattended-upgrades
        cat <<EOF | sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
        sudo systemctl restart unattended-upgrades
        info "✅ Инструменты установлены."
        log_change "SECURITY" "Fail2Ban/Unattended" "Installed" "apt remove"
    fi
}

install_utilities() {
    echo ""
    info "--- ПОЛЕЗНЫЕ УТИЛИТЫ ---"
    ask_yes_no "Установить Midnight Commander (mc)?"
    if [[ "$CONFIRM" == "y" ]]; then
        sudo apt-get install -y mc
        info "✅ MC установлен."
        log_change "UTILITIES" "mc" "Installed" "apt remove mc"
    fi
}

# --- 6. RCLONE / S3 ---
setup_rclone() {
    echo ""
    info "--- S3 STORAGE (RCLONE) ---"
    ask_yes_no "Установить и настроить Rclone?"

    if [[ "$CONFIRM" == "y" ]]; then
        info "Установка Rclone..."
        sudo apt-get install -y fuse3 unzip
        if ! command -v rclone &> /dev/null; then curl https://rclone.org/install.sh | sudo bash; fi
        sudo sed -i 's/#user_allow_other/user_allow_other/' /etc/fuse.conf

        REMOTE_NAME="s3_backup"
        while true; do
            echo ""
            echo "Введите данные S3:"
            read -p "S3 Endpoint: " S3_ENDPOINT
            read -p "S3 Access Key: " S3_ACCESS_KEY
            read -s -p "S3 Secret Key: " S3_SECRET_KEY
            echo ""
            read -p "Имя бакета: " S3_BUCKET
            
            mkdir -p /root/.config/rclone/
            rclone config create "$REMOTE_NAME" s3 provider=Other env_auth=false access_key_id="$S3_ACCESS_KEY" secret_access_key="$S3_SECRET_KEY" endpoint="$S3_ENDPOINT" acl=private --non-interactive > /dev/null 2>&1

            info "Проверка..."
            if rclone lsd "$REMOTE_NAME:$S3_BUCKET" --config /root/.config/rclone/rclone.conf > /dev/null 2>&1; then
                info "✅ Подключение успешно."
                break
            else
                error "❌ Ошибка подключения!"
                echo ""
                ask_yes_no "Попробовать снова?"
                if [[ "$CONFIRM" != "y" ]]; then return; fi
            fi
        done
        
        DEFAULT_MOUNT="$MOUNT_DIR/backup/borg"
        echo "Монтируем в $DEFAULT_MOUNT (внутри $MOUNT_DIR)"
        
        TARGET_MOUNT="$DEFAULT_MOUNT"
        mkdir -p "$TARGET_MOUNT"
        
        SERVICE_FILE="/etc/systemd/system/rclone-backup.service"
        
        cat <<EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Rclone Mount
AssertPathIsDirectory=$TARGET_MOUNT
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount $REMOTE_NAME:$S3_BUCKET $TARGET_MOUNT \\
    --config=/root/.config/rclone/rclone.conf \\
    --allow-other \\
    --vfs-cache-mode writes \\
    --uid=0 --gid=0 \\
    --umask=002
ExecStop=/bin/fusermount3 -u $TARGET_MOUNT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        
        sudo systemctl daemon-reload
        sudo systemctl enable rclone-backup.service
        sudo systemctl start rclone-backup.service
        RCLONE_MOUNT_POINT="$TARGET_MOUNT"
        info "✅ Rclone смонтирован."
    fi
}

# --- 7. ЖЕЛЕЗО ---
check_hardware() {
    CURRENT_CPU=$(nproc)
    REQ_CPU=4
    if [ "$CURRENT_CPU" -lt "$REQ_CPU" ]; then
        warn "CPU < 4 ядер. Продолжить?"
        ask_yes_no "Подтвердить?"
        if [[ "$CONFIRM" != "y" ]]; then exit 1; fi
    fi
}

configure_memory() {
    echo ""
    info "--- ПАМЯТЬ ---"
    echo "1) 1024M  2) 2048M  Enter) 512M"
    read -p "Выбор: " M < /dev/tty
    case "$M" in
        1) CHOSEN_MEM="1024M" ;;
        2) CHOSEN_MEM="2048M" ;;
        *) CHOSEN_MEM="512M" ;;
    esac
    if grep -q "NEXTCLOUD_MEMORY_LIMIT:" "$PROJECT_DIR/$COMPOSE_FILENAME"; then
        sed -i "s/NEXTCLOUD_MEMORY_LIMIT: .*/NEXTCLOUD_MEMORY_LIMIT: $CHOSEN_MEM/" "$PROJECT_DIR/$COMPOSE_FILENAME"
    fi
}

# --- ИСПОЛНЕНИЕ ---
update_system

info "Установка Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    log_change "DOCKER" "System" "Install Docker" "apt purge..."
fi

generate_auto_key
setup_firewall
harden_ssh
install_security_tools
install_utilities
setup_rclone        
check_hardware

# --- ЗАГРУЗКА ---
info "Подготовка папок..."
# Создаем папки ДЛЯ ДАННЫХ В /mnt
mkdir -p "$DATA_DIR"
mkdir -p "$MOUNT_DIR"

mkdir -p "$PROJECT_DIR"
info "Загрузка конфига в $PROJECT_DIR..."
COMPOSE_FULL_PATH="$PROJECT_DIR/$COMPOSE_FILENAME"

if curl --output /dev/null --silent --head --fail "$YAML_URL"; then
    curl -L "$YAML_URL" -o "$COMPOSE_FULL_PATH"
else error "Ошибка загрузки!"; fi

# --- НАСТРОЙКА ПУТЕЙ В YAML ---
# Здесь мы подставляем /mnt/ncdata и /mnt/, которые теперь зафиксированы
sed -i "s|NEXTCLOUD_DATADIR: /mnt/ncdata|NEXTCLOUD_DATADIR: $DATA_DIR|g" "$COMPOSE_FULL_PATH"
sed -i "s|NEXTCLOUD_MOUNT: /mnt/|NEXTCLOUD_MOUNT: $MOUNT_DIR|g" "$COMPOSE_FULL_PATH"

configure_memory

echo ""
read -p "Введите домен: " USER_DOMAIN < /dev/tty
if [[ -z "$USER_DOMAIN" ]]; then error "Пусто."; fi

if grep -q "$PLACEHOLDER" "$COMPOSE_FULL_PATH"; then
    sed -i "s/$PLACEHOLDER/$USER_DOMAIN/g" "$COMPOSE_FULL_PATH"
fi

info "Запуск..."
cd "$PROJECT_DIR"
sudo docker compose up -d

# --- ОТЧЕТ ---
KEY_SECTION=""
if [[ -n "$GENERATED_PRIVATE_KEY" ]]; then
KEY_SECTION="
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!   ВНИМАНИЕ: ДОСТУП ПО ПАРОЛЮ ОТКЛЮЧЕН (ROOT)       !!!
!!!   ЕСЛИ НЕ СОХРАНИТЬ КЛЮЧИ - ДОСТУП БУДЕТ УТЕРЯН    !!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

----------------------------------------------------------
1. ПРИВАТНЫЙ КЛЮЧ (OPENSSH) - Для Linux / MacOS / Coolify
----------------------------------------------------------
Вход: ssh -i key_file root@$SERVER_IP
----------------------------------------------------------
$GENERATED_PRIVATE_KEY
----------------------------------------------------------

----------------------------------------------------------
2. ПРИВАТНЫЙ КЛЮЧ (PuTTY .PPK) - Для Windows (PuTTY)
----------------------------------------------------------
Сохраните текст ниже в файл с расширением .ppk
----------------------------------------------------------
$GENERATED_PPK_KEY
----------------------------------------------------------
"
fi

REPORT_TEXT="
==========================================================
 ОТЧЕТ О ЗАПУСКЕ СКРИПТА (CHANGELOG)
 Дата: $TIMESTAMP
 Файл: $PROJECT_DIR/$REPORT_FILE
==========================================================

1. ОБЩАЯ ИНФОРМАЦИЯ
-------------------
Домен:        $USER_DOMAIN
IP:           $SERVER_IP
Пользователь: $NC_USER (ROOT)

[ПУТИ]
Config Dir:   $PROJECT_DIR   (Docker Compose)
Data Dir:     $DATA_DIR      (Файлы Nextcloud)
Mount Dir:    $MOUNT_DIR     (Точка монтирования хоста)
Rclone Mount: $RCLONE_MOUNT_POINT

2. ЖУРНАЛ ИЗМЕНЕНИЙ
-------------------
$CHANGELOG_BODY

3. СТАТУС ФАЕРВОЛА (UFW)
------------------------
$UFW_REPORT_INFO

4. POST-INSTALL TIPS
--------------------
Apps to install inside Nextcloud:
1. Two-Factor TOTP Provider
2. Password Policy
3. Antivirus for Files (ClamAV)
4. Suspicious Login Detection
5. Ransomware protection

==========================================================
!!! ФИНАЛЬНЫЙ ШАГ !!!
==========================================================
Панель: https://$USER_DOMAIN:8080
РЕЖИМ:  ИНКОГНИТО (PRIVATE MODE) - если ругается SSL
==========================================================
"

# Сохранение отчета на диск
echo "$REPORT_TEXT" > "$PROJECT_DIR/$REPORT_FILE"

# Создание ссылки на отчет в текущей папке (чтобы легко найти)
if [[ "$(pwd)" != "$PROJECT_DIR" ]]; then 
    ln -sf "$PROJECT_DIR/$REPORT_FILE" ./latest_install_report.txt
fi

# Вывод на экран
clear
echo -e "${GREEN}$REPORT_TEXT${NC}"
if [[ -n "$KEY_SECTION" ]]; then echo -e "${YELLOW}$KEY_SECTION${NC}"; fi
echo ""
info "✅ Отчет сохранен: $PROJECT_DIR/$REPORT_FILE"