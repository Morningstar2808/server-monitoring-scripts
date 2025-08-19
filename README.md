# Server Monitoring Scripts

Набор скриптов для автоматической установки и настройки системы мониторинга на базе Prometheus + Grafana + Node Exporter + Angie.

## Компоненты

- **Node Exporter** - сбор системных метрик
- **Angie** - метрики веб-сервера (автоопределение)
- **Prometheus** - централизованный сбор метрик
- **Grafana** - визуализация данных

## Использование

### 1. Установка мониторинга на новом сервере
wget https://raw.githubusercontent.com/YOURUSERNAME/server-monitoring-scripts/main/install_monitoring.sh
chmod +x install_monitoring.sh
./install_monitoring.sh

### 2. Добавление сервера в центральный мониторинг

На сервере с Prometheus выполните:
wget https://raw.githubusercontent.com/YOURUSERNAME/server-monitoring-scripts/main/add_server_to_monitoring.sh
chmod +x add_server_to_monitoring.sh
./add_server_to_monitoring.sh SERVER_NAME TAILSCALE_IP [ANGIE_PORT]

### 3. Удаление сервера из мониторинга
wget https://raw.githubusercontent.com/YOURUSERNAME/server-monitoring-scripts/main/remove_server_from_monitoring.sh
chmod +x remove_server_from_monitoring.sh
./remove_server_from_monitoring.sh SERVER_NAME
## Требования

- Linux с systemd
- Права root
- Tailscale (опционально)
- curl, wget

## Поддерживаемые архитектуры

- x86_64 (amd64)
- ARM64 (aarch64)
- ARMv7
- ARMv6

## Автоматическое обнаружение

Скрипт автоматически:
- Определяет архитектуру системы
- Находит Tailscale IP
- Обнаруживает установленный Angie
- Настраивает соответствующие метрики
