#!/bin/bash

#############################################################################
# Скрипт для удаления сервера из мониторинга Prometheus и Grafana
#############################################################################

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Конфигурация
PROMETHEUS_URL="http://localhost:9090"
TARGETS_DIR="/etc/prometheus/targets"
BACKUP_DIR="/etc/prometheus/backups"

# Функция для логирования
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ОШИБКА:${NC} $1"
}

# Получение имени сервера
if [ $# -eq 0 ]; then
    # Если аргумент не передан, запросить интерактивно через /dev/tty
    echo -e "${YELLOW}=== Удаление сервера из мониторинга ===${NC}\n"

    # Показать доступные серверы
    echo "Доступные серверы в мониторинге:"
    echo ""
    for category in node cadvisor angie crowdsec remnawave; do
        if [ -d "$TARGETS_DIR/$category" ]; then
            servers=$(ls -1 "$TARGETS_DIR/$category/" 2>/dev/null | sed 's/\.yml$//' | grep -v "^$")
            if [ -n "$servers" ]; then
                echo -e "${GREEN}[$category]${NC}"
                echo "$servers" | sed 's/^/  - /'
            fi
        fi
    done
    echo ""

    # Чтение с /dev/tty для интерактивного режима
    if [ -t 0 ]; then
        read -p "Введите имя сервера для удаления: " SERVER_NAME
    else
        # Если stdin не терминал (запуск через curl), использовать /dev/tty
        read -p "Введите имя сервера для удаления: " SERVER_NAME < /dev/tty
    fi

    if [ -z "$SERVER_NAME" ]; then
        error "Имя сервера не может быть пустым!"
        exit 1
    fi
else
    SERVER_NAME="$1"
fi

echo -e "\n${YELLOW}=== Начало удаления сервера: $SERVER_NAME ===${NC}\n"

# Создание директории для бэкапов
log "Создание резервной копии..."
mkdir -p "$BACKUP_DIR"
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="$BACKUP_DIR/server_${SERVER_NAME}_${BACKUP_TIMESTAMP}"
mkdir -p "$BACKUP_PATH"

# Поиск и резервное копирование файлов конфигурации
log "Поиск конфигурационных файлов для сервера $SERVER_NAME..."
FOUND_FILES=0

for category in node cadvisor angie crowdsec remnawave; do
    TARGET_FILE="$TARGETS_DIR/$category/${SERVER_NAME}.yml"
    if [ -f "$TARGET_FILE" ]; then
        log "Найден: $TARGET_FILE"
        cp "$TARGET_FILE" "$BACKUP_PATH/"
        FOUND_FILES=$((FOUND_FILES + 1))
    fi
done

if [ $FOUND_FILES -eq 0 ]; then
    error "Файлы конфигурации для сервера $SERVER_NAME не найдены!"
    echo "Проверьте доступные серверы выше."
    exit 1
fi

log "Найдено и скопировано $FOUND_FILES файл(ов) в $BACKUP_PATH"

# Проверка активных целей в Prometheus
log "Проверка активных целей в Prometheus..."
if curl -s "$PROMETHEUS_URL/api/v1/targets" | jq -e ".data.activeTargets[] | select(.labels.nodename==\"$SERVER_NAME\")" > /dev/null 2>&1; then
    log "Сервер $SERVER_NAME найден в активных целях Prometheus"
else
    log "Сервер $SERVER_NAME не найден в активных целях (возможно уже удален)"
fi

# Получение instance для удаления метрик
log "Получение информации об instance сервера..."
INSTANCE=$(curl -s "$PROMETHEUS_URL/api/v1/targets" | jq -r ".data.activeTargets[] | select(.labels.nodename==\"$SERVER_NAME\") | .labels.instance" | head -n1)

if [ -n "$INSTANCE" ] && [ "$INSTANCE" != "null" ]; then
    log "Найден instance: $INSTANCE"
else
    log "Instance не найден, будем использовать только nodename"
fi

# Удаление файлов конфигурации
log "Удаление конфигурационных файлов..."
for category in node cadvisor angie crowdsec remnawave; do
    TARGET_FILE="$TARGETS_DIR/$category/${SERVER_NAME}.yml"
    if [ -f "$TARGET_FILE" ]; then
        rm -f "$TARGET_FILE"
        log "Удален: $TARGET_FILE"
    fi
done

# Перезагрузка конфигурации Prometheus
log "Перезагрузка конфигурации Prometheus..."
if curl -X POST "$PROMETHEUS_URL/-/reload" > /dev/null 2>&1; then
    log "Конфигурация Prometheus успешно перезагружена"
else
    error "Не удалось перезагрузить Prometheus через API"
    log "Попытка перезагрузки через systemctl..."
    if systemctl reload prometheus; then
        log "Prometheus перезагружен через systemctl"
    else
        error "Не удалось перезагрузить Prometheus"
        exit 1
    fi
fi

# Ожидание применения изменений
log "Ожидание применения изменений (5 секунд)..."
sleep 5

# Удаление метрик из базы данных Prometheus
log "Удаление метрик из базы данных Prometheus..."

# Удаление по nodename
log "Удаление метрик по nodename=$SERVER_NAME..."
curl -X POST -g "$PROMETHEUS_URL/api/v1/admin/tsdb/delete_series?match[]={nodename=\"$SERVER_NAME\"}" > /dev/null 2>&1

# Удаление по instance (если найден)
if [ -n "$INSTANCE" ] && [ "$INSTANCE" != "null" ]; then
    log "Удаление метрик по instance=$INSTANCE..."
    curl -X POST -g "$PROMETHEUS_URL/api/v1/admin/tsdb/delete_series?match[]={instance=\"$INSTANCE\"}" > /dev/null 2>&1
fi

# Удаление по server_name (альтернативная метка)
log "Удаление метрик по server_name=$SERVER_NAME..."
curl -X POST -g "$PROMETHEUS_URL/api/v1/admin/tsdb/delete_series?match[]={server_name=\"$SERVER_NAME\"}" > /dev/null 2>&1

# Очистка tombstones
log "Очистка tombstones для освобождения места..."
if curl -X POST "$PROMETHEUS_URL/api/v1/admin/tsdb/clean_tombstones" > /dev/null 2>&1; then
    log "Tombstones успешно очищены"
else
    error "Не удалось очистить tombstones"
fi

# Перезапуск Grafana для очистки кэша
log "Перезапуск Grafana для очистки кэша..."
if systemctl restart grafana-server; then
    log "Grafana успешно перезапущена"
    log "Ожидание запуска Grafana (10 секунд)..."
    sleep 10
else
    error "Не удалось перезапустить Grafana"
fi

# Проверка результата
log "Проверка удаления сервера из мониторинга..."
if curl -s "$PROMETHEUS_URL/api/v1/targets" | jq -e ".data.activeTargets[] | select(.labels.nodename==\"$SERVER_NAME\")" > /dev/null 2>&1; then
    error "Сервер $SERVER_NAME всё ещё присутствует в активных целях!"
    echo "Подождите 5-10 минут для полного удаления устаревших метрик"
else
    log "Сервер $SERVER_NAME успешно удален из активных целей"
fi

# Финальная информация
echo ""
echo -e "${GREEN}=== Удаление завершено ===${NC}"
echo "Сервер: $SERVER_NAME"
echo "Удалено файлов: $FOUND_FILES"
echo "Резервная копия: $BACKUP_PATH"
echo ""
echo "Рекомендации:"
echo "1. Проверьте веб-интерфейс Prometheus: $PROMETHEUS_URL/targets"
echo "2. Обновите дашборды Grafana (Ctrl+Shift+R)"
echo "3. Подождите 5-10 минут для полного удаления метрик из памяти"
echo ""
echo "Для восстановления сервера скопируйте файлы из:"
echo "$BACKUP_PATH"
echo ""

exit 0
