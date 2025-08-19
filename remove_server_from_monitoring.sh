#!/bin/bash

if [ $# -ne 1 ]; then
    echo "Использование: $0 <server_name>"
    exit 1
fi

SERVER_NAME="$1"
PROMETHEUS_CONFIG="/etc/prometheus/prometheus.yml"

# Создаем резервную копию
cp "$PROMETHEUS_CONFIG" "/etc/prometheus/backups/prometheus.yml.$(date +%Y%m%d_%H%M%S)"

# Удаляем блоки конфигурации для данного сервера
sed -i "/# $SERVER_NAME/,/^$/d" "$PROMETHEUS_CONFIG"

# Перезагружаем конфигурацию
curl -X POST http://localhost:9090/-/reload

echo "Сервер $SERVER_NAME удален из мониторинга"
