#!/bin/bash

# =============================================================================
# Скрипт для добавления нового сервера в конфигурацию Prometheus с file_sd_configs
# Версия 2.2.0 - добавлена информация о CrowdSec
# =============================================================================

set -e

FORCE=false
if [ "${!#}" = "--force" ]; then
    FORCE=true
    set -- "${@:1:$(($#-1))}"
fi

if [ $# -lt 2 ]; then
    echo "Использование: $0 <server_name> <tailscale_ip> [angie_port] [cadvisor_port] [--force]"
    echo "Пример: $0 remnawave 100.79.31.83 '' 9080 --force"
    exit 1
fi

SERVER_NAME="$1"
TAILSCALE_IP="$2"
ANGIE_PORT="${3:-}"
CADVISOR_PORT="${4:-}"

TARGETS_DIR="/etc/prometheus/targets"
mkdir -p "$TARGETS_DIR/node" "$TARGETS_DIR/cadvisor" "$TARGETS_DIR/angie"

NODE_FILE="$TARGETS_DIR/node/$SERVER_NAME.yml"
CADVISOR_FILE="$TARGETS_DIR/cadvisor/$SERVER_NAME.yml"
ANGIE_FILE="$TARGETS_DIR/angie/$SERVER_NAME.yml"

# Проверяем существование
if [ -f "$NODE_FILE" ] && [ "$FORCE" != true ]; then
    echo "Предупреждение: Сервер $SERVER_NAME уже существует"
    read -p "Обновить? (y/N): " response
    if [[ ! $response =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Проверки доступности
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
echo "Генерируем/обновляем YAML-файлы в $TARGETS_DIR..."

cat > "$NODE_FILE" << EOF
- targets: ['$TAILSCALE_IP:9100']
  labels:
    server_name: '$SERVER_NAME'
    service_type: 'node_exporter'
    environment: 'production'
EOF

if [ "$CADVISOR_AVAILABLE" = true ]; then
    cat > "$CADVISOR_FILE" << EOF
- targets: ['$TAILSCALE_IP:$CADVISOR_PORT']
  labels:
    server_name: '$SERVER_NAME'
    service_type: 'cadvisor_host'
    environment: 'production'
EOF
else
    rm -f "$CADVISOR_FILE"
fi

if [ "$ANGIE_AVAILABLE" = true ]; then
    cat > "$ANGIE_FILE" << EOF
- targets: ['$TAILSCALE_IP:$ANGIE_PORT']
  labels:
    server_name: '$SERVER_NAME'
    service_type: 'angie'
    environment: 'production'
EOF
else
    rm -f "$ANGIE_FILE"
fi

chown -R prometheus:prometheus "$TARGETS_DIR"
echo "✓ YAML-файлы обновлены"

# Reload Prometheus
if curl -X POST http://localhost:9090/-/reload; then
    echo "✓ Конфигурация Prometheus перезагружена"
else
    echo "⚠ Не удалось reload, перезапускаем сервис..."
    systemctl restart prometheus
fi

# Проверка targets
sleep 5
echo ""
echo "=== Проверка новых targets ==="
TARGET_STATUS=$(curl -s http://localhost:9090/api/v1/targets | jq -r ".data.activeTargets[] | select(.labels.server_name==\"$SERVER_NAME\") | \"\(.labels.job): \(.health)\"")

if [ -n "$TARGET_STATUS" ]; then
    echo "$TARGET_STATUS"
    echo "✓ Сервер $SERVER_NAME успешно добавлен/обновлён"
else
    echo "⚠ Targets пока не появились, подождите refresh_interval (1m) или проверьте логи"
fi

# Проверка CrowdSec
echo ""
echo "=== Проверка CrowdSec ==="
CROWDSEC_METRICS=$(curl -s "http://localhost:8428/api/v1/query" -d "query=cs_lapi_decision{instance=\"$SERVER_NAME\"}" 2>/dev/null | jq -r '.data.result | length')

if [ "$CROWDSEC_METRICS" -gt 0 ] 2>/dev/null; then
    echo "✓ CrowdSec метрики обнаружены ($CROWDSEC_METRICS записей)"
    echo "  Дашборд: CrowdSec Cyber Threat Insights"
else
    echo "ℹ CrowdSec метрики отсутствуют (появятся после первых alerts)"
    echo "  Метрики отправляются автоматически через HTTP push"
fi

# Финальный отчёт
echo ""
echo "Добавленные/обновлённые файлы:"
echo "- Node Exporter: $NODE_FILE"
if [ "$CADVISOR_AVAILABLE" = true ]; then echo "- cAdvisor: $CADVISOR_FILE"; fi
if [ "$ANGIE_AVAILABLE" = true ]; then echo "- Angie: $ANGIE_FILE"; fi

echo ""
echo "Проверить статус: http://localhost:9090/targets"
echo ""
echo "📊 Рекомендуемые дашборды Grafana:"
echo "- Node Exporter Full: ID 1860"
echo "- Docker Container & Host Metrics: ID 10619"
if [ "$CADVISOR_AVAILABLE" = true ]; then echo "- Docker and system monitoring: ID 893"; fi
echo "- CrowdSec Cyber Threat Insights (импортирован локально)"
