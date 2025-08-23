#!/bin/bash

# =============================================================================
# Скрипт быстрой установки Node Exporter с автообнаружением Angie и cAdvisor
# Использует правильные диапазоны портов для избежания конфликтов
# =============================================================================

set -e
printf "=== Установка мониторинга сервера ===\n"

# [... проверки root, архитектуры, IP, SERVER_NAME остаются без изменений ...]

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
    
    printf "Поиск свободного порта для %s в диапазоне %d-%d...\n" "$service_name" "$start_port" "$end_port"
    
    for port in $(seq $start_port $end_port); do
        local process=$(check_port_process $port)
        if [ -z "$process" ]; then
            printf "✓ Найден свободный порт %d для %s\n" "$port" "$service_name"
            echo $port
            return
        elif [ "$process" = "cadvisor" ] && [ "$service_name" = "cAdvisor" ]; then
            # Переиспользуем существующий cAdvisor
            if timeout 5 curl -s http://localhost:$port/metrics 2>/dev/null | grep -q "container_cpu_usage_seconds_total"; then
                printf "✓ Обнаружен рабочий cAdvisor на порту %d (переиспользуем)\n" "$port"
                echo $port
                return
            fi
        fi
        printf "⚠ Порт %d занят процессом '%s', проверяем следующий...\n" "$port" "$process"
    done
    
    printf "❌ Не найдено свободных портов в диапазоне %d-%d для %s\n" "$start_port" "$end_port" "$service_name"
    echo ""
}

# [... NODE EXPORTER секция остается без изменений ...]

# CADVISOR (обновлено: использует диапазон 9080-9089)
CADVISOR_INSTALLED=false
CADVISOR_PORT=""

printf "=== Проверка и установка cAdvisor ===\n"

# Проверяем активный systemd сервис
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

# Установка cAdvisor, если нужно
if [ "$CADVISOR_INSTALLED" = false ]; then
    # Используем диапазон 9080-9089 для cAdvisor (prometheus ecosystem)
    CADVISOR_PORT=$(find_free_port_range 9080 9089 "cAdvisor")
    
    if [ -z "$CADVISOR_PORT" ]; then
        printf "⚠ Не удалось найти свободный порт для cAdvisor в диапазоне 9080-9089\n"
        printf "   Попробуйте освободить порты или настройте cAdvisor вручную\n"
    else
        # Проверяем, не переиспользуем ли существующий
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

# Финальная проверка cAdvisor
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

# ANGIE (обновлено: предпочитает диапазон 8081-8089)
ANGIE_DETECTED=false
ANGIE_METRICS_PORT=""

printf "=== Проверка Angie ===\n"
if pgrep -x "angie" > /dev/null; then
    printf "✓ Angie обнаружен\n"
    ANGIE_DETECTED=true
    
    printf "Проверка метрик Angie в предпочтительных портах...\n"
    # Проверяем сначала рекомендуемые порты для веб-сервисов
    for port in 8081 8082 8083 80 443; do
        HTTP_CODE=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/prometheus" 2>/dev/null || echo "000")
        if [[ "$HTTP_CODE" =~ ^(200|204)$ ]]; then
            ANGIE_METRICS_PORT=$port
            printf "✓ Метрики Angie найдены на порту %s\n" "$port"
            break
        fi
    done
    
    if [ -z "$ANGIE_METRICS_PORT" ]; then
        printf "⚠ Angie найден, но метрики не настроены на стандартных портах\n"
        printf "   Настройте метрики Angie на порту 8081-8089 для правильной архитектуры\n"
    fi
else
    printf "ℹ Angie не обнаружен\n"
fi

# [... остальная часть без изменений ...]

# ФИНАЛЬНЫЙ ВЫВОД с пояснением портов
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
fi
if [ "$CADVISOR_INSTALLED" = true ] && [ -n "$CADVISOR_PORT" ]; then 
    COMMAND_ARGS="$COMMAND_ARGS \"$CADVISOR_PORT\""
fi

printf "curl -fsSL https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/add | bash -s %s\n" "$COMMAND_ARGS"
printf "\n✅ Готово! Архитектура портов спроектирована для масштабирования.\n"

