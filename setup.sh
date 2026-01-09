#!/bin/bash

# --- НАСТРОЙКИ ---
DEFAULT_YAML_URL="https://raw.githubusercontent.com/FluentBusiness/aio-nextcloud-docker/refs/heads/master/docker-compose.yaml"
COMPOSE_FILENAME="docker-compose.yaml"
PLACEHOLDER="YOUR_DOMAIN" 
NC_USER="nextcloud" 

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

# Переменная для детального отчета по портам
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

# Переменные путей (Default)
INSTALL_HOME="/root"
PROJECT_DIR="/root"
DATA_DIR="/mnt/ncdata"
MOUNT_DIR="/mnt/"

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

# --- 2. ГЕНЕРАЦИЯ КЛЮЧА (С PUTTY) ---
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
        
        info "Конвертация в формат PuTTY (.ppk)..."
        puttygen ./temp_access_key -o ./temp_access_key.ppk -O private

        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        cat ./temp_access_key.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        
        GENERATED_PRIVATE_KEY=$(cat ./temp_access_key)
        GENERATED_PPK_KEY=$(cat ./temp_access_key.ppk)
        
        KEY_CREATED_MSG="Да"
        
        rm ./temp_access_key ./temp_access_key.pub ./temp_access_key.ppk
        
        info "✅ Ключи созданы (OpenSSH и PuTTY)."
        log_change "SSH KEY" "~/.ssh/authorized_keys" "Добавлен новый ключ (включая .ppk версию в отчете)" "Удалить строку из authorized_keys"
    fi
}

# --- 3. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ---
setup_new_user() {
    echo ""
    info "--- БЕЗОПАСНОСТЬ И ПУТИ ---"
    echo "Рекомендуется: создать пользователя '$NC_USER' и установить Nextcloud в /home/$NC_USER."
    
    ask_yes_no "Выполнить?"
    
    if [[ "$CONFIRM" == "y" ]]; then
        if id "$NC_USER" &>/dev/null; then
            warn "Пользователь $NC_USER уже существует."
            log_change "USER" "/etc/passwd" "Пользователь уже был" "-"
        else
            info "Создание $NC_USER..."
            adduser --gecos "" "$NC_USER"
            usermod -aG sudo "$NC_USER"
            mkdir -p "/home/$NC_USER/.ssh"
            if [ -f ~/.ssh/authorized_keys ]; then
                cp ~/.ssh/authorized_keys "/home/$NC_USER/.ssh/"
                chmod 700 "/home/$NC_USER/.ssh"
                chmod 600 "/home/$NC_USER/.ssh/authorized_keys"
                chown -R "$NC_USER:$NC_USER" "/home/$NC_USER/.ssh"
            fi
            passwd -l root
            info "✅ Пользователь создан."
            log_change "USER" "User & Root" "Создан $NC_USER, Root disabled" "sudo passwd -u root"
        fi
        
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
        log_change "USER" "-" "Используется Root" "-"
    fi
}

