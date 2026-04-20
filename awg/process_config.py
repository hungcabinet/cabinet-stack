import sys
import os
import re
import logging
import ipaddress
import shutil
import argparse
import subprocess

logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')

def is_ip(addr):
    try:
        ipaddress.ip_address(addr)
        return True
    except ValueError:
        return False

def get_default_gateway():
    cmd = ["ip", "route", "show", "default"]
    output = subprocess.check_output(cmd, text=True)

    for line in output.splitlines():
        parts = line.split()
        if "default" in parts:
            gw_index = parts.index("via") + 1
            return parts[gw_index]

    return "127.0.0.1"

def get_interface_by_gateway(gateway_ip: str) -> str:
    try:
        result = subprocess.run(
            ['ip', '-o', 'route', 'get', gateway_ip],
            capture_output=True,
            text=True,
            check=True
        )

        output = result.stdout.strip()

        match = re.search(r'\bdev\s+(\S+)', output)

        if match:
            return match.group(1)
        else:
            raise ValueError(f"Не удалось извлечь интерфейс из вывода: {output}")

    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Ошибка выполнения ip route get: {e}")
    except FileNotFoundError:
        raise RuntimeError("Команда 'ip' не найдена. Убедись, что ты в Linux-контейнере с iproute2.")

def process_config(mode, input_file, output_dir, outbound_ip=None):
    os.makedirs(output_dir, exist_ok=True)
    filename = os.path.basename(input_file)
    output_file = os.path.join(output_dir, filename)

    dns_list = []
    addresses =[]

    with open(input_file, 'r') as f:
        lines = f.readlines()

    in_interface = False
    new_lines =[]

    for line in lines:
        stripped = line.strip()

        # Обнаружение секций
        if stripped.startswith('[') and stripped.endswith(']'):
            if in_interface:
                # Вставляем свои параметры перед выходом из секции [Interface]
                new_lines.append("FwMark = 51820\n")
                if mode == 'client':
                    new_lines.append("Table = off\n")
                new_lines.append(f"PostUp = {output_dir}/up.sh %i\n")
                new_lines.append(f"PostDown = {output_dir}/down.sh %i\n")
                in_interface = False

            if stripped == '[Interface]':
                in_interface = True

        # Парсинг параметров
        match = re.match(r'^([a-zA-Z0-9_\-]+)\s*=\s*(.*)$', stripped)
        if match:
            key, val = match.groups()
            key_lower = key.lower()

            if key_lower == 'saveconfig':
                continue # Удаляем отовсюду

            if in_interface:
                if key_lower.startswith('post'):
                    continue
                if key_lower == 'fwmark':
                    continue
                if key_lower == 'table' and mode == 'client':
                    continue
                if key_lower == 'dns':
                    for d in val.split(','):
                        d = d.strip()
                        if is_ip(d):
                            dns_list.append(d)
                    continue
                if key_lower == 'address':
                    for a in val.split(','):
                        a = a.strip()
                        addresses.append(a)

        new_lines.append(line)

    # Если файл закончился, а мы все еще в [Interface]
    if in_interface:
        new_lines.append("FwMark = 51820\n")
        if mode == 'client':
            new_lines.append("Table = off\n")
        new_lines.append(f"PostUp = {output_dir}/up.sh %i\n")
        new_lines.append(f"PostDown = {output_dir}/down.sh %i\n")

    with open(output_file, 'w') as f:
        f.writelines(new_lines)

    # Генерация скриптов поднятия/опускания
    if mode == 'client':
        generate_client_scripts(output_dir, dns_list, addresses)
    elif mode == 'server':
        generate_server_scripts(output_dir, dns_list, addresses, outbound_ip)

