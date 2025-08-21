#!/bin/bash
# Скрипт для удаления дубликатов серверов

SERVER_IP="$1"
if [ -z "$SERVER_IP" ]; then
    echo "Использование: $0 <IP_ADDRESS>"
    echo "Пример: $0 100.79.31.83"
    exit 1
fi

PROMETHEUS_CONFIG="/etc/prometheus/prometheus.yml"
BACKUP_DIR="/etc/prometheus/backups"

mkdir -p "$BACKUP_DIR"
cp "$PROMETHEUS_CONFIG" "$BACKUP_DIR/prometheus.yml.$(date +%Y%m%d_%H%M%S)"

echo "Удаляем все job'ы для IP $SERVER_IP"

# Создаём новый конфиг без указанного IP
awk -v ip="$SERVER_IP" '
BEGIN { skip = 0 }
/^  - job_name:/ { 
    job_block = ""
    skip = 0
    collecting = 1
}
collecting && /^  - job_name:/ && NR > 1 {
    if (job_block !~ ip) print job_block
    job_block = $0 "\n"
    next
}
collecting && /^[^ ]/ && !/^  - job_name:/ {
    if (job_block !~ ip) print job_block
    print
    collecting = 0
    next
}
collecting {
    job_block = job_block $0 "\n"
    next
}
!collecting { print }
END {
    if (job_block != "" && job_block !~ ip) print job_block
}' "$PROMETHEUS_CONFIG" > /tmp/prometheus_clean.yml

if promtool check config /tmp/prometheus_clean.yml; then
    mv /tmp/prometheus_clean.yml "$PROMETHEUS_CONFIG"
    systemctl reload prometheus
    echo "✅ Дубликаты удалены, Prometheus перезагружен"
else
    echo "❌ Ошибка в новой конфигурации"
    rm -f /tmp/prometheus_clean.yml
fi
