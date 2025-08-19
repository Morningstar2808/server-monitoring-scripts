#!/bin/bash

# =============================================================================
# Скрипт быстрой установки Node Exporter с автообнаружением Angie
# Проверяет правильные директории Angie: /etc/angie/
# =============================================================================

set -e

printf "=== Установка мониторинга сервера ===\n"

# Определяем архитектуру
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_SUFFIX="amd64";;
    aarch64) ARCH_SUFFIX="arm64";;
    armv7l) ARCH_SUFFIX="armv7";;
    armv6l) ARCH_SUFFIX="armv6";;
    *) 
        printf "Ошибка: Неподдерживаемая архитектура: %s\n" "$ARCH"
        exit 1
        ;;
esac

printf "Архитектура: %s -> %s\n" "$ARCH" "$ARCH_SUFFIX"

# Определяем Tailscale IP автоматически
TAILSCALE_IP=""
if command -v tailscale > /dev/null 2>&1; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -n1 || echo "")
fi

# Если нет Tailscale IP, пробуем основной IP интерфейса
if [ -z "$TAILSCALE_IP" ]; then
    TAILSCALE_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -n1 2>/dev/null || echo "127.0.0.1")
fi

printf "Определен IP: %s\n" "$TAILSCALE_IP"

# Определяем имя сервера
SERVER_NAME=""

# Проверяем, запущен ли скрипт интерактивно
if [ -t 0 ]; then
    # Интерактивный режим - запрашиваем имя
    while true; do
        printf "Введите уникальное имя сервера (латиницей, без пробелов): "
        read -r SERVER_NAME
        if [[ $SERVER_NAME =~ ^[a-zA-Z0-9_-]+$ ]]; then
            break
        else
            printf "Ошибка: Используйте только буквы, цифры, дефисы и подчеркивания\n"
        fi
    done
else
    # Pipe режим - автоматически генерируем имя
    if [ -f /etc/hostname ]; then
        SERVER_NAME=$(cat /etc/hostname | tr -cd 'a-zA-Z0-9_-' | head -c 15)
    else
        SERVER_NAME="server-$(date +%s | tail -c 6)"
    fi
    
    # Проверяем корректность и исправляем если нужно
    if ! [[ $SERVER_NAME =~ ^[a-zA-Z0-9_-]+$ ]] || [ -z "$SERVER_NAME" ]; then
        SERVER_NAME="server-$(date +%s | tail -c 6)"
    fi
    
    printf "Автоматически определено имя сервера: %s\n" "$SERVER_NAME"
fi

# Останавливаем старый Node Exporter если есть
systemctl stop node_exporter 2>/dev/null || true
systemctl disable node_exporter 2>/dev/null || true

# Версия Node Exporter
NODE_EXPORTER_VER="1.9.1"
DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VER}/node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}.tar.gz"

printf "Загружаем Node Exporter версии %s...\n" "$NODE_EXPORTER_VER"

# Переходим во временную директорию
cd /tmp

# Очищаем старые файлы
rm -rf node_exporter-*/
rm -f node_exporter-*.tar.gz

# Загружаем Node Exporter
if ! wget -q --show-progress "$DOWNLOAD_URL"; then
    printf "Ошибка: Не удалось загрузить Node Exporter\n"
    printf "URL: %s\n" "$DOWNLOAD_URL"
    exit 1
fi

# Распаковываем
printf "Распаковка архива...\n"
tar -xzf "node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}.tar.gz"

# Копируем бинарный файл
printf "Установка Node Exporter...\n"
cp "node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH_SUFFIX}/node_exporter" /usr/local/bin/
chmod +x /usr/local/bin/node_exporter

# Создаем системного пользователя
useradd -M -r -s /bin/false node_exporter 2>/dev/null || true
chown node_exporter:node_exporter /usr/local/bin/node_exporter

printf "Создаем systemd сервис...\n"

# Создаем systemd сервис
cat > /etc/systemd/system/node_exporter.service << 'SERVICE_EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
SyslogIdentifier=node_exporter
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Запускаем и включаем сервис
printf "Запуск Node Exporter...\n"
systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

# Ждем запуска
printf "Ожидание запуска сервиса...\n"
sleep 5

# Проверяем статус
if systemctl is-active --quiet node_exporter; then
    printf "✓ Node Exporter успешно запущен\n"
else
    printf "✗ Ошибка запуска Node Exporter\n"
    systemctl status node_exporter --no-pager
    exit 1
fi

# Проверяем порт
printf "Проверка порта 9100...\n"
if ss -tlnp | grep -q ":9100"; then
    printf "✓ Node Exporter слушает на порту 9100\n"
else
    printf "✗ Node Exporter не слушает на порту 9100\n"
    ss -tlnp | grep node_exporter || printf "Процесс node_exporter не найден\n"
    exit 1
fi

# Проверяем доступность метрик (исправленная проверка с таймаутом)
printf "Проверка доступности метрик...\n"
for i in {1..5}; do
    HTTP_CODE=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" http://localhost:9100/metrics 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        printf "✓ Метрики Node Exporter доступны (HTTP %s)\n" "$HTTP_CODE"
        break
    else
        printf "Попытка %d/5: метрики недоступны (HTTP %s), ждем...\n" "$i" "$HTTP_CODE"
        sleep 3
    fi
    
    if [ $i -eq 5 ]; then
        printf "✗ Метрики Node Exporter недоступны после 5 попыток\n"
        printf "Отладочная информация:\n"
        timeout 10 curl -v http://localhost:9100/metrics 2>&1 | head -10
        exit 1
    fi
done

