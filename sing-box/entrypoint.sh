#!/bin/bash
set -e

GATEWAY_TUN="${GATEWAY_TUN:-}"
CONFIG_FILE="${CONFIG_FILE:-/etc/sing-box/config.json}"

down_script() {
    echo "=== Получен сигнал завершения (SIGTERM/SIGINT). Останавливаем sing-box ==="

    if [ -n "${SINGBOX_PID:-}" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
        echo "Отправляем SIGTERM sing-box (PID $SINGBOX_PID)..."
        kill -TERM "$SINGBOX_PID" 2>/dev/null || true
        wait "$SINGBOX_PID" 2>/dev/null || true
    fi

    if [ -n "$GATEWAY_TUN" ]; then
        echo "=== Очистка маршрутов и правил ==="
        ip route del default dev "$GATEWAY_TUN" table singbox 2>/dev/null || true
        ip rule del fwmark 0x99 table singbox 2>/dev/null || true
    fi

    echo "=== sing-box остановлен, контейнер завершается ==="
}

trap 'down_script; exit 0' SIGTERM SIGINT

if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    echo "Ошибка: Переменная CONFIG_FILE не установлена или файл не найден!"
    exit 1
fi

echo "Запускаем sing-box..."
sing-box run -c "$CONFIG_FILE" &
SINGBOX_PID=$!

if [ -n "$GATEWAY_TUN" ]; then
    echo "Ожидаем появления интерфейса $GATEWAY_TUN..."

    timeout=30
    while [ $timeout -gt 0 ]; do
        if ip -o link show "$GATEWAY_TUN" >/dev/null 2>&1; then
            echo "Интерфейс $GATEWAY_TUN появился!"
            break
        fi
        sleep 0.5
        timeout=$((timeout - 1))
    done

    if ! ip -o link show "$GATEWAY_TUN" >/dev/null 2>&1; then
        echo "Ошибка: интерфейс $GATEWAY_TUN так и не появился за 30 секунд!"
        kill $SINGBOX_PID 2>/dev/null || true
        exit 1
    fi

    echo "Настраиваем маршрутизацию и NAT..."

    grep -q "singbox" /etc/iproute2/rt_tables || echo "99 singbox" >> /etc/iproute2/rt_tables

    ip route add default dev "$GATEWAY_TUN" table singbox 2>/dev/null || true
    ip rule add fwmark 0x99 table singbox 2>/dev/null || true

    ip -o -4 addr show | while read -r _ iface _ ip_cidr _; do
        iface=${iface%%@*}

        if [ "$iface" = "lo" ] || [ "$iface" = "$GATEWAY_TUN" ]; then
            continue
        fi

        ip=${ip_cidr%/*}
        prefix=${ip_cidr#*/}

        iptables -t mangle -A PREROUTING -i "$iface" -m addrtype ! --dst-type LOCAL -j MARK --set-mark 0x99  2>/dev/null || true
        iptables -A FORWARD -i "$iface" -o "$GATEWAY_TUN" -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -i "$GATEWAY_TUN" -o "$iface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        iptables -t nat -A POSTROUTING -s "$ip_cidr" -o "$GATEWAY_TUN" -j MASQUERADE 2>/dev/null || true
    done
fi

echo "sing-box запущен и маршруты настроены. Держим контейнер живым..."
wait $SINGBOX_PID