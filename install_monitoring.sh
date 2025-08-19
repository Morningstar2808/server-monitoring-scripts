#!/bin/bash

# =============================================================================
# Скрипт быстрой установки Node Exporter с автообнаружением Angie
# Выполняется под root (без sudo)
# =============================================================================

set -e

echo "=== Установка мониторинга сервера ==="

# Определяем Tailscale IP автоматически
TAILSCALE_IP=""
if command -v tailscale &> /dev/null; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -n1)
fi

# Если автоопределение не сработало, запрашиваем вручную
if [ -z "$TAILSCALE_IP" ]; then
    echo "Tailscale IP не найден автоматически."
    read -p "Введите IP-адрес Tailscale этого сервера: " TAILSCALE_IP
    
    # Проверяем корректность IP
    if ! [[ $TAILSCALE_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "Ошибка: Некорректный IP-адрес"
        exit 1
    fi
else
    echo "Автоматически определен Tailscale IP: $TAILSCALE_IP"
fi

# Запрашиваем уникальное имя сервера
while true; do
    read -p "Введите уникальное имя сервера (латиницей, без пробелов): " SERVER_NAME
    if [[ $SERVER_NAME =~ ^[a-zA-Z0-9_-]+$ ]]; then
        break
    else
        echo "Ошибка: Используйте только буквы, цифры, дефисы и подчеркивания"
    fi
done

# Определяем архитектуру и соответствующий суффикс
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_SUFFIX="amd64";;
    aarch64) ARCH_SUFFIX="arm64";;
    armv7l) ARCH_SUFFIX="armv7";;
    armv6l) ARCH_SUFFIX="armv6";;
    *) echo "Ошибка: Неподдерживаемая архитектура: $ARCH"; exit 1;;
esac

echo "Архитектура: $ARCH -> $ARCH_SUFFIX"

# Версия Node Exporter
NODE_EXPORTER_VER="1.9.1"
DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VER}/node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}.tar.gz"

echo "Загружаем Node Exporter версии $NODE_EXPORTER_VER..."

# Переходим во временную директорию
cd /tmp

# Загружаем Node Exporter
if ! wget -q --show-progress "$DOWNLOAD_URL"; then
    echo "Ошибка: Не удалось загрузить Node Exporter"
    exit 1
fi

# Очищаем старые файлы и распаковываем
rm -rf node_exporter-*/ 
tar -xzf "node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}.tar.gz"

# Копируем бинарный файл
cp "node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}/node_exporter" /usr/local/bin/
chmod +x /usr/local/bin/node_exporter

# Создаем системного пользователя
useradd -M -r -s /bin/false node_exporter 2>/dev/null || true
chown node_exporter:node_exporter /usr/local/bin/node_exporter

echo "Создаем systemd сервис..."

# Создаем systemd сервис
tee /etc/systemd/system/node_exporter.service > /dev/null << 'SERVICE_EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
    --web.listen-address=:9100 \
    --path.rootfs=/ \
    --collector.filesystem.mount-points-exclude='^/(sys|proc|dev|host|etc|rootfs/var/lib/docker/containers|rootfs/var/lib/docker/overlay2|rootfs/run/docker/netns|rootfs/var/lib/docker/aufs)($$|/)' \
    --collector.filesystem.fs-types-exclude='^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$$'
SyslogIdentifier=node_exporter
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Запускаем и включаем сервис
systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

# Проверяем статус
if systemctl is-active --quiet node_exporter; then
    echo "✓ Node Exporter успешно запущен"
else
    echo "✗ Ошибка запуска Node Exporter"
    systemctl status node_exporter
    exit 1
fi

# Проверяем доступность метрик
if curl -s http://localhost:9100/metrics | grep -q "node_cpu_seconds_total"; then
    echo "✓ Метрики Node Exporter доступны"
else
    echo "✗ Метрики Node Exporter недоступны"
    exit 1
fi

# Проверяем наличие и статус Angie
ANGIE_DETECTED=false
ANGIE_METRICS_PORT=""

if pgrep -x "angie" > /dev/null; then
    echo "✓ Angie обнаружен"
    ANGIE_DETECTED=true
    
    # Проверяем, настроены ли метрики Prometheus в Angie
    for port in 8080 80 443; do
        if curl -s "http://localhost:$port/prometheus" 2>/dev/null | grep -q "angie_"; then
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
tee /etc/monitoring-info.conf > /dev/null << INFO_EOF
# Информация о сервере для мониторинга
SERVER_NAME="$SERVER_NAME"
TAILSCALE_IP="$TAILSCALE_IP"
ARCH="$ARCH"
ANGIE_DETECTED="$ANGIE_DETECTED"
ANGIE_METRICS_PORT="$ANGIE_METRICS_PORT"
INSTALL_DATE="$(date -Iseconds)"
NODE_EXPORTER_VERSION="$NODE_EXPORTER_VER"
INFO_EOF

echo ""
echo "=== Установка завершена ==="
echo "Сервер: $SERVER_NAME"
echo "Tailscale IP: $TAILSCALE_IP"
echo "Архитектура: $ARCH"
echo "Node Exporter: http://$TAILSCALE_IP:9100/metrics"
if [ "$ANGIE_DETECTED" = true ] && [ -n "$ANGIE_METRICS_PORT" ]; then
    echo "Angie метрики: http://$TAILSCALE_IP:$ANGIE_METRICS_PORT/prometheus"
fi
echo ""
echo "Для добавления в центральный мониторинг выполните на сервере Prometheus:"
echo "./add_server_to_monitoring.sh $SERVER_NAME $TAILSCALE_IP $ANGIE_METRICS_PORT"
