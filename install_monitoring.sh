#!/bin/bash

# =============================================================================
# Скрипт быстрой установки Node Exporter с автообнаружением Angie и cAdvisor
# =============================================================================

set -e
printf "=== Установка мониторинга сервера ===\n"

# Архитектура
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_SUFFIX="amd64";;
    aarch64) ARCH_SUFFIX="arm64";;
    armv7l) ARCH_SUFFIX="armv7";;
    armv6l) ARCH_SUFFIX="armv6";;
    *) printf "Ошибка: Неподдерживаемая архитектура: %s\n" "$ARCH"; exit 1;;
esac
printf "Архитектура: %s -> %s\n" "$ARCH" "$ARCH_SUFFIX"

# Tailscale IP
TAILSCALE_IP=""
if command -v tailscale > /dev/null 2>&1; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -n1 || echo "")
fi
if [ -z "$TAILSCALE_IP" ]; then
    TAILSCALE_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -n1 2>/dev/null || echo "127.0.0.1")
fi
printf "Определен IP: %s\n" "$TAILSCALE_IP"

# Имя сервера
SERVER_NAME=""
if [ -t 0 ]; then
    while true; do
        printf "Введите уникальное имя сервера (латиницей, без пробелов): "
        read -r SERVER_NAME
        if [[ $SERVER_NAME =~ ^[a-zA-Z0-9_-]+$ ]]; then break; else
            printf "Ошибка: Используйте только буквы, цифры, дефисы и подчеркивания\n"; fi
    done
else
    if [ -f /etc/hostname ]; then
        SERVER_NAME=$(cat /etc/hostname | tr -cd 'a-zA-Z0-9_-' | head -c 15)
    else
        SERVER_NAME="server-$(date +%s | tail -c 6)"
    fi
    if ! [[ $SERVER_NAME =~ ^[a-zA-Z0-9_-]+$ ]] || [ -z "$SERVER_NAME" ]; then
        SERVER_NAME="server-$(date +%s | tail -c 6)"
    fi
    printf "Автоматически определено имя сервера: %s\n" "$SERVER_NAME"
fi

# NODE EXPORTER
NODE_EXPORTER_INSTALLED=false
NODE_EXPORTER_VER="1.9.1"

if systemctl is-active --quiet node_exporter 2>/dev/null && curl -s http://localhost:9100/metrics | grep -q "node_cpu_seconds_total"; then
    printf "✓ Node Exporter уже установлен и работает\n"
    NODE_EXPORTER_INSTALLED=true
else
    printf "Node Exporter не найден, устанавливаем...\n"
    systemctl stop node_exporter 2>/dev/null || true
    
    DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VER}/node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}.tar.gz"
    printf "Загружаем Node Exporter %s...\n" "$NODE_EXPORTER_VER"
    
    cd /tmp && rm -rf node_exporter-* && wget -q --show-progress "$DOWNLOAD_URL" || { printf "Ошибка загрузки\n"; exit 1; }
    tar -xzf "node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}.tar.gz"
    cp "node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}/node_exporter" /usr/local/bin/
    chmod +x /usr/local/bin/node_exporter
    
    useradd -M -r -s /bin/false node_exporter 2>/dev/null || true
    chown node_exporter:node_exporter /usr/local/bin/node_exporter
    
    cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload && systemctl enable node_exporter && systemctl start node_exporter
    sleep 3
    
    if systemctl is-active --quiet node_exporter; then
        printf "✓ Node Exporter успешно запущен\n"
        NODE_EXPORTER_INSTALLED=true
    else
        printf "✗ Ошибка запуска Node Exporter\n"; exit 1
    fi
    rm -rf /tmp/node_exporter-*
fi

# Проверка Node Exporter
printf "Проверка метрик Node Exporter...\n"
for i in {1..3}; do
    if curl -s http://localhost:9100/metrics | grep -q "node_cpu_seconds_total"; then
        printf "✓ Метрики Node Exporter доступны\n"; break
    else
        printf "Попытка %d/3...\n" "$i"; sleep 2
    fi
    if [ $i -eq 3 ]; then printf "✗ Node Exporter недоступен\n"; exit 1; fi
done

# CADVISOR (ИСПРАВЛЕННАЯ ВЕРСИЯ ДЛЯ ARM64)
CADVISOR_INSTALLED=false
CADVISOR_PORT="8080"

if systemctl is-active --quiet cadvisor 2>/dev/null && curl -s http://localhost:8080/metrics | grep -q "container_cpu_usage_seconds_total"; then
    printf "✓ cAdvisor уже работает\n"
    CADVISOR_INSTALLED=true
