#!/bin/bash

# =============================================================================
# Скрипт установки Node Exporter с автообнаружением Angie и cAdvisor
# =============================================================================

set -e

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    printf "Ошибка: Скрипт должен запускаться от root\n"
    exit 1
fi

# ============================================================================
# САМООБНОВЛЕНИЕ СКРИПТА
# ============================================================================
SCRIPT_VERSION="2.3.0"
SCRIPT_URL="https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/install_monitoring.sh"
SCRIPT_NAME="$(basename "$0")"
UPDATE_CHECK_FILE="/tmp/.monitoring_install_update_check"

# Пропускаем проверку обновлений если скрипт запускается через pipe (curl | bash)
if [ ! -t 0 ] && [ "$SCRIPT_NAME" = "bash" ]; then
    printf "ℹ Скрипт запущен через pipe, проверка обновлений пропущена\n"
else
    # Проверяем обновления только раз в 5 минут
    SHOULD_CHECK=true
    if [ -f "$UPDATE_CHECK_FILE" ]; then
        LAST_CHECK=$(stat -c %Y "$UPDATE_CHECK_FILE" 2>/dev/null || echo 0)
        CURRENT_TIME=$(date +%s)
        TIME_DIFF=$((CURRENT_TIME - LAST_CHECK))
        if [ $TIME_DIFF -lt 300 ]; then
            SHOULD_CHECK=false
        fi
    fi

    if [ "$SHOULD_CHECK" = true ]; then
        printf "🔄 Проверка обновлений скрипта...\n"

        TEMP_SCRIPT="/tmp/install_monitoring_new.sh"
        if wget -q -O "$TEMP_SCRIPT" "$SCRIPT_URL" 2>/dev/null || curl -fsSL -o "$TEMP_SCRIPT" "$SCRIPT_URL" 2>/dev/null; then
            NEW_VERSION=$(grep -m1 '^SCRIPT_VERSION=' "$TEMP_SCRIPT" | cut -d'"' -f2)

            if [ -n "$NEW_VERSION" ] && [ "$NEW_VERSION" != "$SCRIPT_VERSION" ]; then
                printf "✨ Найдена новая версия: %s -> %s\n" "$SCRIPT_VERSION" "$NEW_VERSION"
                printf "📥 Обновляем скрипт...\n"

                if [ -f "$0" ] && [ "$SCRIPT_NAME" != "bash" ]; then
                    cp "$TEMP_SCRIPT" "$0"
                    chmod +x "$0"
                    rm -f "$TEMP_SCRIPT"
                    touch "$UPDATE_CHECK_FILE"
                    printf "✅ Скрипт обновлён, перезапуск...\n\n"
                    exec "$0" "$@"
                else
                    cp "$TEMP_SCRIPT" "./install_monitoring.sh"
                    chmod +x "./install_monitoring.sh"
                    rm -f "$TEMP_SCRIPT"
                    touch "$UPDATE_CHECK_FILE"
                    printf "✅ Скрипт обновлён, перезапуск...\n\n"
                    exec "./install_monitoring.sh" "$@"
                fi
            else
                printf "✓ Используется актуальная версия %s\n" "$SCRIPT_VERSION"
                rm -f "$TEMP_SCRIPT"
                touch "$UPDATE_CHECK_FILE"
            fi
        else
            printf "⚠ Не удалось проверить обновления (нет подключения к GitHub)\n"
        fi
    fi
fi

printf "=== Установка мониторинга сервера (v%s) ===\n" "$SCRIPT_VERSION"

# ============================================================================
# ОПРЕДЕЛЕНИЕ АРХИТЕКТУРЫ И IP
# ============================================================================

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

# ============================================================================
# ОПРЕДЕЛЕНИЕ ИМЕНИ СЕРВЕРА
# ============================================================================

# Перенаправляем stdin на терминал для корректной работы read при запуске через pipe
exec < /dev/tty

SERVER_NAME=""
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

printf "Имя сервера установлено: %s\n" "$SERVER_NAME"

# ============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================================

check_port_process() {
    local port=$1
    local output=$(ss -lpn | grep ":$port ")
    if [ -n "$output" ]; then
        local process=$(echo "$output" | grep -oP 'users:\(\(\("([^"]+)"' | grep -oP '"\K[^"]+' 2>/dev/null || echo "unknown")
        echo "$process"
    else
        echo ""
    fi
}

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

# ============================================================================
# NODE EXPORTER
# ============================================================================

NODE_EXPORTER_INSTALLED=false
NODE_EXPORTER_VER="1.9.1"

printf "\n=== Проверка Node Exporter ===\n"
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

# ============================================================================
# CADVISOR
# ============================================================================

CADVISOR_INSTALLED=false
CADVISOR_PORT=""

