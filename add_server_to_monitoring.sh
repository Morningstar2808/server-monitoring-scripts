#!/bin/bash

# =============================================================================
# Скрипт для добавления нового сервера в конфигурацию Prometheus
# Выполняется на центральном сервере мониторинга под root
# =============================================================================

set -e

if [ $# -lt 2 ]; then
    echo "Использование: $0 <server_name> <tailscale_ip> [angie_port]"
    echo "Пример: $0 web-server-01 100.87.187.88 8080"
    exit 1
fi

SERVER_NAME="$1"
TAILSCALE_IP="$2"
ANGIE_PORT="${3:-}"

PROMETHEUS_CONFIG="/etc/prometheus/prometheus.yml"
BACKUP_DIR="/etc/prometheus/backups"

# Создаем директорию для резервных копий
mkdir -p "$BACKUP_DIR"

# Создаем резервную копию конфигурации
BACKUP_FILE="$BACKUP_DIR/prometheus.yml.$(date +%Y%m%d_%H%M%S)"
cp "$PROMETHEUS_CONFIG" "$BACKUP_FILE"
echo "Резервная копия создана: $BACKUP_FILE"

# Проверяем корректность IP
if ! [[ $TAILSCALE_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Ошибка: Некорректный IP-адрес: $TAILSCALE_IP"
    exit 1
fi

# Проверяем, что сервер еще не добавлен
if grep -q "$SERVER_NAME" "$PROMETHEUS_CONFIG"; then
    echo "Предупреждение: Сервер $SERVER_NAME уже существует в конфигурации"
    read -p "Продолжить обновление? (y/N): " response
    if [[ ! $response =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Проверяем доступность Node Exporter
echo "Проверяем доступность Node Exporter на $TAILSCALE_IP:9100..."
if ! timeout 10 curl -s "http://$TAILSCALE_IP:9100/metrics" | grep -q "node_cpu_seconds_total"; then
    echo "Ошибка: Node Exporter недоступен на $TAILSCALE_IP:9100"
    exit 1
fi
echo "✓ Node Exporter доступен"

# Создаем новую job секцию для сервера
NEW_JOB_CONFIG="
  # $SERVER_NAME
  - job_name: '$SERVER_NAME'
    static_configs:
      - targets: ['$TAILSCALE_IP:9100']
        labels:
          server_name: '$SERVER_NAME'
          server_type: 'remote'
          environment: 'production'
    scrape_interval: 30s
    scrape_timeout: 10s"

# Проверяем и добавляем конфигурацию для Angie (если указан порт)
if [ -n "$ANGIE_PORT" ] && [ "$ANGIE_PORT" != "null" ] && [ "$ANGIE_PORT" != "" ]; then
    echo "Проверяем метрики Angie на $TAILSCALE_IP:$ANGIE_PORT..."
    if timeout 10 curl -s "http://$TAILSCALE_IP:$ANGIE_PORT/prometheus" | grep -q "angie_"; then
        echo "✓ Метрики Angie доступны"
        NEW_JOB_CONFIG="$NEW_JOB_CONFIG

  # $SERVER_NAME Angie
  - job_name: '$SERVER_NAME-angie'
    static_configs:
      - targets: ['$TAILSCALE_IP:$ANGIE_PORT']
        labels:
          server_name: '$SERVER_NAME'
          service_type: 'angie'
          environment: 'production'
    metrics_path: '/prometheus'
    scrape_interval: 30s
    scrape_timeout: 10s"
    else
        echo "⚠ Метрики Angie недоступны на порту $ANGIE_PORT"
    fi
fi

# Добавляем новую конфигурацию в файл Prometheus
if cp "$PROMETHEUS_CONFIG" /tmp/prometheus_temp.yml; then
    echo "$NEW_JOB_CONFIG" >> /tmp/prometheus_temp.yml
    
    # Проверяем синтаксис обновленной конфигурации
    if promtool check config /tmp/prometheus_temp.yml; then
        mv /tmp/prometheus_temp.yml "$PROMETHEUS_CONFIG"
        chown prometheus:prometheus "$PROMETHEUS_CONFIG"
        echo "✓ Конфигурация обновлена"
    else
        echo "✗ Ошибка в конфигурации Prometheus"
        rm -f /tmp/prometheus_temp.yml
        exit 1
    fi
else
    echo "✗ Ошибка при создании временного файла"
    exit 1
fi

# Перезагружаем конфигурацию Prometheus
if curl -X POST http://localhost:9090/-/reload; then
    echo "✓ Конфигурация Prometheus перезагружена"
else
    echo "⚠ Не удалось перезагрузить конфигурацию через API, перезапускаем сервис..."
    systemctl restart prometheus
fi

# Ждем несколько секунд и проверяем новые targets
sleep 5

echo ""
echo "=== Проверка новых targets ==="
TARGET_STATUS=$(curl -s http://localhost:9090/api/v1/targets | jq -r ".data.activeTargets[] | select(.labels.server_name==\"$SERVER_NAME\") | \"\(.labels.job): \(.health)\"")

if [ -n "$TARGET_STATUS" ]; then
    echo "$TARGET_STATUS"
    echo "✓ Сервер $SERVER_NAME успешно добавлен в мониторинг"
else
    echo "⚠ Новые targets пока не появились, проверьте через несколько минут"
fi

echo ""
echo "Добавленные конфигурации:"
echo "- Node Exporter: $SERVER_NAME -> $TAILSCALE_IP:9100"
if [ -n "$ANGIE_PORT" ] && [ "$ANGIE_PORT" != "null" ]; then
    echo "- Angie: $SERVER_NAME-angie -> $TAILSCALE_IP:$ANGIE_PORT/prometheus"
fi
echo ""
echo "Проверить статус: https://prometheus.yourdomain.com/targets"
