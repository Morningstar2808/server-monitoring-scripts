#!/bin/bash

# =============================================================================
# Скрипт быстрой установки Node Exporter с автообнаружением Angie и cAdvisor
# =============================================================================

set -e
printf "=== Установка мониторинга сервера ===\n"

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    printf "Ошибка: Скрипт должен запускаться от root\n"
    exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_SUFFIX="amd64";;
    aarch64) ARCH_SUFFIX="arm64";;
    armv7l) ARCH_SUFFIX="armv7";;
    armv6l) ARCH_SUFFIX="armv6";;
    *) printf "Ошибка: Неподдерживаемая архитектура: %s\n" "$ARCH"; exit 1;;
esac
printf "Архитектура: %s -> %s\n" "$ARCH" "$ARCH_SUFFIX"

TAILSCALE_IP=""
if command -v tailscale > /dev/null 2>&1; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -n1 || echo "")
fi
if [ -z "$TAILSCALE_IP" ]; then
    TAILSCALE_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -n1 2>/dev/null || echo "127.0.0.1")
fi
printf "Определен IP: %s\n" "$TAILSCALE_IP"

SERVER_NAME=""
if [ -t 0 ]; then
    while true; do
        printf "Введите уникальное имя сервера (латиницей, без пробелов): "
        read -r SERVER_NAME
        SERVER_NAME=$(echo "$SERVER_NAME" | tr -d ' ')  # Авто-удаление пробелов
        if [[ $SERVER_NAME =~ ^[a-zA-Z0-9_-]+$ ]] && [ -n "$SERVER_NAME" ]; then 
            break
        else
            printf "Ошибка: Используйте только буквы, цифры, дефисы и подчеркивания (без пробелов). Попробуйте снова.\n"
        fi
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

# NODE EXPORTER (без изменений, работает корректно)
NODE_EXPORTER_INSTALLED=false
NODE_EXPORTER_VER="1.9.1"

printf "=== Проверка Node Exporter ===\n"
if systemctl is-active --quiet node_exporter 2>/dev/null; then
    printf "✓ Найден запущенный Node Exporter, проверяем метрики...\n"
    if timeout 5 curl -s http://localhost:9100/metrics 2>/dev/null | grep -q "node_cpu_seconds_total"; then
        printf "✓ Node Exporter уже установлен и работает корректно\n"
        NODE_EXPORTER_INSTALLED=true
    else
        printf "⚠ Node Exporter запущен, но метрики недоступны, переустанавливаем...\n"
        systemctl stop node_exporter
    fi
else
    printf "Node Exporter не найден, устанавливаем...\n"
fi

if [ "$NODE_EXPORTER_INSTALLED" = false ]; then
    systemctl stop node_exporter 2>/dev/null || true
    systemctl disable node_exporter 2>/dev/null || true
    
    DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VER}/node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}.tar.gz"
    printf "Загружаем Node Exporter %s...\n" "$NODE_EXPORTER_VER"
    
    cd /tmp && rm -rf node_exporter-* && wget -q --show-progress "$DOWNLOAD_URL" || { printf "Ошибка загрузки\n"; exit 1; }
    printf "Распаковка архива...\n"
    tar -xzf "node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}.tar.gz"
    printf "Установка Node Exporter...\n"
    cp "node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}/node_exporter" /usr/local/bin/
    chmod +x /usr/local/bin/node_exporter
    
    useradd -M -r -s /bin/false node_exporter 2>/dev/null || true
    chown node_exporter:node_exporter /usr/local/bin/node_exporter
    
    printf "Создаем systemd сервис...\n"
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
    printf "Ожидание запуска сервиса...\n"
    sleep 3
    
    if systemctl is-active --quiet node_exporter; then
        printf "✓ Node Exporter успешно запущен\n"
        NODE_EXPORTER_INSTALLED=true
    else
        printf "✗ Ошибка запуска Node Exporter\n"
        systemctl status node_exporter --no-pager
        exit 1
    fi
    rm -rf /tmp/node_exporter-*
fi

printf "Финальная проверка метрик Node Exporter...\n"
for i in {1..3}; do
    if timeout 5 curl -s http://localhost:9100/metrics 2>/dev/null | grep -q "node_cpu_seconds_total"; then
        printf "✓ Метрики Node Exporter доступны\n"
        break
    else
        printf "Попытка %d/3...\n" "$i"
        sleep 2
    fi
    if [ $i -eq 3 ]; then 
        printf "✗ Node Exporter недоступен\n"
        exit 1
    fi
done

# CADVISOR (обновлено: проверка сервиса/метрик всегда, даже если порт занят)
CADVISOR_INSTALLED=false
CADVISOR_PORT="8080"

printf "=== Проверка и установка cAdvisor ===\n"

