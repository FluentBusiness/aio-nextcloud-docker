#!/bin/bash

# --- НАСТРОЙКИ ---
DEFAULT_YAML_URL="https://raw.githubusercontent.com/FluentBusiness/aio-nextcloud-docker/refs/heads/master/docker-compose.yaml"
COMPOSE_FILENAME="docker-compose.yaml"
# Имя отчета будет сгенерировано динамически ниже
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

# --- ПЕРЕМЕННЫЕ ДЛЯ ОТЧЕТА ---
# Генерируем уникальное имя файла с датой и временем
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
REPORT_FILE="report_${TIMESTAMP}.txt"

# Переменная, куда будем складывать весь лог изменений
CHANGELOG_BODY=""

# Функция для записи изменений в лог
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
KEY_CREATED_MSG="Нет"

# --- 1. ОБНОВЛЕНИЕ ---
update_system() {
    info "Обновление сервера..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get -qqy update
    sudo -E apt-get -qqy -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    sudo apt-get -y autoremove
    info "Сервер обновлен."
    
    log_change "SYSTEM UPDATE" "System Packages" \
        "Выполнено apt update & upgrade" \
        "Откат системных обновлений сложен и обычно не требуется."
}

# --- 2. ГЕНЕРАЦИЯ КЛЮЧА ---
generate_auto_key() {
    echo ""
    info "--- АВТО-СОЗДАНИЕ КЛЮЧА ДОСТУПА ---"
    read -p "Создать новый SSH-ключ? (y/N): " CONFIRM < /dev/tty

    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        ssh-keygen -t ed25519 -C "generated-by-install-script" -f ./temp_access_key -N "" -q
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        cat ./temp_access_key.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        GENERATED_PRIVATE_KEY=$(cat ./temp_access_key)
        KEY_CREATED_MSG="Да"
        rm ./temp_access_key ./temp_access_key.pub
        info "✅ Ключ создан."
        
        log_change "SSH KEY" "~/.ssh/authorized_keys" \
            "Добавлен новый публичный ключ (Ed25519)" \
            "Отредактируйте ~/.ssh/authorized_keys и удалите последнюю строку."
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
            log_change "USER" "/etc/passwd" \
                "Пользователь $NC_USER уже существовал. Изменений не вносилось." \
                "-"
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
            info "✅ Пользователь создан, ключи скопированы, Root отключен."
            
            log_change "USER & SECURITY" "/etc/passwd & /etc/shadow" \
                "1. Создан юзер $NC_USER (sudo). 2. Пароль root заблокирован." \
                "sudo passwd -u root (разблок. root); sudo deluser --remove-home $NC_USER"
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
        
        log_change "USER" "-" "Используется текущий пользователь (Root)" "-"
    fi
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
        for port in 22 80 443 8080 3478; do sudo ufw allow "$port"/tcp; done
        sudo ufw allow 443/udp
        sudo ufw allow 3478/udp
        echo "y" | sudo ufw enable
        info "✅ UFW активен."
        
        log_change "FIREWALL" "UFW (iptables)" \
            "Включен UFW. Открыты порты: 22, 80, 443, 8080, 3478." \
            "sudo ufw disable (Выключить) ИЛИ sudo ufw reset (Сбросить правила)"
    fi
}

