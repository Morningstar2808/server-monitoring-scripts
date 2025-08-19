# Server Monitoring Scripts

Набор скриптов для автоматической установки и настройки системы мониторинга на базе Prometheus + Grafana + Node Exporter + Angie.

## Компоненты

- **Node Exporter** - сбор системных метрик
- **Angie** - метрики веб-сервера (автоопределение)
- **Prometheus** - централизованный сбор метрик
- **Grafana** - визуализация данных

## Использование

### 1. Установка мониторинга на новом сервере
curl -fsSL https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/install_monitoring.sh | bash
### Интерактивный режим:
wget https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/install_monitoring.sh && chmod +x install_monitoring.sh && ./install_monitoring.sh

### 2. Добавление сервера в центральный мониторинг

На сервере с Prometheus выполните:
curl -fsSL https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/add | bash -s "SERVER_NAME" "IP"

### 3. Удаление сервера из мониторинга
curl -fsSL https://raw.githubusercontent.com/Morningstar2808/server-monitoring-scripts/master/remove | bash -s "SERVER_NAME"
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