# --- 4. ФАЕРВОЛ ---
setup_firewall() {
    echo ""
    info "--- ФАЕРВОЛ (UFW) ---"
    
    ask_yes_no "Настроить UFW?"
    
    if [[ "$CONFIRM" == "y" ]]; then
        sudo apt-get install -y ufw
        sudo ufw --force reset > /dev/null
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        
        # Настройка правил
        sudo ufw allow 22/tcp comment 'SSH'
        sudo ufw allow 80/tcp comment 'HTTP Nextcloud'
        sudo ufw allow 443/tcp comment 'HTTPS Nextcloud'
        sudo ufw allow 443/udp comment 'HTTP/3 Nextcloud'
        sudo ufw allow 8080/tcp comment 'AIO Interface'
        sudo ufw allow 3478/tcp comment 'Talk TURN TCP'
        sudo ufw allow 3478/udp comment 'Talk TURN UDP'
        
        echo "y" | sudo ufw enable
        
        info "✅ UFW активен."
        
        # Формирование детального текста для отчета
        UFW_REPORT_INFO="
СТАТУС: Активен (Active)
ПОЛИТИКА ПО УМОЛЧАНИЮ: Deny Incoming / Allow Outgoing

ОТКРЫТЫЕ ПОРТЫ:
  - 22/tcp   : SSH (Удаленный доступ)
  - 80/tcp   : HTTP (Веб-сервер / Let's Encrypt)
  - 443/tcp  : HTTPS (Основной трафик)
  - 443/udp  : HTTP/3 (QUIC протокол)
  - 8080/tcp : Панель управления AIO
  - 3478/tcp : Nextcloud Talk (TURN)
  - 3478/udp : Nextcloud Talk (TURN)
"
        
        log_change "FIREWALL" "UFW" "Включен UFW, открыты порты 22,80,443,8080,3478" "sudo ufw disable"
    fi
}

# --- 5. SSH ---
harden_ssh() {
    echo ""
    info "--- SSH ---"
    
    ask_yes_no "Отключить вход по паролю и Root Login?"
    
    if [[ "$CONFIRM" == "y" ]]; then
        TARGET_SSH_DIR="/root/.ssh"
        if [[ "$INSTALL_HOME" == "/home/$NC_USER" ]]; then TARGET_SSH_DIR="/home/$NC_USER/.ssh"; fi
        
        if [ ! -s "$TARGET_SSH_DIR/authorized_keys" ]; then
            error "ОШИБКА: Нет ключей! Отмена."
            return
        fi
        
        SSH_BACKUP_NAME="/etc/ssh/sshd_config.bak.$(date +%F_%R)"
        sudo cp /etc/ssh/sshd_config "$SSH_BACKUP_NAME"
        
        # Гарантируем вход по ключу
        sudo sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        if ! grep -q "^PubkeyAuthentication" /etc/ssh/sshd_config; then 
            echo "PubkeyAuthentication yes" | sudo tee -a /etc/ssh/sshd_config
        fi

        # Отключаем пароли
        sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config
        
        if [[ "$INSTALL_HOME" == "/home/$NC_USER" ]]; then
             sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
             if ! grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then echo "PermitRootLogin no" | sudo tee -a /etc/ssh/sshd_config; fi
        fi
        
        sudo service ssh restart
        info "✅ SSH защищен."
        log_change "SSH" "/etc/ssh/sshd_config" "PubkeyAuth yes, PasswordAuth no" "cp $SSH_BACKUP_NAME /etc/ssh/sshd_config"
    fi
}

# --- 6. TOOLS ---
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
        log_change "SECURITY" "Fail2Ban/Unattended" "Установлены" "apt remove..."
    fi
}

# --- 6.5. UTILITIES (MC) ---
install_utilities() {
    echo ""
    info "--- ПОЛЕЗНЫЕ УТИЛИТЫ ---"
    
    ask_yes_no "Установить Midnight Commander (mc)?"
    
    if [[ "$CONFIRM" == "y" ]]; then
        info "Установка MC..."
        sudo apt-get install -y mc
        info "✅ Midnight Commander установлен."
        log_change "UTILITIES" "System Packages" "Установлен Midnight Commander (mc)" "sudo apt remove mc"
    fi
}

