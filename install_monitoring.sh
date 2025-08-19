#!/bin/bash

# =============================================================================
# Скрипт быстрой установки Node Exporter с автообнаружением Angie
# Выполняется под root (без sudo) - ИСПРАВЛЕННАЯ ВЕРСИЯ БЕЗ ДУБЛИРОВАНИЯ
# =============================================================================

set -e

echo "=== Установка мониторинга сервера ==="

# Определяем архитектуру
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_SUFFIX="amd64";;
    aarch64) ARCH_SUFFIX="arm64";;
    armv7l) ARCH_SUFFIX="armv7";;
    armv6l) ARCH_SUFFIX="armv6";;
    *) echo "Ошибка: Неподдерживаемая архитектура: $ARCH"; exit 1;;
esac

echo "Архитектура: $ARCH -> $ARCH_SUFFIX"

# Определяем Tailscale IP автоматически
TAILSCALE_IP=""
if command -v tailscale > /dev/null 2>&1; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -n1)
fi

# Если нет Tailscale IP, пробуем основной IP интерфейса
if [ -z "$TAILSCALE_IP" ]; then
    TAILSCALE_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -n1 2>/dev/null || echo "127.0.0.1")
fi

echo "Определен IP: $TAILSCALE_IP"

# Определяем имя сервера
SERVER_NAME=""

# Проверяем, запущен ли скрипт интерактивно
if [ -t 0 ]; then
    # Интерактивный режим - запрашиваем имя
    while true; do
        read -p "Введите уникальное имя сервера (латиницей, без пробелов): " SERVER_NAME
        if [[ $SERVER_NAME =~ ^[a-zA-Z0-9_-]+$ ]]; then
            break
        else
            echo "Ошибка: Используйте только буквы, цифры, дефисы и подчеркивания"
        fi
    done
else
    # Pipe режим - автоматически генерируем имя
    if [ -f /etc/hostname ]; then
        SERVER_NAME=$(cat /etc/hostname | tr -cd 'a-zA-Z0-9_-' | head -c 15)
    else
        SERVER_NAME="server-$(date +%s | tail -c 6)"
    fi
    
    # Проверяем корректность и исправляем если нужно
    if ! [[ $SERVER_NAME =~ ^[a-zA-Z0-9_-]+$ ]] || [ -z "$SERVER_NAME" ]; then
        SERVER_NAME="server-$(date +%s | tail -c 6)"
    fi
    
    echo "Автоматически определено имя сервера: $SERVER_NAME"
fi

# Останавливаем старый Node Exporter если есть
systemctl stop node_exporter 2>/dev/null || true
systemctl disable node_exporter 2>/dev/null || true

# Версия Node Exporter
NODE_EXPORTER_VER="1.9.1"
DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VER}/node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}.tar.gz"

echo "Загружаем Node Exporter версии $NODE_EXPORTER_VER..."

# Переходим во временную директорию
cd /tmp

# Очищаем старые файлы
rm -rf node_exporter-*/
rm -f node_exporter-*.tar.gz

# Загружаем Node Exporter
if ! wget -q --show-progress "$DOWNLOAD_URL"; then
    echo "Ошибка: Не удалось загрузить Node Exporter"
    echo "URL: $DOWNLOAD_URL"
    exit 1
fi

# Распаковываем
echo "Распаковка архива..."
tar -xzf "node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}.tar.gz"

# Копируем бинарный файл
echo "Установка Node Exporter..."
cp "node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}/node_exporter" /usr/local/bin/
chmod +x /usr/local/bin/node_exporter

# Создаем системного пользователя
useradd -M -r -s /bin/false node_exporter 2>/dev/null || true
chown node_exporter:node_exporter /usr/local/bin/node_exporter

echo "Создаем systemd сервис..."

# Создаем простой systemd сервис
cat > /etc/systemd/system/node_exporter.service << 'SERVICE_EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
SyslogIdentifier=node_exporter
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Запускаем и включаем сервис
echo "Запуск Node Exporter..."
systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

# Ждем запуска
echo "Ожидание запуска сервиса..."
sleep 5

# Проверяем статус
if systemctl is-active --quiet node_exporter; then
    echo "✓ Node Exporter успешно запущен"