# ИСПРАВЛЕННАЯ ПРОВЕРКА ANGIE - проверяем весь /etc/angie/
ANGIE_DETECTED=false
ANGIE_METRICS_PORT=""
ANGIE_CONFIG_INFO=""

# Проверяем, запущен ли процесс Angie
if pgrep -x "angie" > /dev/null; then
    printf "✓ Angie обнаружен\n"
    ANGIE_DETECTED=true
    
    # Проверяем конфигурацию Angie
    if [ -d "/etc/angie" ]; then
        printf "✓ Найдена директория конфигурации Angie: /etc/angie/\n"
        
        # Проверяем основные файлы конфигурации
        if [ -f "/etc/angie/angie.conf" ]; then
            ANGIE_CONFIG_INFO="Основной конфиг: /etc/angie/angie.conf"
        fi
        
        # Проверяем наличие prometheus_all.conf
        if [ -f "/etc/angie/prometheus_all.conf" ]; then
            ANGIE_CONFIG_INFO="$ANGIE_CONFIG_INFO, Шаблоны метрик: /etc/angie/prometheus_all.conf"
        fi
        
        # Проверяем папки с дополнительными конфигами
        for config_dir in "http.d" "sites-enabled" "conf.d"; do
            if [ -d "/etc/angie/$config_dir" ] && [ "$(ls -A /etc/angie/$config_dir 2>/dev/null | wc -l)" -gt 0 ]; then
                ANGIE_CONFIG_INFO="$ANGIE_CONFIG_INFO, Конфиги в: /etc/angie/$config_dir/"
            fi
        done
        
        printf "ℹ Конфигурация Angie: %s\n" "$ANGIE_CONFIG_INFO"
    fi
    
    # Проверяем метрики Prometheus на стандартных портах (с таймаутом)
    printf "Проверка доступности метрик Angie...\n"
    for port in 8080 80 443; do
        HTTP_CODE=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/prometheus" 2>/dev/null || echo "000")
        if [[ "$HTTP_CODE" =~ ^(200|204)$ ]]; then
            ANGIE_METRICS_PORT=$port
            printf "✓ Метрики Angie доступны на порту %s (HTTP %s)\n" "$port" "$HTTP_CODE"
            break
        elif [ "$HTTP_CODE" != "000" ]; then
            printf "⚠ Порт %s отвечает (HTTP %s), но метрики недоступны\n" "$port" "$HTTP_CODE"
        fi
    done
    
    if [ -z "$ANGIE_METRICS_PORT" ]; then
        printf "⚠ Angie найден, но метрики Prometheus не настроены\n"
        printf "  Для настройки метрик:\n\n"
        printf "  1. Убедитесь, что в /etc/angie/angie.conf в блоке http есть:\n"
        printf "     include /etc/angie/prometheus_all.conf;\n"
        printf "     include /etc/angie/http.d/*.conf;\n\n"
        printf "  2. Создайте файл /etc/angie/http.d/prometheus.conf:\n"
        printf "     server {\n"
        printf "         listen 127.0.0.1:8080;\n"
        printf "         location /prometheus { prometheus all; access_log off; }\n"
        printf "     }\n\n"
        printf "  3. Перезагрузите Angie: systemctl reload angie\n\n"
    fi
else
    printf "ℹ Angie не обнаружен\n"
fi

# Очищаем временные файлы
rm -rf /tmp/node_exporter-*

# Создаем файл с информацией о сервере
cat > /etc/monitoring-info.conf << INFO_EOF
# Информация о сервере для мониторинга
SERVER_NAME="$SERVER_NAME"
TAILSCALE_IP="$TAILSCALE_IP"
ARCH="$ARCH"
ANGIE_DETECTED="$ANGIE_DETECTED"
ANGIE_METRICS_PORT="$ANGIE_METRICS_PORT"
ANGIE_CONFIG_INFO="$ANGIE_CONFIG_INFO"
INSTALL_DATE="$(date -Iseconds)"
NODE_EXPORTER_VERSION="$NODE_EXPORTER_VER"
INFO_EOF

# ФИНАЛЬНЫЙ ВЫВОД (без буферизации)
exec 1>&1
printf "\n==================================================\n"
printf "🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!\n"
printf "==================================================\n"
printf "Сервер: %s\n" "$SERVER_NAME"
printf "IP адрес: %s\n" "$TAILSCALE_IP"
printf "Архитектура: %s (%s)\n" "$ARCH" "$ARCH_SUFFIX"
printf "Node Exporter: http://%s:9100/metrics\n" "$TAILSCALE_IP"

if [ "$ANGIE_DETECTED" = true ] && [ -n "$ANGIE_METRICS_PORT" ]; then
    printf "Angie метрики: http://%s:%s/prometheus\n" "$TAILSCALE_IP" "$ANGIE_METRICS_PORT"
fi

printf "\n📋 ДЛЯ ДОБАВЛЕНИЯ В ЦЕНТРАЛЬНЫЙ МОНИТОРИНГ:\n"
printf "На сервере Prometheus выполните:\n\n"

if [ -n "$ANGIE_METRICS_PORT" ]; then
    printf "curl -fsSL https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/add | bash -s \"%s\" \"%s\" \"%s\"\n" "$SERVER_NAME" "$TAILSCALE_IP" "$ANGIE_METRICS_PORT"
else
    printf "curl -fsSL https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/add | bash -s \"%s\" \"%s\"\n" "$SERVER_NAME" "$TAILSCALE_IP"
fi

printf "\n✅ Готово! Сервер готов к мониторингу.\n"

# Принудительно сбрасываем буферы
sync
