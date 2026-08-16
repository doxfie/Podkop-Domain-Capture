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

# Качаем рядом с целевым файлом и подменяем переименованием. Прямая запись
# в "$TARGET" при обрыве связи оставила бы обрезанный исполняемый файл вместо
# рабочей установки; mv в пределах одной ФС атомарен.
NEW_FILE="$(dirname "$TARGET")/.pdc.new"
rm -f "$NEW_FILE"

if ! wget -O "$NEW_FILE" "$SCRIPT_URL"; then
	echo "Ошибка: не удалось скачать скрипт."
	rm -f "$NEW_FILE"
	exit 1
fi

# Убеждаемся, что скачали скрипт целиком, а не страницу с ошибкой.
if ! head -n 1 "$NEW_FILE" | grep -q '^#!/bin/ash'; then
	echo "Ошибка: скачанный файл не похож на скрипт."
	rm -f "$NEW_FILE"
	exit 1
fi

if [ "$(wc -c < "$NEW_FILE")" -lt 10000 ]; then
	echo "Ошибка: скачанный файл обрезан."
	rm -f "$NEW_FILE"
	exit 1
fi

if ! chmod +x "$NEW_FILE"; then
	echo "Ошибка: не удалось сделать скрипт исполняемым."
	rm -f "$NEW_FILE"
	exit 1
fi

if ! mv "$NEW_FILE" "$TARGET"; then
	echo "Ошибка: не удалось установить скрипт в $TARGET"
	rm -f "$NEW_FILE"
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