printf "\n=== Проверка и установка cAdvisor ===\n"

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

                printf "Создаем сервис cAdvisor на порту %s...\n" "$CADVISOR_PORT"
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

# ============================================================================
# ANGIE
# ============================================================================

ANGIE_DETECTED=false
ANGIE_METRICS_PORT=""

printf "\n=== Проверка Angie ===\n"
if pgrep -x "angie" > /dev/null; then
    printf "✓ Angie обнаружен\n"
    ANGIE_DETECTED=true

    if [ ! -f /etc/angie/http.d/prometheus-metrics.conf ]; then
        printf "Создаём конфигурацию метрик Angie...\n"

        ANGIE_METRICS_PORT=$(find_free_port_range 8081 8089 "Angie metrics")

        if [ -n "$ANGIE_METRICS_PORT" ]; then
            mkdir -p /etc/angie/http.d

            cat > /etc/angie/http.d/prometheus-metrics.conf << EOF
server {
    listen $ANGIE_METRICS_PORT;

    location /prometheus {
        prometheus all;
        access_log off;
    }
}
EOF
            printf "✓ Создан файл /etc/angie/http.d/prometheus-metrics.conf на порту %s\n" "$ANGIE_METRICS_PORT"

            if ! grep -qE '^\s*include\s+prometheus_all\.conf\s*;' /etc/angie/angie.conf; then
                printf "Добавляем prometheus_all.conf в конфигурацию...\n"
                if grep -qE "^\s*http\s*\{" /etc/angie/angie.conf; then
                    sed -i '/^\s*http\s*{/a \    include prometheus_all.conf;' /etc/angie/angie.conf
                    printf "✓ prometheus_all.conf добавлен\n"
                fi
            else
                printf "ℹ prometheus_all.conf уже подключен\n"
            fi

            if ! grep -qE '^\s*include\s+/etc/angie/http\.d/\*\.conf\s*;' /etc/angie/angie.conf; then
                printf "Добавляем подключение http.d в конфигурацию...\n"
                if grep -qE '^\s*include\s+prometheus_all\.conf\s*;' /etc/angie/angie.conf; then
                    sed -i '/^\s*include\s\+prometheus_all\.conf\s*;/a \    include /etc/angie/http.d/*.conf;' /etc/angie/angie.conf
                elif grep -qE "^\s*http\s*\{" /etc/angie/angie.conf; then
                    sed -i '/^\s*http\s*{/a \    include /etc/angie/http.d/*.conf;' /etc/angie/angie.conf
                fi
                printf "✓ http.d подключен в конфигурацию\n"
            else
                printf "ℹ http.d уже подключен\n"
            fi

            printf "Добавляем status_zone в виртуальные хосты...\n"
            cd /etc/angie/http.d/
            for conf in *.conf; do
                if [[ "$conf" == "prometheus-metrics.conf" ]]; then
                    continue
                fi

                if ! grep -q "status_zone" "$conf"; then
                    ZONE_NAME=$(basename "$conf" .conf | tr '.' '_' | tr '-' '_')
                    sed -i '/^\s*server\s*{/a \    status_zone '"$ZONE_NAME"';' "$conf"
                    printf "  ✓ Добавлена status_zone '$ZONE_NAME' в $conf\n"
                fi
            done
            cd - > /dev/null

            printf "Проверяем конфигурацию Angie...\n"
            if angie -t 2>&1; then
                printf "Перезапускаем Angie для применения изменений...\n"
                systemctl restart angie
                sleep 5

                printf "Проверяем доступность метрик на порту %s...\n" "$ANGIE_METRICS_PORT"

                if ss -tlnp | grep -q ":$ANGIE_METRICS_PORT "; then
                    printf "✓ Порт %s открыт\n" "$ANGIE_METRICS_PORT"

                    if timeout 10 curl -s "http://localhost:$ANGIE_METRICS_PORT/prometheus" 2>/dev/null | grep -q "angie_"; then
                        printf "✓ Метрики Angie работают на порту %s\n" "$ANGIE_METRICS_PORT"

                        if timeout 10 curl -s "http://localhost:$ANGIE_METRICS_PORT/prometheus" 2>/dev/null | grep -q "angie_http_server_zones"; then
                            printf "✓ Метрики HTTP Server Zones обнаружены\n"
                        else
                            printf "⚠ Метрики HTTP Server Zones появятся после трафика\n"
                        fi
                    else
                        printf "⚠ Метрики не отвечают, но порт открыт\n"
                        printf "Попробуйте позже: curl http://localhost:%s/prometheus\n" "$ANGIE_METRICS_PORT"
                    fi
                else
                    printf "❌ Порт %s не открыт\n" "$ANGIE_METRICS_PORT"
                    ANGIE_METRICS_PORT=""
                fi
            else
                printf "❌ Ошибка конфигурации Angie:\n"
                angie -t 2>&1 | head -5
                printf "Удаляем некорректную конфигурацию...\n"
                rm -f /etc/angie/http.d/prometheus-metrics.conf
                ANGIE_METRICS_PORT=""
            fi
        else
            printf "⚠ Не удалось найти свободный порт для Angie metrics\n"
        fi
    else
        printf "ℹ Конфигурация метрик Angie уже существует\n"

        ANGIE_METRICS_PORT=$(grep -oP 'listen\s+(127\.0\.0\.1:)?\K[0-9]+' /etc/angie/http.d/prometheus-metrics.conf 2>/dev/null | head -n1)

        if [ -n "$ANGIE_METRICS_PORT" ]; then
            if ! grep -qE '^\s*include\s+/etc/angie/http\.d/\*\.conf\s*;' /etc/angie/angie.conf; then
                printf "⚠ Обнаружен prometheus-metrics.conf, но http.d не подключен. Исправляем...\n"
                if grep -qE '^\s*include\s+prometheus_all\.conf\s*;' /etc/angie/angie.conf; then
                    sed -i '/^\s*include\s\+prometheus_all\.conf\s*;/a \    include /etc/angie/http.d/*.conf;' /etc/angie/angie.conf
                elif grep -qE "^\s*http\s*\{" /etc/angie/angie.conf; then
                    sed -i '/^\s*http\s*{/a \    include /etc/angie/http.d/*.conf;' /etc/angie/angie.conf
                fi
                systemctl restart angie
                sleep 5
            fi

            if timeout 10 curl -s "http://localhost:$ANGIE_METRICS_PORT/prometheus" 2>/dev/null | grep -q "angie_"; then
                printf "✓ Метрики Angie работают на порту %s\n" "$ANGIE_METRICS_PORT"

                if grep -q "listen 127.0.0.1:$ANGIE_METRICS_PORT" /etc/angie/http.d/prometheus-metrics.conf; then
                    printf "⚠ Обнаружена конфигурация с 127.0.0.1, исправляем...\n"
                    sed -i "s/listen 127.0.0.1:$ANGIE_METRICS_PORT/listen $ANGIE_METRICS_PORT/" /etc/angie/http.d/prometheus-metrics.conf

                    if angie -t 2>&1; then
                        systemctl restart angie
                        sleep 3
                        printf "✓ Конфигурация обновлена\n"
                    fi
                fi

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
                        systemctl restart angie
                        printf "✓ Конфигурация Angie обновлена\n"
                    fi
                fi
            else
                printf "⚠ Метрики не отвечают на порту %s\n" "$ANGIE_METRICS_PORT"
            fi
        fi
    fi

    if [ -z "$ANGIE_METRICS_PORT" ]; then
        printf "⚠ Не удалось настроить метрики Angie\n"
        ANGIE_DETECTED=false
    fi
