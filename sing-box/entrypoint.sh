#!/bin/bash
set -e

GATEWAY_TUN="${GATEWAY_TUN:-}"
CONFIG_FILE="${CONFIG_FILE:-/etc/sing-box/config.json}"

if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    echo "Ошибка: Переменная CONFIG_FILE не установлена или файл не найден!"
    exit 1
fi

if [ -n "$GATEWAY_TUN" ]; then
    TUN_ADDRESS=$(jq -r --arg tun "$GATEWAY_TUN" '
    .inbounds[]
    | select(.interface_name == $tun)
    | .address
    | map(select(test("^[0-9.]+/")))
    | .[0]
    | split("/")[0]
    ' "$CONFIG_FILE")

    if [ -z "$TUN_ADDRESS" ] || [ "$TUN_ADDRESS" = "null" ]; then
        echo "Ошибка: интерфейс $GATEWAY_TUN не найден или не содержит IPv4 адреса"
        exit 1
    fi

    grep -q "singbox" /etc/iproute2/rt_tables || echo "99 singbox" >> /etc/iproute2/rt_tables

    ip route add default dev "$GATEWAY_TUN" table singbox 2>/dev/null
    ip rule add fwmark 0x99 table singbox 2>/dev/null

    ip -o -4 addr show | while read -r _ iface _ ip_cidr _; do
        iface=${iface%%@*}

        [ "$iface" = "lo" ] && continue

        ip=${ip_cidr%/*}
        prefix=${ip_cidr#*/}

        iptables -t mangle -A PREROUTING -i "$iface" -m addrtype ! --dst-type LOCAL -j MARK --set-mark 0x99  2>/dev/null
        iptables -A FORWARD -i "$iface" -o "$GATEWAY_TUN" -j ACCEPT 2>/dev/null
        iptables -A FORWARD -i "$GATEWAY_TUN" -o "$iface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        iptables -t nat -A POSTROUTING -s "$ip_cidr" -o "$GATEWAY_TUN" -j MASQUERADE 2>/dev/null
    done

fi

sing-box run -c "$CONFIG_FILE"