# --- 7. RCLONE / S3 ---
setup_rclone() {
    echo ""
    info "--- S3 STORAGE (RCLONE) ---"
    echo "Вы можете подключить S3-хранилище и примонтировать его как папку."
    
    ask_yes_no "Установить и настроить Rclone?"

    if [[ "$CONFIRM" == "y" ]]; then
        echo ""
        info "⏳ ПОЖАЛУЙСТА, ПОДОЖДИТЕ!" 
        info "Сейчас начнется установка зависимостей (Unzip, Fuse) и самого Rclone."
        echo ""

        info "Установка Rclone, Fuse и Unzip..."
        sudo apt-get install -y fuse3 unzip

        if ! command -v rclone &> /dev/null; then
            curl https://rclone.org/install.sh | sudo bash
        fi
        
        sudo sed -i 's/#user_allow_other/user_allow_other/' /etc/fuse.conf

        REMOTE_NAME="s3_backup"
        
        while true; do
            echo ""
            echo "---------------------------------------------------"
            echo "Введите данные S3 (Object Storage):"
            echo "---------------------------------------------------"
            read -p "S3 Endpoint (напр. https://storage.yandexcloud.net): " S3_ENDPOINT
            read -p "S3 Access Key: " S3_ACCESS_KEY
            read -s -p "S3 Secret Key: " S3_SECRET_KEY
            echo ""
            read -p "Имя бакета (Bucket Name): " S3_BUCKET
            
            mkdir -p /root/.config/rclone/
            rclone config create "$REMOTE_NAME" s3 provider=Other env_auth=false access_key_id="$S3_ACCESS_KEY" secret_access_key="$S3_SECRET_KEY" endpoint="$S3_ENDPOINT" acl=private --non-interactive > /dev/null 2>&1

            info "Проверка подключения к бакету '$S3_BUCKET'..."
            
            if rclone lsd "$REMOTE_NAME:$S3_BUCKET" --config /root/.config/rclone/rclone.conf > /dev/null 2>&1; then
                info "✅ Успешное подключение! Данные верны."
                break
            else
                error "❌ Ошибка подключения!" 
                echo "Скорее всего, неверные ключи, Endpoint или имя бакета."
                echo "Текст ошибки (последняя попытка):"
                rclone lsd "$REMOTE_NAME:$S3_BUCKET" --config /root/.config/rclone/rclone.conf 2>&1 | head -n 2
                
                echo ""
                ask_yes_no "Попробовать ввести данные заново?"
                if [[ "$CONFIRM" != "y" ]]; then
                    warn "Пропуск настройки Rclone."
                    return
                fi
            fi
        done
        
        mkdir -p /home/$NC_USER/.config/rclone/
        
        DEFAULT_MOUNT="$INSTALL_HOME/mnt/backup/borg"
        echo ""
        echo "Куда монтировать бакет?"
        echo "По умолчанию: $DEFAULT_MOUNT"
        
        read -p "Нажмите Enter для дефолта или введите свой путь: " CUSTOM_PATH < /dev/tty
        
        TARGET_MOUNT="${CUSTOM_PATH:-$DEFAULT_MOUNT}"
        mkdir -p "$TARGET_MOUNT"
        
        if [[ "$INSTALL_HOME" == "/home/$NC_USER" ]]; then
             chown -R "$NC_USER:$NC_USER" "$TARGET_MOUNT"
             mkdir -p "/home/$NC_USER/.config/rclone"
             cp /root/.config/rclone/rclone.conf "/home/$NC_USER/.config/rclone/rclone.conf"
             chown -R "$NC_USER:$NC_USER" "/home/$NC_USER/.config"
             USER_UID=$(id -u "$NC_USER")
             USER_GID=$(id -g "$NC_USER")
        else
             USER_UID="0"
             USER_GID="0"
        fi

        SERVICE_FILE="/etc/systemd/system/rclone-backup.service"
        info "Создание службы $SERVICE_FILE..."
        
        cat <<EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Rclone Mount for S3 Backup
AssertPathIsDirectory=$TARGET_MOUNT
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount $REMOTE_NAME:$S3_BUCKET $TARGET_MOUNT \\
    --config=/root/.config/rclone/rclone.conf \\
    --allow-other \\
    --vfs-cache-mode writes \\
    --uid=$USER_UID --gid=$USER_GID \\
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
        
        sleep 2
        if systemctl is-active --quiet rclone-backup.service; then
            RCLONE_MOUNT_POINT="$TARGET_MOUNT"
            info "✅ Rclone смонтирован в: $TARGET_MOUNT"
            log_change "RCLONE S3" "$TARGET_MOUNT" \
                "Установлен Rclone, проверено подключение, смонтирован бакет $S3_BUCKET" \
                "sudo systemctl stop rclone-backup && sudo systemctl disable rclone-backup && sudo rm $SERVICE_FILE"
        else
            error "Не удалось запустить службу rclone! Проверьте 'systemctl status rclone-backup'"
        fi
    else
        info "Пропуск настройки Rclone."
    fi
}