def generate_dns_files(dns_list, old_resolv, new_resolv):
    orig_resolv = '/etc/resolv.conf'

    if os.path.exists(orig_resolv):
        shutil.copy(orig_resolv, old_resolv)
        with open(orig_resolv, 'r') as f:
            resolv_lines = f.readlines()
    else:
        open(old_resolv, 'a').close()
        resolv_lines =[]

    orig_dns =[]
    for line in resolv_lines:
        if line.strip().startswith('nameserver'):
            parts = line.strip().split()
            if len(parts) > 1:
                orig_dns.append(parts[1])

    with open(new_resolv, 'w') as f:
        for d in dns_list:
            f.write(f"nameserver {d}\n")
        for line in resolv_lines:
            f.write(line)

    orig_set = set(orig_dns)
    new_added_dns = [d for d in dns_list if d not in orig_set]

    return orig_dns, new_added_dns

def get_interfaces():
    result = subprocess.run(
        ["ip", "-o", "-4", "addr", "show"],
        capture_output=True,
        text=True,
        check=True
    )

    interfaces = []

    for line in result.stdout.splitlines():
        parts = line.split()

        iface = parts[1].split("@")[0]

        if iface == "lo":
            continue

        ip_cidr = parts[3]

        interface = ipaddress.ip_interface(ip_cidr)

        interfaces.append((
            iface,
            str(interface.ip),
            interface.network.prefixlen,
            str(interface.network)
        ))

    return interfaces

def generate_client_scripts(output_dir, dns_list, addresses):
    old_resolv = os.path.join(output_dir, 'resolv.old.conf')
    new_resolv = os.path.join(output_dir, 'resolv.new.conf')

    generate_dns_files(dns_list, old_resolv, new_resolv)

    up_sh = os.path.join(output_dir, 'up.sh')
    down_sh = os.path.join(output_dir, 'down.sh')

    with open(up_sh, 'w') as up, open(down_sh, 'w') as down:
        up.write("#!/bin/bash\nIFACE=$1\n")
        down.write("#!/bin/bash\nIFACE=$1\n")

        up.write(f"cp {new_resolv} /etc/resolv.conf\n")
        down.write(f"cp {old_resolv} /etc/resolv.conf\n")

        up.write('grep -q "awg" /etc/iproute2/rt_tables || echo "99 awg" >> /etc/iproute2/rt_tables\n')

        up.write(f"ip route delete default dev $IFACE table awg 2>/dev/null || true\n")
        up.write(f"ip route add default dev $IFACE table awg 2>/dev/null\n")
        down.write(f"ip route delete default dev $IFACE table awg 2>/dev/null || true\n")
        down.write(f"ip route flush table awg 2>/dev/null || true\n")

        up.write(f"ip rule del fwmark 0x99 table awg 2>/dev/null || true\n")
        up.write(f"ip rule add fwmark 0x99 table awg 2>/dev/null\n")
        down.write(f"ip rule del fwmark 0x99 table awg 2>/dev/null || true\n")

        for iface, ip, cidr, network in get_interfaces():
            expr = f"PREROUTING -i {iface} -m addrtype ! --dst-type LOCAL -j MARK --set-mark 0x99"
            up.write(f"iptables -t mangle -D {expr} 2>/dev/null || true\n")
            up.write(f"iptables -t mangle -A {expr} 2>/dev/null\n")
            down.write(f"iptables -t mangle -D {expr} 2>/dev/null || true\n")

            expr = f"FORWARD -i {iface} -o $IFACE -j ACCEPT"
            up.write(f"iptables -D {expr} 2>/dev/null || true\n")
            up.write(f"iptables -A {expr} 2>/dev/null\n")
            down.write(f"iptables -D {expr} 2>/dev/null || true\n")

            expr = f"FORWARD -i $IFACE -o {iface} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
            up.write(f"iptables -D {expr} 2>/dev/null || true\n")
            up.write(f"iptables -A {expr} 2>/dev/null\n")
            down.write(f"iptables -D {expr} 2>/dev/null || true\n")

            expr = f"POSTROUTING -s {network} -o $IFACE -j MASQUERADE"
            up.write(f"iptables -t nat -D {expr} 2>/dev/null || true\n")
            up.write(f"iptables -t nat -A {expr} 2>/dev/null\n")
            down.write(f"iptables -t nat -D {expr} 2>/dev/null || true\n")

        up.write(f"cp {new_resolv} /etc/resolv.conf\n")
        down.write(f"cp {old_resolv} /etc/resolv.conf\n")

    os.chmod(up_sh, 0o755)
    os.chmod(down_sh, 0o755)