# --- 5. SSH HARDENING ---
harden_ssh() {
    echo ""
    info "--- SSH ---"
    read -p "Отключить вход по паролю и Root Login? (y/N): " CONFIRM < /dev/tty
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        TARGET_SSH_DIR="/root/.ssh"
        if [[ "$INSTALL_HOME" == "/home/$NC_USER" ]]; then TARGET_SSH_DIR="/home/$NC_USER/.ssh"; fi
        
        if [ ! -s "$TARGET_SSH_DIR/authorized_keys" ]; then
            error "ОШИБКА: Нет ключей в $TARGET_SSH_DIR! Отмена действия."
            return
        fi
        
        SSH_BACKUP_NAME="/etc/ssh/sshd_config.bak.$(date +%F_%R)"
        sudo cp /etc/ssh/sshd_config "$SSH_BACKUP_NAME"
        
        sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config
        
        CHANGE_DESC="PasswordAuthentication -> no."
        
        if [[ "$INSTALL_HOME" == "/home/$NC_USER" ]]; then
             sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
             if ! grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then echo "PermitRootLogin no" | sudo tee -a /etc/ssh/sshd_config; fi
             CHANGE_DESC="$CHANGE_DESC Также PermitRootLogin -> no."
        fi
        
        sudo service ssh restart
        info "✅ SSH защищен."
        
        log_change "SSH CONFIG" "/etc/ssh/sshd_config" \
            "$CHANGE_DESC (Бэкап создан: $SSH_BACKUP_NAME)" \
            "sudo cp $SSH_BACKUP_NAME /etc/ssh/sshd_config && sudo service ssh restart"
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
        info "✅ Инструменты установлены."
        
        log_change "SECURITY PACKAGES" "/etc/fail2ban/jail.local" \
            "Установлены Fail2ban (защита SSH) и Unattended-Upgrades." \
            "sudo apt remove fail2ban unattended-upgrades"
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
    log_change "NEXTCLOUD CONFIG" "$COMPOSE_FULL_PATH" \
        "Установлен лимит памяти PHP: $CHOSEN_MEM" \
        "Отредактируйте файл и измените NEXTCLOUD_MEMORY_LIMIT"
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
    log_change "DOCKER" "System Packages" "Установлен Docker и Docker Compose" "sudo apt purge docker-ce docker-ce-cli"
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

log_change "CONFIG FILE" "$COMPOSE_FULL_PATH" \
    "Скачан свежий docker-compose.yaml с GitHub" \
    "Удалить файл: rm $COMPOSE_FULL_PATH"

# --- НАСТРОЙКА ПУТЕЙ В YAML ---
info "Настройка путей в docker-compose..."

sed -i "s|NEXTCLOUD_DATADIR: /mnt/ncdata|NEXTCLOUD_DATADIR: $DATA_DIR|g" "$COMPOSE_FULL_PATH"
sed -i "s|NEXTCLOUD_MOUNT: /mnt/|NEXTCLOUD_MOUNT: $MOUNT_DIR|g" "$COMPOSE_FULL_PATH"

log_change "NEXTCLOUD CONFIG" "$COMPOSE_FULL_PATH" \
    "Изменены пути: DATADIR -> $DATA_DIR, MOUNT -> $MOUNT_DIR" \
    "Отредактируйте файл вручную"

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
    log_change "NEXTCLOUD CONFIG" "$COMPOSE_FULL_PATH" "Установлен домен: $USER_DOMAIN" "Редактирование файла"
fi

# Назначение прав пользователю
if [[ "$INSTALL_HOME" == "/home/$NC_USER" ]]; then
    info "Назначение прав владельца пользователю $NC_USER..."
    usermod -aG docker "$NC_USER" || true
    chown -R "$NC_USER:$NC_USER" "$INSTALL_HOME"
    log_change "PERMISSIONS" "$INSTALL_HOME" \
        "Права на папку переданы пользователю $NC_USER" \
        "chown -R root:root $INSTALL_HOME"
fi

info "Запуск контейнеров..."
cd "$PROJECT_DIR"
sudo docker compose up -d

# --- ФОРМИРОВАНИЕ ИТОГОВОГО ОТЧЕТА ---
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
 ОТЧЕТ О ЗАПУСКЕ СКРИПТА (CHANGELOG)
 Дата запуска: $TIMESTAMP
 Файл отчета:  $PROJECT_DIR/$REPORT_FILE
==========================================================

1. ОБЩАЯ ИНФОРМАЦИЯ
-------------------
Домен:        $USER_DOMAIN
IP сервера:   $SERVER_IP
Папка конфига: $PROJECT_DIR
Папка данных:  $DATA_DIR
Пользователь:  $NC_USER

2. ДЕТАЛЬНЫЙ ЖУРНАЛ ИЗМЕНЕНИЙ (ЧТО БЫЛО СДЕЛАНО)
------------------------------------------------
Ниже перечислены все изменения, внесенные этим запуском скрипта,
и инструкции по их отмене (Revert).
$CHANGELOG_BODY

3. РЕКОМЕНДАЦИИ ПО БЕЗОПАСНОСТИ (POST-INSTALL)
----------------------------------------------
Включите в Nextcloud Apps:
1. Two-Factor TOTP Provider
2. Password Policy
3. Antivirus for Files (ClamAV)
4. Suspicious Login Detection
5. Ransomware protection

==========================================================
!!! ФИНАЛЬНЫЙ ШАГ !!!
==========================================================
Панель управления: https://$USER_DOMAIN:8080
ОТКРЫВАЙТЕ В РЕЖИМЕ ИНКОГНИТО!
==========================================================
"

# Сохраняем отчет (Уникальный файл для каждого запуска)
echo "$REPORT_TEXT" > "$PROJECT_DIR/$REPORT_FILE"

# Если мы запускали не из папки проекта, делаем симлинк на последний отчет
if [[ "$(pwd)" != "$PROJECT_DIR" ]]; then 
    ln -sf "$PROJECT_DIR/$REPORT_FILE" ./latest_install_report.txt
fi

clear
echo -e "${GREEN}$REPORT_TEXT${NC}"
if [[ -n "$KEY_SECTION" ]]; then echo -e "${YELLOW}$KEY_SECTION${NC}"; fi
echo ""
info "✅ Отчет сохранен в файл: $PROJECT_DIR/$REPORT_FILE"