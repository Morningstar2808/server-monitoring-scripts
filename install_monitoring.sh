#!/bin/bash

# =============================================================================
# Скрипт быстрой установки Node Exporter с автообнаружением Angie и cAdvisor
# Использует правильные диапазоны портов для избежания конфликтов
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
        SERVER_NAME=$(echo "$SERVER_NAME" | tr -d ' ')
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

# Функция для проверки, какой процесс занимает порт
check_port_process() {
    local port=$1
    local output=$(ss -lpn | grep ":$port ")
    if [ -n "$output" ]; then
        local process=$(echo "$output" | grep -oP 'users:\(\("([^"]+)"' | grep -oP '"\K[^"]+' 2>/dev/null || echo "unknown")
        echo "$process"
    else
        echo ""
    fi
}

# Функция для поиска свободного порта в указанном диапазоне
find_free_port_range() {
    local start_port=$1
    local end_port=$2
    local service_name=${3:-"unknown"}
    
    printf "Поиск свободного порта для %s в диапазоне %d-%d...\n" "$service_name" "$start_port" "$end_port" >&2
    
    for port in $(seq $start_port $end_port); do
        local process=$(check_port_process $port)
        if [ -z "$process" ]; then
            printf "✓ Найден свободный порт %d для %s\n" "$port" "$service_name" >&2
            echo $port
            return
        elif [ "$process" = "cadvisor" ] && [ "$service_name" = "cAdvisor" ]; then
            if timeout 5 curl -s http://localhost:$port/metrics 2>/dev/null | grep -q "container_cpu_usage_seconds_total"; then
                printf "✓ Обнаружен рабочий cAdvisor на порту %d (переиспользуем)\n" "$port" >&2
                echo $port
                return
            fi
        fi
        printf "⚠ Порт %d занят процессом '%s', проверяем следующий...\n" "$port" "$process" >&2
    done
    
    printf "❌ Не найдено свободных портов в диапазоне %d-%d для %s\n" "$start_port" "$end_port" "$service_name" >&2
    echo ""
}

# NODE EXPORTER
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

# CADVISOR
CADVISOR_INSTALLED=false
CADVISOR_PORT=""

printf "=== Проверка и установка cAdvisor ===\n"

if systemctl is-active --quiet cadvisor 2>/dev/null; then
    printf "✓ Обнаружен активный systemd сервис cAdvisor\n"
    
    EXISTING_PORT=$(systemctl show cadvisor -p ExecStart --value 2>/dev/null | grep -oP '\--port=\K[0-9]+' || echo "9080")
    printf "Проверяем метрики cAdvisor на порту %s...\n" "$EXISTING_PORT"
    
    if timeout 5 curl -s http://localhost:$EXISTING_PORT/metrics 2>/dev/null | grep -q "container_cpu_usage_seconds_total"; then
        printf "✓ cAdvisor работает корректно на порту %s (переиспользуем)\n" "$EXISTING_PORT"
        CADVISOR_INSTALLED=true
        CADVISOR_PORT=$EXISTING_PORT
    else
        printf "⚠ Метрики недоступны, переустанавливаем cAdvisor\n"
        systemctl stop cadvisor
    fi
fi

if [ "$CADVISOR_INSTALLED" = false ]; then
    CADVISOR_PORT=$(find_free_port_range 9080 9089 "cAdvisor")
    
    if [ -z "$CADVISOR_PORT" ]; then
        printf "⚠ Не удалось найти свободный порт для cAdvisor в диапазоне 9080-9089\n"
        printf "   Попробуйте освободить порты или настройте cAdvisor вручную\n"
    else
        EXISTING_PROCESS=$(check_port_process $CADVISOR_PORT)
        if [ "$EXISTING_PROCESS" = "cadvisor" ]; then
            printf "✓ Обнаружен рабочий cAdvisor на порту %s, переиспользуем\n" "$CADVISOR_PORT"
            CADVISOR_INSTALLED=true
        else
            printf "Устанавливаем cAdvisor на порт %s...\n" "$CADVISOR_PORT"
            
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
                
                printf "Создаем сервис cAdvisor на порту %s (Prometheus ecosystem диапазон)...\n" "$CADVISOR_PORT"
                cat > /etc/systemd/system/cadvisor.service << EOF
