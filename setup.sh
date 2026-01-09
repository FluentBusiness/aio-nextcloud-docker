#!/bin/bash

# --- НАСТРОЙКИ ---
# Ваша прямая ссылка на docker-compose.yaml
DEFAULT_YAML_URL="https://raw.githubusercontent.com/FluentBusiness/aio-nextcloud-docker/refs/heads/master/docker-compose.yaml"
COMPOSE_FILE="docker-compose.yaml"
PLACEHOLDER="YOUR_DOMAIN" # Скрипт будет искать это слово и менять на ваш домен

# Аргумент запуска (если есть) перекрывает ссылку по умолчанию
YAML_URL="${1:-$DEFAULT_YAML_URL}"

set -e

# Цвета для удобства
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- 1. ОБНОВЛЕНИЕ СИСТЕМЫ ---
update_system() {
    info "Обновление сервера (apt update & upgrade)..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get -qqy update
    # Обновляем пакеты, автоматически оставляя старые конфиги при конфликтах
    sudo -E apt-get -qqy -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    sudo apt-get -y autoremove
    info "Сервер обновлен."
}
update_system

# --- 2. ПРОВЕРКА ИНСТРУМЕНТОВ ---
info "Проверка зависимостей..."
if ! command -v curl &> /dev/null; then sudo apt-get install -y curl; fi

PACKAGES="apt-transport-https ca-certificates software-properties-common gnupg dnsutils"
if ! dpkg -s $PACKAGES >/dev/null 2>&1; then
     sudo apt-get install -y $PACKAGES
fi

# --- 3. УСТАНОВКА DOCKER ---
if ! command -v docker &> /dev/null; then
    info "Установка Docker..."
    sudo install -m 0755 -d /etc/apt/keyrings
    [ ! -f /etc/apt/keyrings/docker.gpg ] && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=""$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      ""$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    # Симлинк для совместимости
    sudo ln -sfv /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
else
    info "Docker уже установлен."
fi

# --- 4. СКАЧИВАНИЕ YAML ---
info "Скачивание конфигурации..."
info "URL: $YAML_URL"

if curl --output /dev/null --silent --head --fail "$YAML_URL"; then
    curl -L "$YAML_URL" -o "$COMPOSE_FILE"
else
    error "Не удалось скачать файл! Проверьте, что ссылка $YAML_URL доступна публично."
fi

# --- 5. ВВОД ДОМЕНА ---
echo ""
echo "====================================================="
echo " Введите ваш домен (например: cloud.mysite.com)"
echo "====================================================="
read -p "Домен: " USER_DOMAIN < /dev/tty

if [[ -z "$USER_DOMAIN" ]]; then error "Домен не может быть пустым."; fi

# --- 6. ПРОВЕРКА DNS ---
info "Проверка DNS записей..."
SERVER_IP=$(curl -s4 https://ifconfig.me)
DOMAIN_IP=$(dig +short A "$USER_DOMAIN" | tail -n1)

if [[ -z "$DOMAIN_IP" ]]; then
    echo ""
    warn "!!! ОШИБКА: У домена $USER_DOMAIN нет A-записи (IP не найден) !!!"
    warn "Caddy не сможет получить SSL сертификат."
    read -p "Продолжить на свой страх и риск? (y/N): " CONFIRM < /dev/tty
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then exit 1; fi
elif [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
    echo ""
    warn "!!! IP не совпадают !!!"
    warn "Ваш сервер: $SERVER_IP"
    warn "Домен направлен на: $DOMAIN_IP"
    echo "Если это Cloudflare Proxy (оранжевое облако) — всё ок."
    read -p "Продолжить? (y/N): " CONFIRM < /dev/tty
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then exit 1; fi
else
    info "DNS корректен (IP совпадают)."
fi

# --- 7. НАСТРОЙКА И ЗАПУСК ---
info "Настройка конфигурации..."

# Проверка наличия заглушки
if grep -q "$PLACEHOLDER" "$COMPOSE_FILE"; then
    sed -i "s/$PLACEHOLDER/$USER_DOMAIN/g" "$COMPOSE_FILE"
    info "Домен $USER_DOMAIN успешно прописан в конфиг."
else
    warn "---------------------------------------------------------------------"
    warn "ВНИМАНИЕ: В скачанном файле не найдена строка '$PLACEHOLDER'!"
    warn "Скрипт не смог автоматически заменить домен."
    warn "Убедитесь, что в файле на GitHub стоит $PLACEHOLDER в Caddyfile."
    warn "---------------------------------------------------------------------"
    read -p "Нажмите Enter, чтобы продолжить (или Ctrl+C для отмены)..." < /dev/tty
fi

# Создаем папки для данных, чтобы избежать проблем с правами root
if grep -q "NEXTCLOUD_DATADIR: /mnt/ncdata" "$COMPOSE_FILE"; then
    sudo mkdir -p /mnt/ncdata
fi

info "Запуск контейнеров..."
sudo docker compose up -d

info "Установка завершена!"
info "Панель AIO: https://$USER_DOMAIN:8080"