def generate_server_scripts(output_dir, dns_list, addresses, outbound_ip=None):
    old_resolv = os.path.join(output_dir, 'resolv.old.conf')
    new_resolv = os.path.join(output_dir, 'resolv.new.conf')

    generate_dns_files(dns_list, old_resolv, new_resolv)

    up_sh = os.path.join(output_dir, 'up.sh')
    down_sh = os.path.join(output_dir, 'down.sh')

    with open(up_sh, 'w') as up, open(down_sh, 'w') as down:
        up.write("#!/bin/bash\nIFACE=$1\n")
        down.write("#!/bin/bash\nIFACE=$1\n")

        up.write(f"cp {new_resolv} /etc/resolv.conf\n")
        down.write(f"cp {old_resolv} /etc/resolv.conf\n")

        default_gw_ip = get_default_gateway();
        out_dev = get_interface_by_gateway(default_gw_ip)
        if outbound_ip:
            out_dev = get_interface_by_gateway(outbound_ip)

            up.write('grep -q "awg" /etc/iproute2/rt_tables || echo "99 awg" >> /etc/iproute2/rt_tables\n')

            up.write(f"ip -4 route del default via {outbound_ip} dev {out_dev} table awg 2>/dev/null || true\n")
            up.write(f"ip -4 route add default via {outbound_ip} dev {out_dev} table awg 2>/dev/null\n")
            down.write(f"ip -4 route del default via {outbound_ip} dev {out_dev} table awg 2>/dev/null || true\n")
            down.write(f"ip -4 route flush table awg 2>/dev/null || true\n")

            up.write(f"ip -4 rule del fwmark 0x99 table awg 2>/dev/null || true\n")
            up.write(f"ip -4 rule add fwmark 0x99 table awg 2>/dev/null\n")
            down.write(f"ip -4 rule del fwmark 0x99 table awg 2>/dev/null || true\n")

            expr = f"PREROUTING -i $IFACE -m addrtype ! --dst-type LOCAL -j MARK --set-mark 0x99"
            up.write(f"iptables -t mangle -D {expr} 2>/dev/null || true\n")
            up.write(f"iptables -t mangle -A {expr} 2>/dev/null\n")
            down.write(f"iptables -t mangle -D {expr} 2>/dev/null || true\n")

        exprI = f"FORWARD 1 -i $IFACE -m set --match-set forward-block-v4 dst -j DROP"
        expr = f"FORWARD -i $IFACE -m set --match-set forward-block-v4 dst -j DROP"
        up.write(f"iptables -D {expr} 2>/dev/null || true\n")
        up.write(f"iptables -I {exprI} 2>/dev/null\n")
        down.write(f"iptables -D {expr} 2>/dev/null || true\n")

        expr = f"FORWARD -i $IFACE -o {out_dev} -j ACCEPT"
        up.write(f"iptables -D {expr} 2>/dev/null || true\n")
        up.write(f"iptables -A {expr} 2>/dev/null\n")
        down.write(f"iptables -D {expr} 2>/dev/null || true\n")

        expr = f"FORWARD -i {out_dev} -o $IFACE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
        up.write(f"iptables -D {expr} 2>/dev/null || true\n")
        up.write(f"iptables -A {expr} 2>/dev/null\n")
        down.write(f"iptables -D {expr} 2>/dev/null || true\n")

        for address in addresses:
            expr = f"POSTROUTING -s {address} -o {out_dev} -j MASQUERADE"
            up.write(f"iptables -t nat -D {expr} 2>/dev/null || true\n")
            up.write(f"iptables -t nat -A {expr} 2>/dev/null\n")
            down.write(f"iptables -t nat -D {expr} 2>/dev/null || true\n")

    os.chmod(up_sh, 0o755)
    os.chmod(down_sh, 0o755)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--mode', required=True, choices=['client', 'server'])
    parser.add_argument('--input', required=True)
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--outbound-ip', required=False, default=None)
    args = parser.parse_args()

    process_config(args.mode, args.input, args.output_dir, args.outbound_ip)