[Unit]
Description=cAdvisor (Container Advisor)
Documentation=https://github.com/google/cadvisor
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cadvisor --port=$CADVISOR_PORT --listen_ip=0.0.0.0
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
                
                systemctl daemon-reload && systemctl enable cadvisor && systemctl start cadvisor
                sleep 5
                
                if systemctl is-active --quiet cadvisor; then
                    printf "✓ cAdvisor успешно запущен на порту %s\n" "$CADVISOR_PORT"
                    CADVISOR_INSTALLED=true
                else
                    printf "❌ Ошибка запуска cAdvisor\n"
                    systemctl status cadvisor --no-pager
                fi
            else
                printf "❌ Не удалось загрузить cAdvisor\n"
            fi
        fi
    fi
fi

if [ "$CADVISOR_INSTALLED" = true ] && [ -n "$CADVISOR_PORT" ]; then
    printf "Финальная проверка метрик cAdvisor на порту %s...\n" "$CADVISOR_PORT"
    for i in {1..3}; do
        if timeout 5 curl -s http://localhost:$CADVISOR_PORT/metrics 2>/dev/null | grep -q "container_cpu_usage_seconds_total"; then
            printf "✓ cAdvisor метрики подтверждены на порту %s\n" "$CADVISOR_PORT"
            break
        else
            printf "Попытка %d/3...\n" "$i"
            sleep 2
        fi
        if [ $i -eq 3 ]; then 
            printf "❌ cAdvisor метрики недоступны\n"
            CADVISOR_INSTALLED=false
        fi
    done
fi

# ANGIE (расширенная версия с автоматической настройкой status_zone)
ANGIE_DETECTED=false
ANGIE_METRICS_PORT=""

printf "\n=== Проверка Angie ===\n"
if pgrep -x "angie" > /dev/null; then
    printf "✓ Angie обнаружен\n"
    ANGIE_DETECTED=true
    
    # Проверяем существующую конфигурацию метрик
    if [ ! -f /etc/angie/http.d/prometheus-metrics.conf ]; then
        printf "Создаём конфигурацию метрик Angie...\n"
        
        # Ищем свободный порт в диапазоне 8081-8089
        ANGIE_METRICS_PORT=$(find_free_port_range 8081 8089 "Angie metrics")
        
        if [ -n "$ANGIE_METRICS_PORT" ]; then
            # Создаём конфигурацию (БЕЗ 127.0.0.1 - слушаем на всех интерфейсах)
            cat > /etc/angie/http.d/prometheus-metrics.conf << EOF
