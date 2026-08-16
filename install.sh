#!/bin/ash

# Установщик Podkop Domain Capture для OpenWrt / BusyBox ash.
# Скачивает основной скрипт в /usr/bin/pdc и сразу запускает его.

SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/doxfie/Podkop-Domain-Capture/main/podkop-domain-capture.sh}"
TARGET="${TARGET:-/usr/bin/pdc}"

echo "Podkop Domain Capture installer"
echo "Скачиваю скрипт:"
echo "$SCRIPT_URL"
echo

if ! command -v wget >/dev/null 2>&1; then
	echo "Ошибка: wget не найден."
	echo "Установите wget или скачайте podkop-domain-capture.sh вручную."
	exit 1
fi

if ! wget -O "$TARGET" "$SCRIPT_URL"; then
	echo "Ошибка: не удалось скачать скрипт."
	exit 1
fi

if ! chmod +x "$TARGET"; then
	echo "Ошибка: не удалось сделать скрипт исполняемым: $TARGET"
	exit 1
fi

echo
echo "Скрипт установлен: $TARGET"
echo "Повторный запуск: pdc"
echo "Запускаю..."
echo

if [ -t 0 ]; then
	exec "$TARGET"
fi

if [ -c /dev/tty ]; then
	exec "$TARGET" < /dev/tty
fi

echo "Интерактивный ввод недоступен."
echo "Запустите скрипт вручную:"
echo "pdc"
