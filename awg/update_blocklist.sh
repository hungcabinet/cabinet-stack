#!/bin/bash
set -euo pipefail

LIST_FILE=$1

if [[ -z "$LIST_FILE" ]] || [[ ! -f "$LIST_FILE" ]]; then
    echo "[!] Ошибка: файл со списком URL $LIST_FILE не найден."
    exit 1
fi

TMP_FILE="/tmp/blocklist_all.txt"
SET4="forward-block-v4"
SET6="forward-block-v6"
TMP4="${SET4}-tmp"
TMP6="${SET6}-tmp"

> "$TMP_FILE"

echo "[*] Читаем URLs из $LIST_FILE"

while IFS= read -r URL || [[ -n "$URL" ]]; do
    # Пропускаем комментарии и пустые строки
    [[ "$URL" =~ ^#.*$ ]] || [[ -z "$URL" ]] && continue

    echo "  -> $URL"
    if curl -fsSL "$URL" | grep -hvE '^\s*(#|$)' >> "$TMP_FILE"; then
        echo "     OK"
    else
        echo "     [!] Ошибка загрузки $URL — пропускаем"
    fi
done < "$LIST_FILE"

TOTAL=$(wc -l < "$TMP_FILE")
if [[ "$TOTAL" -eq 0 ]]; then
    echo "[!] ПРЕДУПРЕЖДЕНИЕ: загруженные списки пусты. Пропускаем обновление."
    exit 0
fi

echo "[*] Всего записей: $TOTAL"

# Разделяем IPv4 и IPv6
grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$TMP_FILE" > /tmp/ipv4.txt || true
grep -E ':' "$TMP_FILE" > /tmp/ipv6.txt || true

COUNT4=$(wc -l < /tmp/ipv4.txt)
COUNT6=$(wc -l < /tmp/ipv6.txt)

echo "[*] Найдено IPv4: $COUNT4"
echo "[*] Найдено IPv6: $COUNT6"

# Удаляем старые временные ipset, если они зависли
ipset destroy "$TMP4" 2>/dev/null || true
ipset destroy "$TMP6" 2>/dev/null || true

# Создаём новые временные ipset с запасом по размеру
(( COUNT4 > 0 )) && ipset create "$TMP4" hash:net family inet  maxelem $(( COUNT4 + 1000 ))
(( COUNT6 > 0 )) && ipset create "$TMP6" hash:net family inet6 maxelem $(( COUNT6 + 1000 ))

# Передаем подготовленные правила напрямую в ipset restore (экономит память по сравнению с Here-Doc)
echo "[*] Загружаем IPv4..."
(( COUNT4 > 0 )) && awk "{print \"add $TMP4 \" \$0 \" -exist\"}" /tmp/ipv4.txt | ipset restore

echo "[*] Загружаем IPv6..."
(( COUNT6 > 0 )) && awk "{print \"add $TMP6 \" \$0 \" -exist\"}" /tmp/ipv6.txt | ipset restore

# Проверка загруженных данных
(( COUNT4 > 0 )) && FINAL4=$(ipset list "$TMP4" | awk '/Number of entries:/ {print $4}') || FINAL4=0
(( COUNT6 > 0 )) && FINAL6=$(ipset list "$TMP6" | awk '/Number of entries:/ {print $4}') || FINAL6=0

echo "[*] Добавлено IPv4 адресов: $FINAL4"
echo "[*] Добавлено IPv6 адресов: $FINAL6"

# Проверяем наличие основных ipset, если их нет — создаём
ipset list "$SET4" &>/dev/null || ipset create "$SET4" hash:net family inet  maxelem 200000 2>/dev/null || true
ipset list "$SET6" &>/dev/null || ipset create "$SET6" hash:net family inet6 maxelem 200000 2>/dev/null || true

echo "[*] Атомарно заменяем ipset..."

(( COUNT4 > 0 )) && ipset swap "$TMP4" "$SET4" && ipset destroy "$TMP4"
(( COUNT6 > 0 )) && ipset swap "$TMP6" "$SET6" && ipset destroy "$TMP6"

echo "========================================"
echo "[✓] Обновление списков завершено."