server {
    listen $ANGIE_METRICS_PORT;
    
    location /prometheus {
        prometheus all;
        access_log off;
    }
}
EOF
            
            # Проверяем, включен ли prometheus_all.conf
            if ! grep -q "include prometheus_all.conf" /etc/angie/angie.conf; then
                printf "Добавляем prometheus_all.conf в конфигурацию...\n"
                sed -i '/^http {/a \    include prometheus_all.conf;' /etc/angie/angie.conf
            fi
            
            # Добавляем status_zone во все виртуальные хосты
            printf "Добавляем status_zone в виртуальные хосты...\n"
            cd /etc/angie/http.d/
            for conf in *.conf; do
                # Пропускаем prometheus-metrics.conf
                if [[ "$conf" == "prometheus-metrics.conf" ]]; then
                    continue
                fi
                
                # Проверяем, есть ли уже status_zone в конфиге
                if ! grep -q "status_zone" "$conf"; then
                    # Извлекаем имя зоны из имени файла
                    ZONE_NAME=$(basename "$conf" .conf | tr '.' '_' | tr '-' '_')
                    
                    # Добавляем status_zone после первой строки server {
                    sed -i '/^\s*server\s*{/a \    status_zone '"$ZONE_NAME"';' "$conf"
                    printf "  ✓ Добавлена status_zone '$ZONE_NAME' в $conf\n"
                fi
            done
            cd - > /dev/null
            
            # Проверяем и перезагружаем конфигурацию
            printf "Проверяем конфигурацию Angie...\n"
            if angie -t 2>&1; then
                systemctl reload angie
                sleep 2
                
                # Проверяем доступность метрик локально
                printf "Проверяем доступность метрик на порту %s...\n" "$ANGIE_METRICS_PORT"
                if timeout 5 curl -s "http://localhost:$ANGIE_METRICS_PORT/prometheus" 2>/dev/null | grep -q "angie_"; then
                    printf "✓ Метрики Angie настроены и работают на порту %s\n" "$ANGIE_METRICS_PORT"
                    
                    # Проверяем что status_zone метрики появились
                    if timeout 5 curl -s "http://localhost:$ANGIE_METRICS_PORT/prometheus" 2>/dev/null | grep -q "angie_http_server_zones"; then
                        printf "✓ Метрики HTTP Server Zones обнаружены\n"
                    else
                        printf "⚠ Метрики HTTP Server Zones пока не появились (нужен трафик)\n"
                    fi
                else
                    printf "⚠ Метрики Angie недоступны на порту %s\n" "$ANGIE_METRICS_PORT"
                    ANGIE_METRICS_PORT=""
                    rm -f /etc/angie/http.d/prometheus-metrics.conf
                fi
            else
                printf "❌ Ошибка конфигурации Angie, откатываем изменения\n"
                rm -f /etc/angie/http.d/prometheus-metrics.conf
                # Откатываем изменения в angie.conf если они были
                sed -i '/include prometheus_all.conf/d' /etc/angie/angie.conf
                ANGIE_METRICS_PORT=""
            fi
        else
            printf "⚠ Не удалось найти свободный порт для Angie metrics в диапазоне 8081-8089\n"
        fi
    else
        printf "ℹ Конфигурация метрик Angie уже существует\n"
        
        # Ищем существующий порт в конфигурации
        ANGIE_METRICS_PORT=$(grep -oP 'listen\s+(127\.0\.0\.1:)?\K[0-9]+' /etc/angie/http.d/prometheus-metrics.conf 2>/dev/null | head -n1)
        
        if [ -n "$ANGIE_METRICS_PORT" ]; then
            # Проверяем что метрики доступны
            if timeout 5 curl -s "http://localhost:$ANGIE_METRICS_PORT/prometheus" 2>/dev/null | grep -q "angie_"; then
                printf "✓ Метрики Angie работают на порту %s\n" "$ANGIE_METRICS_PORT"
                
                # Проверяем, не слушает ли только на 127.0.0.1
                if grep -q "listen 127.0.0.1:$ANGIE_METRICS_PORT" /etc/angie/http.d/prometheus-metrics.conf; then
                    printf "⚠ Обнаружена конфигурация с 127.0.0.1, исправляем для удалённого доступа...\n"
                    sed -i "s/listen 127.0.0.1:$ANGIE_METRICS_PORT/listen $ANGIE_METRICS_PORT/" /etc/angie/http.d/prometheus-metrics.conf
                    
                    if angie -t 2>&1; then
                        systemctl reload angie
                        sleep 2
                        printf "✓ Конфигурация обновлена для удалённого доступа\n"
                    else
                        printf "❌ Ошибка при обновлении конфигурации\n"
                        sed -i "s/listen $ANGIE_METRICS_PORT/listen 127.0.0.1:$ANGIE_METRICS_PORT/" /etc/angie/http.d/prometheus-metrics.conf
                        angie -t && systemctl reload angie
                    fi
                fi
                
                # Добавляем status_zone если его нет
                printf "Проверяем наличие status_zone...\n"
                cd /etc/angie/http.d/
                ZONES_ADDED=0
                for conf in *.conf; do
                    if [[ "$conf" == "prometheus-metrics.conf" ]]; then
                        continue
                    fi
                    
                    if ! grep -q "status_zone" "$conf"; then
                        ZONE_NAME=$(basename "$conf" .conf | tr '.' '_' | tr '-' '_')
                        sed -i '/^\s*server\s*{/a \    status_zone '"$ZONE_NAME"';' "$conf"
                        printf "  ✓ Добавлена status_zone '$ZONE_NAME' в $conf\n"
                        ZONES_ADDED=$((ZONES_ADDED + 1))
                    fi
                done
                cd - > /dev/null
                
                if [ $ZONES_ADDED -gt 0 ]; then
                    if angie -t 2>&1; then
                        systemctl reload angie
                        printf "✓ Конфигурация Angie обновлена с новыми status_zone\n"
                    fi
                fi
            else
                printf "⚠ Метрики Angie не отвечают на порту %s\n" "$ANGIE_METRICS_PORT"
                ANGIE_METRICS_PORT=""
            fi
        fi
    fi
    
    if [ -z "$ANGIE_METRICS_PORT" ]; then
        printf "⚠ Не удалось настроить или найти метрики Angie\n"
        ANGIE_DETECTED=false
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
CADVISOR_VERSION="${CADVISOR_VERSION:-v0.49.1}"
EOF