else
    printf "ℹ Angie не обнаружен\n"
fi

# ============================================================================
# СОХРАНЕНИЕ КОНФИГУРАЦИИ
# ============================================================================

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
SCRIPT_VERSION="$SCRIPT_VERSION"
EOF

# ============================================================================
# ФИНАЛЬНЫЙ ВЫВОД
# ============================================================================

printf "\n==================================================\n"
printf "🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!\n"
printf "==================================================\n"
printf "Сервер: %s\n" "$SERVER_NAME"
printf "IP адрес: %s\n" "$TAILSCALE_IP"
printf "Архитектура: %s (%s)\n" "$ARCH" "$ARCH_SUFFIX"
printf "Версия скрипта: %s\n" "$SCRIPT_VERSION"

printf "\n📊 УСТАНОВЛЕННЫЕ СЕРВИСЫ:\n"
printf "Node Exporter: http://%s:9100/metrics\n" "$TAILSCALE_IP"

if [ "$CADVISOR_INSTALLED" = true ] && [ -n "$CADVISOR_PORT" ]; then
    printf "cAdvisor: http://%s:%s/metrics\n" "$TAILSCALE_IP" "$CADVISOR_PORT"
else
    printf "cAdvisor: Не установлен\n"
fi

if [ "$ANGIE_DETECTED" = true ] && [ -n "$ANGIE_METRICS_PORT" ]; then
    printf "Angie: http://%s:%s/prometheus\n" "$TAILSCALE_IP" "$ANGIE_METRICS_PORT"
    printf "  → Метрики: connections, http_server_zones\n"
else
    printf "Angie: Не обнаружен или метрики не настроены\n"
fi

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

printf "curl -fsSL https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/add_server_to_monitoring.sh | bash -s %s\n" "$COMMAND_ARGS"

printf "\n✅ Готово!\n"