#!/bin/bash

# --- НАСТРОЙКИ ---
DEFAULT_YAML_URL="https://raw.githubusercontent.com/FluentBusiness/aio-nextcloud-docker/refs/heads/master/docker-compose.yaml"
COMPOSE_FILE="docker-compose.yaml"
REPORT_FILE="install_report.txt"
PLACEHOLDER="YOUR_DOMAIN" 
SUDO_USER="nextcloud"

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

# Глобальные переменные для отчета
SSH_BACKUP_NAME="Не создавался"
GENERATED_PRIVATE_KEY=""
KEY_CREATED_MSG="Нет"

# Переменные состояния (для наполнения отчета)
LOG_USER="Без изменений"
LOG_SSH="Без изменений"
LOG_UFW="Без изменений"
LOG_TOOLS="Без изменений"
LOG_DOCKER_CFG="Без изменений"

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
        ssh-keygen -t ed25519 -C "generated-by-install-script" -f ./temp_access_key -N "" -q
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        cat ./temp_access_key.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        GENERATED_PRIVATE_KEY=$(cat ./temp_access_key)
        KEY_CREATED_MSG="Да"
        rm ./temp_access_key ./temp_access_key.pub
        info "✅ Ключ создан."
    fi
}

# --- 3. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ---
setup_new_user() {
    echo ""
    info "--- БЕЗОПАСНОСТЬ ПОЛЬЗОВАТЕЛЯ ---"
    read -p "Создать юзера '$SUDO_USER' и отключить Root? (y/N): " CONFIRM < /dev/tty
    
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        if id "$SUDO_USER" &>/dev/null; then
            warn "Пользователь уже есть."
            LOG_USER="Пользователь $SUDO_USER уже существовал. Root не отключали во избежание конфликтов."
        else
            info "Создание $SUDO_USER..."
            adduser --gecos "" "$SUDO_USER"
            usermod -aG sudo "$SUDO_USER"
            if getent group docker > /dev/null; then usermod -aG docker "$SUDO_USER"; fi

            mkdir -p "/home/$SUDO_USER/.ssh"
            if [ -f ~/.ssh/authorized_keys ]; then
                cp ~/.ssh/authorized_keys "/home/$SUDO_USER/.ssh/"
                chmod 700 "/home/$SUDO_USER/.ssh"
                chmod 600 "/home/$SUDO_USER/.ssh/authorized_keys"
                chown -R "$SUDO_USER:$SUDO_USER" "/home/$SUDO_USER/.ssh"
            fi

            # Отключение Root
            passwd -l root
            
            LOG_USER="
   1. Создан пользователь: $SUDO_USER
   2. Root заблокирован (passwd -l root)
   3. Ключи скопированы от текущего пользователя.
   
   ОТКАТ (Как вернуть):
   1. sudo passwd -u root (Разблокировать пароль root)
   2. sudo deluser --remove-home $SUDO_USER (Удалить нового юзера)"
            
            info "✅ Пользователь создан."
        fi
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
        for port in 22 80 443 8080 3478; do
            sudo ufw allow "$port"/tcp
        done
        sudo ufw allow 443/udp
        sudo ufw allow 3478/udp

        echo "y" | sudo ufw enable
        
        LOG_UFW="
   Файл: Системные правила iptables (через UFW)
   Действие: Сброс правил, блокировка входящих, открытие портов 22, 80, 443, 8080, 3478.
   
   ОТКАТ (Как вернуть):
   sudo ufw disable (Выключить фаервол)
   или sudo ufw reset (Сбросить все правила)"
        
        info "✅ UFW активен."
    fi
}

# --- 5. SSH ---
harden_ssh() {
    echo ""
    info "--- SSH ---"
    read -p "Отключить вход по паролю и Root Login? (y/N): " CONFIRM < /dev/tty
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        TARGET_HOME="/root"
        if [[ "$LOG_USER" != "Без изменений" ]] && [[ "$LOG_USER" != *"уже существовал"* ]]; then
            TARGET_HOME="/home/$SUDO_USER"
        fi
        
        if [ ! -s "$TARGET_HOME/.ssh/authorized_keys" ]; then
            error "ОШИБКА: Нет ключей в $TARGET_HOME! Отмена."
            return
        fi
        
        SSH_BACKUP_NAME="/etc/ssh/sshd_config.bak.$(date +%F_%R)"
        sudo cp /etc/ssh/sshd_config "$SSH_BACKUP_NAME"
        
        sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config
        
        if [[ "$LOG_USER" != "Без изменений" ]]; then
             sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
             if ! grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then echo "PermitRootLogin no" | sudo tee -a /etc/ssh/sshd_config; fi
        fi
        
        sudo service ssh restart
        
        LOG_SSH="
   Файл: /etc/ssh/sshd_config
   Бэкап: $SSH_BACKUP_NAME
   Изменения:
     - PasswordAuthentication no
     - PermitRootLogin no (если создавался юзер)
   
   ОТКАТ (Как вернуть):
   sudo cp $SSH_BACKUP_NAME /etc/ssh/sshd_config
   sudo service ssh restart"
   
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
        
        LOG_TOOLS="
   1. Fail2Ban:
      Создан файл: /etc/fail2ban/jail.local
      ОТКАТ: sudo rm /etc/fail2ban/jail.local && sudo systemctl restart fail2ban
      
   2. Unattended Upgrades:
      Создан файл: /etc/apt/apt.conf.d/20auto-upgrades
      ОТКАТ: sudo rm /etc/apt/apt.conf.d/20auto-upgrades"
      
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
    if [ "$TOTAL_RAM" -lt 3800 ]; then CHOSEN_MEM="512M"; else
        CHOSEN_MEM="1024M" # Default
        echo "RAM: ${TOTAL_RAM}MB. 1) 1024M 2) 2048M"
        read -p "Выбор: " M < /dev/tty
        if [[ "$M" == "2" ]]; then CHOSEN_MEM="2048M"; fi
    fi
    if grep -q "NEXTCLOUD_MEMORY_LIMIT:" "$COMPOSE_FILE"; then
        sed -i "s/NEXTCLOUD_MEMORY_LIMIT: .*/NEXTCLOUD_MEMORY_LIMIT: $CHOSEN_MEM/" "$COMPOSE_FILE"
    fi
    LOG_DOCKER_CFG="$LOG_DOCKER_CFG\n   - Память установлена в: $CHOSEN_MEM"
}