# --- 8. ЖЕЛЕЗО ---
check_hardware() {
    CURRENT_CPU=$(nproc)
    REQ_CPU=4
    if [ "$CURRENT_CPU" -lt "$REQ_CPU" ]; then
        warn "CPU < 4 ядер. Продолжить?"
        ask_yes_no "Подтвердить продолжение?"
        if [[ "$CONFIRM" != "y" ]]; then exit 1; fi
    fi
}

configure_memory() {
    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    CURRENT_CPU=$(nproc)
    COMPOSE_FULL_PATH="$PROJECT_DIR/$COMPOSE_FILENAME"
    
    echo ""
    info "--- НАСТРОЙКА ПАМЯТИ (PHP MEMORY LIMIT) ---"
    echo "Текущие ресурсы системы:"
    echo "  CPU: ${CURRENT_CPU} ядер"
    echo "  RAM: ${TOTAL_RAM} MB"
    echo ""
    
    if [[ "$CURRENT_CPU" -ge 4 && "$TOTAL_RAM" -ge 5800 ]]; then
         echo -e "${GREEN}РЕКОМЕНДАЦИЯ: Система мощная (4+ ядра, 6GB+ RAM).${NC}"
         echo -e "${GREEN}Рекомендуется установить 1024M или 2048M.${NC}"
    else
         echo -e "${YELLOW}РЕКОМЕНДАЦИЯ: Ресурсов мало (менее 4 ядер или 6GB RAM).${NC}"
         echo -e "${YELLOW}Рекомендуется оставить 512M (по умолчанию).${NC}"
    fi
    
    echo ""
    echo "Выберите лимит памяти:"
    echo "  1) 1024M (Для среднего объема)"
    echo "  2) 2048M (Для большого количества файлов)"
    echo "  Enter) 512M (По умолчанию)"
    
    read -p "Ваш выбор: " M < /dev/tty
    
    case "$M" in
        1) CHOSEN_MEM="1024M" ;;
        2) CHOSEN_MEM="2048M" ;;
        *) CHOSEN_MEM="512M" ;;
    esac
    
    info "Установлен лимит: $CHOSEN_MEM"

    if grep -q "NEXTCLOUD_MEMORY_LIMIT:" "$COMPOSE_FULL_PATH"; then
        sed -i "s/NEXTCLOUD_MEMORY_LIMIT: .*/NEXTCLOUD_MEMORY_LIMIT: $CHOSEN_MEM/" "$COMPOSE_FULL_PATH"
    fi
    log_change "NEXTCLOUD CONFIG" "$COMPOSE_FULL_PATH" "Память: $CHOSEN_MEM" "Edit file"
}

# --- ИСПОЛНЕНИЕ ---
update_system

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
    log_change "DOCKER" "System" "Install Docker" "apt purge..."
fi

generate_auto_key
setup_new_user      
setup_firewall
harden_ssh
install_security_tools
install_utilities   # <-- УСТАНОВКА MC
setup_rclone        
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

log_change "CONFIG" "$COMPOSE_FULL_PATH" "Скачан docker-compose" "rm file"

# --- НАСТРОЙКА ПУТЕЙ В YAML ---
info "Настройка путей в docker-compose..."

sed -i "s|NEXTCLOUD_DATADIR: /mnt/ncdata|NEXTCLOUD_DATADIR: $DATA_DIR|g" "$COMPOSE_FULL_PATH"
sed -i "s|NEXTCLOUD_MOUNT: /mnt/|NEXTCLOUD_MOUNT: $MOUNT_DIR|g" "$COMPOSE_FULL_PATH"