# ФИНАЛЬНЫЙ ВЫВОД
printf "\n==================================================\n"
printf "🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!\n"
printf "==================================================\n"
printf "Сервер: %s\n" "$SERVER_NAME"
printf "IP адрес: %s\n" "$TAILSCALE_IP"
printf "Архитектура: %s (%s)\n" "$ARCH" "$ARCH_SUFFIX"

printf "\n📊 УСТАНОВЛЕННЫЕ СЕРВИСЫ:\n"
printf "Node Exporter: http://%s:9100/metrics (стандартный порт)\n" "$TAILSCALE_IP"

if [ "$CADVISOR_INSTALLED" = true ] && [ -n "$CADVISOR_PORT" ]; then
    printf "cAdvisor: http://%s:%s/metrics (Prometheus ecosystem: 9080-9089)\n" "$TAILSCALE_IP" "$CADVISOR_PORT"
else
    printf "cAdvisor: Не установлен\n"
fi

if [ "$ANGIE_DETECTED" = true ] && [ -n "$ANGIE_METRICS_PORT" ]; then
    printf "Angie: http://%s:%s/prometheus (веб-сервисы: 8081-8089)\n" "$TAILSCALE_IP" "$ANGIE_METRICS_PORT"
    printf "  → Метрики: connections, http_server_zones\n"
else
    printf "Angie: Не обнаружен или метрики не настроены\n"
fi

printf "\n🔧 РЕКОМЕНДАЦИИ ПО ПОРТАМ:\n"
printf "• 9080-9089: cAdvisor (мониторинг контейнеров)\n" 
printf "• 8080: CrowdSec, приложения (оставлен свободным)\n"
printf "• 8081-8089: Angie metrics, веб-API\n"
printf "• 9100: Node Exporter (стандарт)\n"
printf "• 9090: Prometheus (центральный)\n"

printf "\n📋 ДЛЯ ДОБАВЛЕНИЯ В ЦЕНТРАЛЬНЫЙ МОНИТОРИНГ:\n"

COMMAND_ARGS="\"$SERVER_NAME\" \"$TAILSCALE_IP\""
if [ -n "$ANGIE_METRICS_PORT" ]; then 
    COMMAND_ARGS="$COMMAND_ARGS \"$ANGIE_METRICS_PORT\""
else
    COMMAND_ARGS="$COMMAND_ARGS \"\""
fi
if [ "$CADVISOR_INSTALLED" = true ] && [ -n "$CADVISOR_PORT" ]; then 
    COMMAND_ARGS="$COMMAND_ARGS \"$CADVISOR_PORT\""
fi

printf "curl -fsSL https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/add | bash -s %s\n" "$COMMAND_ARGS"
printf "\n✅ Готово! Архитектура портов спроектирована для масштабирования.\n"