else
    echo "✗ Ошибка запуска Node Exporter"
    echo "Статус сервиса:"
    systemctl status node_exporter --no-pager
    echo "Логи:"
    journalctl -u node_exporter -n 10 --no-pager
    exit 1
fi

# Проверяем порт
echo "Проверка порта 9100..."
if ss -tlnp | grep -q ":9100"; then
    echo "✓ Node Exporter слушает на порту 9100"
else
    echo "✗ Node Exporter не слушает на порту 9100"
    ss -tlnp | grep node_exporter || echo "Процесс node_exporter не найден"
    exit 1
fi

# Проверяем доступность метрик (исправленная проверка)
echo "Проверка доступности метрик..."
for i in {1..5}; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9100/metrics 2>/dev/null)
    if [ "$HTTP_CODE" = "200" ]; then
        echo "✓ Метрики Node Exporter доступны (HTTP $HTTP_CODE)"
        break
    else
        echo "Попытка $i/5: метрики недоступны (HTTP $HTTP_CODE), ждем..."
        sleep 3
    fi
    
    if [ $i -eq 5 ]; then
        echo "✗ Метрики Node Exporter недоступны после 5 попыток"
        echo "Отладочная информация:"
        curl -v http://localhost:9100/metrics 2>&1 | head -10
        exit 1
    fi
done

# Проверяем наличие и статус Angie
ANGIE_DETECTED=false
ANGIE_METRICS_PORT=""

if pgrep -x "angie" > /dev/null; then
    echo "✓ Angie обнаружен"
    ANGIE_DETECTED=true
    
    # Проверяем, настроены ли метрики Prometheus в Angie
    for port in 8080 80 443; do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/prometheus" 2>/dev/null)
        if [ "$HTTP_CODE" = "200" ]; then
            ANGIE_METRICS_PORT=$port
            echo "✓ Метрики Angie доступны на порту $port"
            break
        fi
    done
    
    if [ -z "$ANGIE_METRICS_PORT" ]; then
        echo "⚠ Angie найден, но метрики Prometheus не настроены"
        echo "  Для включения метрик добавьте в конфигурацию Angie:"
        echo "  location /prometheus { prometheus all; }"
    fi
else
    echo "ℹ Angie не обнаружен"
fi

# Очищаем временные файлы
rm -rf /tmp/node_exporter-*

# Создаем файл с информацией о сервере для центрального мониторинга
cat > /etc/monitoring-info.conf << INFO_EOF
# Информация о сервере для мониторинга
SERVER_NAME="$SERVER_NAME"
TAILSCALE_IP="$TAILSCALE_IP"
ARCH="$ARCH"
ANGIE_DETECTED="$ANGIE_DETECTED"
ANGIE_METRICS_PORT="$ANGIE_METRICS_PORT"
INSTALL_DATE="$(date -Iseconds)"
NODE_EXPORTER_VERSION="$NODE_EXPORTER_VER"
INFO_EOF

# ЕДИНСТВЕННОЕ ФИНАЛЬНОЕ СООБЩЕНИЕ (без дублирования)
echo ""
echo "=================================================="
echo "🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!"
echo "=================================================="
echo "Сервер: $SERVER_NAME"
echo "IP адрес: $TAILSCALE_IP"
echo "Архитектура: $ARCH ($ARCH_SUFFIX)"
echo "Node Exporter: http://$TAILSCALE_IP:9100/metrics"
if [ "$ANGIE_DETECTED" = true ] && [ -n "$ANGIE_METRICS_PORT" ]; then
    echo "Angie метрики: http://$TAILSCALE_IP:$ANGIE_METRICS_PORT/prometheus"
fi
echo ""
echo "📋 ДЛЯ ДОБАВЛЕНИЯ В ЦЕНТРАЛЬНЫЙ МОНИТОРИНГ:"
echo "На сервере Prometheus выполните:"
echo ""
if [ -n "$ANGIE_METRICS_PORT" ]; then
    echo "curl -fsSL https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/add | bash -s \"$SERVER_NAME\" \"$TAILSCALE_IP\" \"$ANGIE_METRICS_PORT\""
else
    echo "curl -fsSL https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/add | bash -s \"$SERVER_NAME\" \"$TAILSCALE_IP\""
fi
echo ""
echo "✅ Готово! Сервер готов к мониторингу."