log_change "CONFIG" "$COMPOSE_FULL_PATH" "Paths: $DATA_DIR, $MOUNT_DIR" "Manual edit"

configure_memory

echo ""
read -p "Введите домен: " USER_DOMAIN < /dev/tty
if [[ -z "$USER_DOMAIN" ]]; then error "Пусто."; fi

SERVER_IP=$(curl -s4 https://ifconfig.me)
DOMAIN_IP=$(dig +short A "$USER_DOMAIN" | tail -n1)
if [[ -z "$DOMAIN_IP" ]]; then 
    warn "DNS не найден!"
    ask_yes_no "Продолжить?"
    if [[ "$CONFIRM" != "y" ]]; then exit 1; fi
elif [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then 
    warn "IP отличаются."
    ask_yes_no "Продолжить?"
    if [[ "$CONFIRM" != "y" ]]; then exit 1; fi
fi

if grep -q "$PLACEHOLDER" "$COMPOSE_FULL_PATH"; then
    sed -i "s/$PLACEHOLDER/$USER_DOMAIN/g" "$COMPOSE_FULL_PATH"
    log_change "CONFIG" "$COMPOSE_FULL_PATH" "Domain: $USER_DOMAIN" "Manual edit"
fi

if [[ "$INSTALL_HOME" == "/home/$NC_USER" ]]; then
    info "Назначение прав владельца пользователю $NC_USER..."
    usermod -aG docker "$NC_USER" || true
    chown -R "$NC_USER:$NC_USER" "$INSTALL_HOME"
    log_change "PERMISSIONS" "$INSTALL_HOME" "chown $NC_USER" "chown root"
fi

info "Запуск контейнеров..."
cd "$PROJECT_DIR"
sudo docker compose up -d

# --- ОТЧЕТ ---
KEY_SECTION=""
if [[ -n "$GENERATED_PRIVATE_KEY" ]]; then
KEY_SECTION="
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!! ВАШ НОВЫЙ ПРИВАТНЫЙ КЛЮЧ (OPENSSH)                 !!!
!!! СКОПИРУЙТЕ ЕГО СЕЙЧАС!                             !!!
!!! Вход: ssh -i key_file $NC_USER@$SERVER_IP
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
$GENERATED_PRIVATE_KEY
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!! ВАШ НОВЫЙ ПРИВАТНЫЙ КЛЮЧ (PuTTY .PPK)              !!!
!!! Сохраните его в файл с расширением .ppk            !!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
$GENERATED_PPK_KEY
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
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
Config Dir:   $PROJECT_DIR
Data Dir:     $DATA_DIR
Rclone Mount: $RCLONE_MOUNT_POINT
Пользователь: $NC_USER

2. ЖУРНАЛ ИЗМЕНЕНИЙ
-------------------
$CHANGELOG_BODY

3. СТАТУС ФАЕРВОЛА (UFW)
------------------------
$UFW_REPORT_INFO

4. POST-INSTALL TIPS
--------------------
Apps to install:
1. Two-Factor TOTP Provider
2. Password Policy
3. Antivirus for Files (ClamAV)
4. Suspicious Login Detection
5. Ransomware protection

==========================================================
!!! ФИНАЛЬНЫЙ ШАГ !!!
==========================================================
Панель: https://$USER_DOMAIN:8080
РЕЖИМ:  ИНКОГНИТО (PRIVATE MODE)
==========================================================
"

echo "$REPORT_TEXT" > "$PROJECT_DIR/$REPORT_FILE"
if [[ "$(pwd)" != "$PROJECT_DIR" ]]; then 
    ln -sf "$PROJECT_DIR/$REPORT_FILE" ./latest_install_report.txt
fi

clear
echo -e "${GREEN}$REPORT_TEXT${NC}"
if [[ -n "$KEY_SECTION" ]]; then echo -e "${YELLOW}$KEY_SECTION${NC}"; fi
echo ""
info "✅ Отчет сохранен: $PROJECT_DIR/$REPORT_FILE"