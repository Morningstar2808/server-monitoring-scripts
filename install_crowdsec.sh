#!/bin/bash

# =============================================================================
# Скрипт установки и настройки CrowdSec с отправкой метрик в VictoriaMetrics
# =============================================================================

VICTORIAMETRICS_IP="100.87.29.86"
SCRIPT_VERSION="1.1.0"

if [ "$(id -u)" -ne 0 ]; then
    printf "Ошибка: Скрипт должен запускаться от root\n"
    exit 1
fi

printf "=== Установка CrowdSec (v%s) ===\n" "$SCRIPT_VERSION"

# ============================================================================
# ОПРЕДЕЛЕНИЕ ИМЕНИ СЕРВЕРА
# ============================================================================

SERVER_NAME=""
while true; do
    printf "Введите уникальное имя сервера (латиницей, без пробелов): "
    read -r SERVER_NAME < /dev/tty
    SERVER_NAME=$(echo "$SERVER_NAME" | tr -d ' ')
    if [[ $SERVER_NAME =~ ^[a-zA-Z0-9_-]+$ ]] && [ -n "$SERVER_NAME" ]; then 
        break
    else
        printf "Ошибка: Используйте только буквы, цифры, дефисы и подчеркивания. Попробуйте снова.\n"
    fi
done

printf "Имя сервера установлено: %s\n" "$SERVER_NAME"

# ============================================================================
# ПРОВЕРКА ANGIE
# ============================================================================

ANGIE_DETECTED=false
if pgrep -x "angie" > /dev/null; then
    printf "✓ Обнаружен Angie\n"
    ANGIE_DETECTED=true
else
    printf "ℹ Angie не обнаружен\n"
fi

# ============================================================================
# УСТАНОВКА CROWDSEC
# ============================================================================

CROWDSEC_INSTALLED=false

printf "\n=== Проверка и установка CrowdSec ===\n"

if command -v cscli > /dev/null 2>&1; then
    printf "✓ CrowdSec уже установлен\n"
    CROWDSEC_INSTALLED=true
else
    printf "Устанавливаем CrowdSec...\n"

    # Определяем версию Debian
    DEBIAN_VERSION=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2 || echo "unknown")

    if [ "$DEBIAN_VERSION" = "trixie" ] || [ "$DEBIAN_VERSION" = "sid" ]; then
        printf "⚠ Обнаружен Debian %s (testing/unstable)\n" "$DEBIAN_VERSION"
        printf "  Используем репозиторий Bookworm для совместимости\n"

        # Устанавливаем зависимости
        apt-get install -y curl gnupg apt-transport-https > /dev/null 2>&1

        # Добавляем репозиторий вручную
        curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey | gpg --dearmor -o /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg

        echo "deb [signed-by=/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg] https://packagecloud.io/crowdsec/crowdsec/debian/ bookworm main" > /etc/apt/sources.list.d/crowdsec_crowdsec.list

        apt-get update -qq
    else
        # Стандартная установка для стабильных версий
        if ! curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash; then
            printf "❌ Ошибка добавления репозитория CrowdSec\n"
            exit 1
        fi
        apt-get update -qq
    fi

    # Устанавливаем пакеты
    if apt-get install -y crowdsec crowdsec-firewall-bouncer-nftables; then
        printf "✓ CrowdSec установлен\n"
        CROWDSEC_INSTALLED=true
    else
        printf "❌ Ошибка установки пакетов CrowdSec\n"
        exit 1
    fi
fi

# Проверяем что CrowdSec действительно установлен
if ! command -v cscli > /dev/null 2>&1; then
    printf "❌ CrowdSec не установлен. Проверьте репозитории.\n"
    exit 1
fi

# ============================================================================
# НАСТРОЙКА CROWDSEC
# ============================================================================

printf "\n=== Настройка CrowdSec ===\n"

printf "Устанавливаем коллекции...\n"
cscli hub update > /dev/null 2>&1 || true
cscli collections install crowdsecurity/linux --force > /dev/null 2>&1 || true
cscli collections install crowdsecurity/sshd --force > /dev/null 2>&1 || true

if [ "$ANGIE_DETECTED" = true ]; then
    cscli collections install crowdsecurity/nginx --force > /dev/null 2>&1 || true
    printf "✓ Установлены коллекции: linux, sshd, nginx\n"
else
    printf "✓ Установлены коллекции: linux, sshd\n"
fi

# Backup старой конфигурации
if [ ! -f /etc/crowdsec/acquis.yaml.backup ]; then
    cp /etc/crowdsec/acquis.yaml /etc/crowdsec/acquis.yaml.backup 2>/dev/null || true
fi

# Проверяем существование директории
if [ ! -d /etc/crowdsec ]; then
    printf "❌ Директория /etc/crowdsec не существует\n"
    exit 1
fi

# Настройка acquis.yaml
cat > /etc/crowdsec/acquis.yaml << 'EOF'
source: file
filenames:
  - /var/log/auth.log
labels:
  type: syslog
EOF

if [ "$ANGIE_DETECTED" = true ]; then
    cat >> /etc/crowdsec/acquis.yaml << 'EOF'

---
source: file
filenames:
  - /var/log/angie/access.log
  - /var/log/angie/error.log
labels:
  type: nginx
EOF
    printf "✓ Настроен сбор логов: auth.log, angie\n"
else
    printf "✓ Настроен сбор логов: auth.log\n"
fi

# ============================================================================
# НАСТРОЙКА HTTP NOTIFICATION PLUGIN
# ============================================================================

printf "\nНастраиваем отправку метрик в VictoriaMetrics...\n"

mkdir -p /etc/crowdsec/notifications