# Сначала проверяем, активен ли сервис и доступны метрики (независимо от порта)
if systemctl is-active --quiet cadvisor 2>/dev/null && timeout 5 curl -s http://localhost:8080/metrics 2>/dev/null | grep -q "container_cpu_usage_seconds_total"; then
    printf "✓ cAdvisor уже запущен и метрики доступны (порт занят, но сервис работает)\n"
    CADVISOR_INSTALLED=true
else
    # Если не активен, проверяем порт
    if ss -tuln | grep -q ":$CADVISOR_PORT "; then
        printf "⚠ Порт $CADVISOR_PORT занят другим процессом, пропускаем установку cAdvisor\n"
    else
        printf "cAdvisor не найден, устанавливаем на хост...\n"
        systemctl stop cadvisor 2>/dev/null || true
        systemctl disable cadvisor 2>/dev/null || true
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
            
            printf "Создаем сервис cAdvisor (с флагами для стабильности)...\n"
            cat > /etc/systemd/system/cadvisor.service << 'EOF'
[Unit]
Description=cAdvisor
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cadvisor --port=8080 --listen_ip=0.0.0.0
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
fi

# Проверка метрик (если установлен или уже работал)
if [ "$CADVISOR_INSTALLED" = true ]; then
    printf "Проверка метрик cAdvisor...\n"
    for i in {1..5}; do
        if timeout 5 curl -s http://localhost:8080/metrics 2>/dev/null | grep -q "container_cpu_usage_seconds_total"; then
            printf "✓ cAdvisor метрики доступны на 8080\n"
            break
        else
            printf "Попытка %d/5...\n" "$i"
            sleep 2
        fi
        if [ $i -eq 5 ]; then 
            printf "⚠ cAdvisor метрики недоступны\n"
            CADVISOR_INSTALLED=false  # Сброс, если метрики не подтверждены
        fi
    done
fi

# ANGIE (без изменений)
ANGIE_DETECTED=false
ANGIE_METRICS_PORT=""

printf "=== Проверка Angie ===\n"
if pgrep -x "angie" > /dev/null; then
    printf "✓ Angie обнаружен\n"
    ANGIE_DETECTED=true
    
    printf "Проверка метрик Angie...\n"
    for port in 8081 80 443; do
        HTTP_CODE=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/prometheus" 2>/dev/null || echo "000")
        if [[ "$HTTP_CODE" =~ ^(200|204)$ ]]; then
            ANGIE_METRICS_PORT=$port
            printf "✓ Метрики Angie на порту %s\n" "$port"
            break
        fi
    done
    
    if [ -z "$ANGIE_METRICS_PORT" ]; then
        printf "⚠ Angie найден, но метрики не настроены\n"
    fi
else
    printf "ℹ Angie не обнаружен\n"
fi

# СОХРАНЕНИЕ (без изменений)
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

# ФИНАЛЬНЫЙ ВЫВОД (уточнённый)
printf "\n==================================================\n"
printf "🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!\n"
printf "==================================================\n"
printf "Сервер: %s\n" "$SERVER_NAME"
printf "IP адрес: %s\n" "$TAILSCALE_IP"
printf "Архитектура: %s (%s)\n" "$ARCH" "$ARCH_SUFFIX"
printf "Node Exporter: http://%s:9100/metrics\n" "$TAILSCALE_IP"

if [ "$CADVISOR_INSTALLED" = true ]; then
    printf "cAdvisor: http://%s:8080/metrics (установлен или уже работал)\n" "$TAILSCALE_IP"
else
    printf "cAdvisor: Пропущен (порт занят или ошибка установки)\n"
fi

if [ "$ANGIE_DETECTED" = true ] && [ -n "$ANGIE_METRICS_PORT" ]; then
    printf "Angie: http://%s:%s/prometheus\n" "$TAILSCALE_IP" "$ANGIE_METRICS_PORT"
fi

printf "\n📋 ДЛЯ ДОБАВЛЕНИЯ В ЦЕНТРАЛЬНЫЙ МОНИТОРИНГ:\n"
printf "На сервере Prometheus выполните:\n\n"

COMMAND_ARGS="\"$SERVER_NAME\" \"$TAILSCALE_IP\""
if [ -n "$ANGIE_METRICS_PORT" ]; then 
    COMMAND_ARGS="$COMMAND_ARGS \"$ANGIE_METRICS_PORT\""
fi
if [ "$CADVISOR_INSTALLED" = true ]; then 
    COMMAND_ARGS="$COMMAND_ARGS \"$CADVISOR_PORT\""
fi

printf "curl -fsSL https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/add | bash -s %s\n" "$COMMAND_ARGS"
printf "\n✅ Готово! Сервер готов к мониторингу.\n"
