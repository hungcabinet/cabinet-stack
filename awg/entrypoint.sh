#!/bin/bash
set -e

# Переменные из компоуз файла (по-умолчанию клиент)
MODE="${MODE:-client}"
CONFIG_FILE="${CONFIG_FILE:-/etc/amnezia/awg0.conf}"
FORWARD_BLOCK_LIST="${FORWARD_BLOCK_LIST}"
OUTBOUND_IP="${OUTBOUND_IP:-}"

if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    echo "Ошибка: Переменная CONFIG_FILE не установлена или файл не найден!"
    exit 1
fi

CONF_FILENAME=$(basename "$CONFIG_FILE")
OUTPUT_DIR="/etc/amnezia/run"
OUTPUT_CONF="$OUTPUT_DIR/$CONF_FILENAME"
IFACE="${CONF_FILENAME%.conf}"

iptables -P FORWARD DROP
ip6tables -P FORWARD DROP || true

mkdir -p "$OUTPUT_DIR"

if [ "$MODE" = "server" ]; then
    # Инициализация скрипта блока, если передан список
    if [ -n "$FORWARD_BLOCK_LIST" ] && [ -f "$FORWARD_BLOCK_LIST" ]; then
        echo "Обнаружен список источников блокировок: $FORWARD_BLOCK_LIST. Запускаем обновление..."

        # Выполняем первичное обновление списков до поднятия интерфейса
        /usr/local/bin/update_blocklist.sh "$FORWARD_BLOCK_LIST"

        # Настройка ежесуточного cron'a (в 00:00). Вывод логов направляем в stdout докера
        echo "0 0 * * * root /usr/local/bin/update_blocklist.sh $FORWARD_BLOCK_LIST > /proc/1/fd/1 2>&1" > /etc/cron.d/update_blocklist
        chmod 0644 /etc/cron.d/update_blocklist
        cron
    else
        echo "Файл источников FORWARD_BLOCK_LIST не задан или отсутствует. Создаем пустые списки."
        # Если списка нет, создаем пустые сеты, чтобы iptables в up.sh не упал с ошибкой при запуске
        ipset create forward-block-v4 hash:net family inet maxelem 200000 2>/dev/null || true
        ipset create forward-block-v6 hash:net family inet6 maxelem 200000 2>/dev/null || true
    fi
fi

# 1. Запуск питон скрипта (парсинг и генерация up/down скриптов)
if [ -n "$OUTBOUND_IP" ]; then
    python3 /usr/local/bin/process_config.py --mode "$MODE" --input "$CONFIG_FILE" --output-dir "$OUTPUT_DIR" --outbound-ip "$OUTBOUND_IP"
else
    python3 /usr/local/bin/process_config.py --mode "$MODE" --input "$CONFIG_FILE" --output-dir "$OUTPUT_DIR"
fi

# 2. Функция безопасного завершения
down_script() {
    echo "Получен сигнал остановки, откатываем интерфейс $IFACE..."
    # awg-quick down сам вызовет PostDown={output-dir}/down.sh, но оборачиваем в || true чтобы не прервалось
    awg-quick down "$OUTPUT_CONF" || true

    # Для гарантии (т.к. скрипт идемпотентный, не страшно вызвать его 2 раза)
    if [ -x "$OUTPUT_DIR/down.sh" ]; then
        "$OUTPUT_DIR/down.sh" "$IFACE" || true
    fi
}

# 3. Поднимаем туннель
awg-quick up "$OUTPUT_CONF"

# Перехватываем сигналы остановки от Docker для gracefull shutdown
trap 'down_script; exit 0' SIGTERM SIGINT

echo "AmneziaWG контейнер успешно запущен в режиме: $MODE"

# 4. Удержание контейнера запущенным
tail -f /dev/null & wait $!