#!/bin/bash

# =============================================================================
# Скрипт для добавления нового сервера в конфигурацию Prometheus с file_sd_configs
# =============================================================================

set -e

FORCE=false
if [ "${!#}" = "--force" ]; then
    FORCE=true
    set -- "${@:1:$(($#-1))}"
fi

if [ $# -lt 2 ]; then
    echo "Использование: $0 <server_name> <tailscale_ip> [angie_port] [cadvisor_port] [--force]"
    echo "Пример: $0 remnawave 100.79.31.83 '' 8080 --force"
    exit 1
fi

SERVER_NAME="$1"
TAILSCALE_IP="$2"
ANGIE_PORT="${3:-}"
CADVISOR_PORT="${4:-8080}"

TARGETS_DIR="/etc/prometheus/targets"
mkdir -p "$TARGETS_DIR/node" "$TARGETS_DIR/cadvisor" "$TARGETS_DIR/angie"

# Проверяем, существует ли файл (для force)
NODE_FILE="$TARGETS_DIR/node/$SERVER_NAME.yml"
if [ -f "$NODE_FILE" ] && [ "$FORCE" != true ]; then
    echo "Предупреждение: Сервер $SERVER_NAME уже существует"
    read -p "Обновить? (y/N): " response
    if [[ ! $response =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Проверки доступности (как раньше)
echo "Проверяем доступность сервисов на $TAILSCALE_IP..."

echo "Проверяем Node Exporter на $TAILSCALE_IP:9100..."
if ! timeout 10 curl -s "http://$TAILSCALE_IP:9100/metrics" | grep -q "node_cpu_seconds_total"; then
    echo "Ошибка: Node Exporter недоступен"
    exit 1
fi
echo "✓ Node Exporter доступен"

CADVISOR_AVAILABLE=false
if [ -n "$CADVISOR_PORT" ]; then
    echo "Проверяем cAdvisor на $TAILSCALE_IP:$CADVISOR_PORT..."
    if timeout 10 curl -s "http://$TAILSCALE_IP:$CADVISOR_PORT/metrics" | grep -q "container_cpu_usage_seconds_total"; then
        CADVISOR_AVAILABLE=true
        echo "✓ cAdvisor доступен"
    else
        echo "⚠ cAdvisor недоступен (не будет добавлен)"
    fi
fi

ANGIE_AVAILABLE=false
if [ -n "$ANGIE_PORT" ]; then
    echo "Проверяем Angie на $TAILSCALE_IP:$ANGIE_PORT..."
    if timeout 10 curl -s "http://$TAILSCALE_IP:$ANGIE_PORT/prometheus" | grep -q "angie_"; then
        ANGIE_AVAILABLE=true
        echo "✓ Angie доступен"
    else
        echo "⚠ Angie недоступен (не будет добавлен)"
    fi
fi

# Генерация YAML-файлов
cat > "$NODE_FILE" << EOF
- targets: ['$TAILSCALE_IP:9100']
  labels:
    server_name: '$SERVER_NAME'
    service_type: 'node_exporter'
    environment: 'production'
EOF

if [ "$CADVISOR_AVAILABLE" = true ]; then
    CADVISOR_FILE="$TARGETS_DIR/cadvisor/$SERVER_NAME.yml"
    cat > "$CADVISOR_FILE" << EOF
- targets: ['$TAILSCALE_IP:$CADVISOR_PORT']
  labels:
    server_name: '$SERVER_NAME'
    service_type: 'cadvisor_host'
    environment: 'production'
EOF
fi

if [ "$ANGIE_AVAILABLE" = true ]; then
    ANGIE_FILE="$TARGETS_DIR/angie/$SERVER_NAME.yml"
    cat > "$ANGIE_FILE" << EOF
- targets: ['$TAILSCALE_IP:$ANGIE_PORT']
  labels:
    server_name: '$SERVER_NAME'
    service_type: 'angie'
    environment: 'production'
EOF
fi

chown -R prometheus