# --- ИСПОЛНЕНИЕ ---
update_system

# Docker
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

# Загрузка
info "Загрузка конфига..."
if curl --output /dev/null --silent --head --fail "$YAML_URL"; then
    curl -L "$YAML_URL" -o "$COMPOSE_FILE"
else error "Ошибка загрузки!"; fi

configure_memory

echo ""
read -p "Введите домен: " USER_DOMAIN < /dev/tty
if [[ -z "$USER_DOMAIN" ]]; then error "Пусто."; fi

# DNS
SERVER_IP=$(curl -s4 https://ifconfig.me)
DOMAIN_IP=$(dig +short A "$USER_DOMAIN" | tail -n1)
if [[ -z "$DOMAIN_IP" ]]; then warn "DNS не найден! Продолжить? (y/N)"; read C < /dev/tty; if [[ "$C" != "y" ]]; then exit 1; fi
elif [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then warn "IP отличаются. Продолжить? (y/N)"; read C < /dev/tty; if [[ "$C" != "y" ]]; then exit 1; fi; fi

if grep -q "$PLACEHOLDER" "$COMPOSE_FILE"; then
    sed -i "s/$PLACEHOLDER/$USER_DOMAIN/g" "$COMPOSE_FILE"
    LOG_DOCKER_CFG="   - Домен заменен на: $USER_DOMAIN"
fi
if grep -q "NEXTCLOUD_DATADIR: /mnt/ncdata" "$COMPOSE_FILE"; then sudo mkdir -p /mnt/ncdata; fi

info "Запуск контейнеров..."
sudo docker compose up -d

# --- ФОРМИРОВАНИЕ ОТЧЕТА ---
CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")
KEY_SECTION=""
if [[ -n "$GENERATED_PRIVATE_KEY" ]]; then
KEY_SECTION="
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!! ВАШ НОВЫЙ ПРИВАТНЫЙ КЛЮЧ (ID_ED25519)              !!!
!!! СКОПИРУЙТЕ ЕГО СЕЙЧАС!                             !!!
!!! Команда для входа: ssh -i key_file $SUDO_USER@$SERVER_IP
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

1. ОСНОВНЫЕ ДАННЫЕ
------------------
Домен:       $USER_DOMAIN
IP сервера:  $SERVER_IP
Панель AIO:  https://$USER_DOMAIN:8080
Конфиг:      $(pwd)/$COMPOSE_FILE

2. ЖУРНАЛ ИЗМЕНЕНИЙ И ИНСТРУКЦИИ ПО ОТКАТУ
------------------------------------------

[A] ПОЛЬЗОВАТЕЛИ И ROOT
$LOG_USER

[B] SSH КОНФИГУРАЦИЯ
$LOG_SSH

[C] ФАЕРВОЛ (UFW)
$LOG_UFW

[D] ДОП. ИНСТРУМЕНТЫ (Fail2Ban, AutoUpdate)
$LOG_TOOLS

[E] DOCKER COMPOSE ($COMPOSE_FILE)
$LOG_DOCKER_CFG
   ОТКАТ: Отредактируйте файл вручную (nano $COMPOSE_FILE)
          и запустите 'sudo docker compose up -d'

3. НОВЫЙ КЛЮЧ
-------------
Создавался ли новый ключ? $KEY_CREATED_MSG

4. РЕКОМЕНДАЦИИ ПО НАСТРОЙКЕ БЕЗОПАСНОСТИ (POST-INSTALL)
--------------------------------------------------------
Установите эти модули в разделе 'Apps' веб-интерфейса Nextcloud:

   1. Two-Factor TOTP Provider (2FA)
      ЗАЧЕМ: Защита от кражи паролей.
      ДОК: https://docs.nextcloud.com/server/latest/user_manual/en/user_2fa.html

   2. Password Policy
      ЗАЧЕМ: Принуждение к сложным паролям.
      ДОК: https://apps.nextcloud.com/apps/password_policy

   3. Antivirus for Files (ClamAV)
      ЗАЧЕМ: Сканирование файлов (включите в панели AIO).
      ДОК: https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/antivirus_configuration.html

   4. Suspicious Login Detection
      ЗАЧЕМ: ИИ-блокировка подозрительных IP.
      ДОК: https://apps.nextcloud.com/apps/suspicious_login

   5. Ransomware protection
      ЗАЧЕМ: Блокировка расширений вирусов-шифровальщиков.
      ДОК: https://apps.nextcloud.com/apps/ransomware_protection

==========================================================
"

echo "$REPORT_TEXT" > "$REPORT_FILE"
clear
echo -e "${GREEN}$REPORT_TEXT${NC}"
if [[ -n "$KEY_SECTION" ]]; then echo -e "${YELLOW}$KEY_SECTION${NC}"; fi
echo ""
info "✅ Подробный отчет сохранен в: $(pwd)/$REPORT_FILE"