else
    printf "Устанавливаем cAdvisor на хост...\n"
    
    systemctl stop cadvisor 2>/dev/null || true
    docker stop cadvisor 2>/dev/null || true
    docker rm cadvisor 2>/dev/null || true
    
    case "$ARCH" in
        x86_64) CADVISOR_ARCH="amd64";;
        aarch64) CADVISOR_ARCH="arm64";;
        armv7l) CADVISOR_ARCH="arm";;
        *) printf "Неподдерживаемая архитектура для cAdvisor: %s\n" "$ARCH"; exit 1;;
    esac
    
    CADVISOR_VERSION="v0.49.1"
    cd /tmp
    printf "Загружаем cAdvisor %s для %s...\n" "$CADVISOR_VERSION" "$CADVISOR_ARCH"
    
    if wget -q --show-progress "https://github.com/google/cadvisor/releases/download/${CADVISOR_VERSION}/cadvisor-${CADVISOR_VERSION}-linux-${CADVISOR_ARCH}"; then
        mv "cadvisor-${CADVISOR_VERSION}-linux-${CADVISOR_ARCH}" /usr/local/bin/cadvisor
        chmod +x /usr/local/bin/cadvisor
        
        printf "Создаем сервис cAdvisor (минимальная конфигурация для ARM64)...\n"
        cat > /etc/systemd/system/cadvisor.service << 'EOF'
[Unit]
Description=cAdvisor
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cadvisor
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload && systemctl enable cadvisor && systemctl start cadvisor
        sleep 5
        
        if systemctl is-active --quiet cadvisor; then
            printf "✓ cAdvisor успешно запущен\n"
            CADVISOR_INSTALLED=true
        else
            printf "⚠ Ошибка запуска cAdvisor\n"
            systemctl status cadvisor --no-pager
        fi
    else
        printf "⚠ Не удалось загрузить cAdvisor, продолжаем без него\n"
    fi
fi

# Проверка cAdvisor
if [ "$CADVISOR_INSTALLED" = true ]; then
    printf "Проверка метрик cAdvisor...\n"
    for i in {1..5}; do
        if curl -s http://localhost:8080/metrics | grep -q "container_cpu_usage_seconds_total"; then
            printf "✓ cAdvisor метрики доступны на 8080\n"; break
        else
            printf "Попытка %d/5...\n" "$i"; sleep 2
        fi
        if [ $i -eq 5 ]; then printf "⚠ cAdvisor метрики недоступны\n"; fi
    done
fi

# ANGIE
ANGIE_DETECTED=false
ANGIE_METRICS_PORT=""

if pgrep -x "angie" > /dev/null; then
    printf "✓ Angie обнаружен\n"
    ANGIE_DETECTED=true
    
    printf "Проверка метрик Angie...\n"
    for port in 8081 80 443; do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/prometheus" 2>/dev/null || echo "000")
        if [[ "$HTTP_CODE" =~ ^(200|204)$ ]]; then
            ANGIE_METRICS_PORT=$port
            printf "✓ Метрики Angie на порту %s\n" "$port"; break
        fi
    done
    
    if [ -z "$ANGIE_METRICS_PORT" ]; then
        printf "⚠ Angie найден, но метрики не настроены\n"
    fi
else
    printf "ℹ Angie не обнаружен\n"
fi

# СОХРАНЕНИЕ
cat > /etc/monitoring-info.conf << EOF
SERVER_NAME="$SERVER_NAME"
TAILSCALE_IP="$TAILSCALE_IP"
ARCH="$ARCH"
NODE_EXPORTER_INSTALLED="$NODE_EXPORTER_INSTALLED"
CADVISOR_INSTALLED="$CADVISOR_INSTALLED"
CADVISOR_PORT="$CADVISOR_PORT"
ANGIE_DETECTED="$ANGIE_DETECTED"
ANGIE_METRICS_PORT="$ANGIE_METRICS_PORT"
INSTALL_DATE="$(date -Iseconds)"
NODE_EXPORTER_VERSION="$NODE_EXPORTER_VER"
CADVISOR_VERSION="$CADVISOR_VERSION"
EOF

# ФИНАЛЬНЫЙ ВЫВОД
printf "\n==================================================\n"
printf "🎉 УСТАНОВКА ЗАВЕРШЕНА!\n"
printf "==================================================\n"
printf "Сервер: %s\n" "$SERVER_NAME"
printf "IP: %s\n" "$TAILSCALE_IP"
printf "Архитектура: %s (%s)\n" "$ARCH" "$ARCH_SUFFIX"
printf "Node Exporter: http://%s:9100/metrics\n" "$TAILSCALE_IP"

if [ "$CADVISOR_INSTALLED" = true ]; then
    printf "cAdvisor: http://%s:8080/metrics\n" "$TAILSCALE_IP"
fi

if [ "$ANGIE_DETECTED" = true ] && [ -n "$ANGIE_METRICS_PORT" ]; then
    printf "Angie: http://%s:%s/prometheus\n" "$TAILSCALE_IP" "$ANGIE_METRICS_PORT"
fi

printf "\n📋 ДОБАВЛЕНИЕ В МОНИТОРИНГ:\n"
COMMAND_ARGS="\"$SERVER_NAME\" \"$TAILSCALE_IP\""
if [ -n "$ANGIE_METRICS_PORT" ]; then COMMAND_ARGS="$COMMAND_ARGS \"$ANGIE_METRICS_PORT\""; fi
if [ "$CADVISOR_INSTALLED" = true ]; then COMMAND_ARGS="$COMMAND_ARGS \"8080\""; fi

printf "curl -fsSL https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/add | bash -s %s\n" "$COMMAND_ARGS"
printf "\n✅ Готово!\n"