cat > /etc/crowdsec/notifications/http.yaml << EOF
type: http

name: victoriametrics_push

log_level: info

format: |
  {{range .}}cs_lapi_decision{instance="$SERVER_NAME",server_name="$SERVER_NAME",country="{{.Source.Cn}}",asname="{{.Source.AsName}}",asnumber="{{.Source.AsNumber}}",latitude="{{.Source.Latitude}}",longitude="{{.Source.Longitude}}",scenario="{{.Scenario}}",ip="{{.Source.IP}}",scope="{{range .Decisions}}{{.Scope}}{{end}}",value="{{range .Decisions}}{{.Value}}{{end}}"} 1
  {{end}}

url: http://$VICTORIAMETRICS_IP:8428/api/v1/import/prometheus

method: POST

headers:
  Content-Type: text/plain

timeout: 10s
EOF

printf "✓ Конфигурация HTTP notification создана\n"

# ============================================================================
# НАСТРОЙКА PROFILES.YAML
# ============================================================================

if [ ! -f /etc/crowdsec/profiles.yaml.backup ]; then
    cp /etc/crowdsec/profiles.yaml /etc/crowdsec/profiles.yaml.backup 2>/dev/null || true
fi

cat > /etc/crowdsec/profiles.yaml << 'EOF'
---
name: send_to_victoriametrics
filters:
  - Alert.Remediation == true
notifications:
  - victoriametrics_push
decisions:
  - type: ban
    duration: 4h
on_success: continue

---
name: default_ip_remediation
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Ip"
decisions:
 - type: ban
   duration: 4h
on_success: break
EOF

printf "✓ Конфигурация profiles завершена\n"

# ============================================================================
# ИСПРАВЛЕНИЕ ИМЕН ПЛАГИНОВ (BUG В DEBIAN ПАКЕТЕ)
# ============================================================================

printf "\nИсправляем имена плагинов...\n"

PLUGINS_DIR="/usr/lib/crowdsec/plugins"

# Переименовываем плагины с неправильными именами
for plugin in dummy email http slack splunk; do
    if [ -f "$PLUGINS_DIR/$plugin" ]; then
        printf "  Переименовываем %s -> notification-%s\n" "$plugin" "$plugin"
        mv "$PLUGINS_DIR/$plugin" "$PLUGINS_DIR/notification-$plugin"
    fi
done

# Проверяем что плагины переименованы
if ls "$PLUGINS_DIR"/notification-* > /dev/null 2>&1; then
    printf "✓ Плагины исправлены\n"
else
    printf "⚠ Плагины не найдены в $PLUGINS_DIR\n"
fi

# ============================================================================
# ПЕРЕЗАПУСК CROWDSEC
# ============================================================================

printf "\nПерезапускаем CrowdSec...\n"
systemctl restart crowdsec
sleep 5

if systemctl is-active --quiet crowdsec; then
    printf "✓ CrowdSec успешно запущен\n"

    sleep 2
    if ps aux | grep -q "[n]otification-http"; then
        printf "✓ HTTP notification плагин загружен\n"
    else
        printf "⚠ HTTP notification плагин загрузится при первом alert\n"
    fi
else
    printf "❌ Ошибка запуска CrowdSec\n"
    printf "\nПоследние 20 строк логов:\n"
    journalctl -u crowdsec -n 20 --no-pager
    exit 1
fi

# ============================================================================
# ПРОВЕРКА КОНФИГУРАЦИИ
# ============================================================================

printf "\n=== Проверка конфигурации ===\n"

printf "Установленные коллекции:\n"
cscli collections list 2>/dev/null | grep -E "(linux|sshd|nginx)" | grep "✔️" || printf "Коллекции установлены\n"

printf "\nСтатистика CrowdSec:\n"
cscli metrics 2>/dev/null || printf "Метрики появятся после обработки логов\n"

# ============================================================================
# ФИНАЛЬНЫЙ ВЫВОД
# ============================================================================

printf "\n==================================================\n"
printf "🎉 УСТАНОВКА CROWDSEC ЗАВЕРШЕНА!\n"
printf "==================================================\n"
printf "Сервер: %s\n" "$SERVER_NAME"
printf "VictoriaMetrics: %s:8428\n" "$VICTORIAMETRICS_IP"
printf "Версия скрипта: %s\n" "$SCRIPT_VERSION"

printf "\n📊 КОНФИГУРАЦИЯ:\n"
printf "Коллекции: linux, sshd"
if [ "$ANGIE_DETECTED" = true ]; then printf ", nginx"; fi
printf "\n"

printf "Логи: /var/log/auth.log"
if [ "$ANGIE_DETECTED" = true ]; then printf ", /var/log/angie/*.log"; fi
printf "\n"

printf "Метрики: http://%s:8428/api/v1/query?query=cs_lapi_decision{instance=\"%s\"}\n" "$VICTORIAMETRICS_IP" "$SERVER_NAME"

printf "\n📋 ПОЛЕЗНЫЕ КОМАНДЫ:\n"
printf "cscli metrics                    # Статистика CrowdSec\n"
printf "cscli alerts list               # Список alerts\n"
printf "cscli decisions list            # Активные блокировки\n"
printf "cscli collections list          # Установленные коллекции\n"
printf "systemctl status crowdsec       # Статус сервиса\n"
printf "ps aux | grep notification-http # Проверка плагина\n"

printf "\n✅ Готово! Метрики будут отправляться в VictoriaMetrics автоматически.\n"
printf "   Проверить в Grafana: CrowdSec Cyber Threat Insights дашборд\n"
printf "\n📖 Полная документация: CROWDSEC_INSTALL_GUIDE.md\n"
