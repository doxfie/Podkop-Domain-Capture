#!/bin/ash

# Сбор доменов, к которым обращаются клиенты сети, для добавления в Podkop.
# Совместимо с OpenWrt BusyBox ash: bash-специфичного синтаксиса нет.

LOG_FILE="/tmp/podkop-domain-capture.log"
PREV_FILE="/tmp/podkop-domain-capture.logqueries.prev"
LEASES_FILE="/tmp/dhcp.leases"
CLIENTS_FILE="/tmp/podkop-domain-capture.clients"
LOG_IPS_FILE="/tmp/podkop-domain-capture.log-ips"
SNI_AWK_FILE="/tmp/podkop-domain-capture.sni.awk"
SNI_PID_FILE="/tmp/podkop-domain-capture.tcpdump.pid"
SNI_ERR_FILE="/tmp/podkop-domain-capture.tcpdump.err"
DNS_PID_FILE="/tmp/podkop-domain-capture.logread.pid"
NFT_FILE="/tmp/podkop-domain-capture.nft"
TTY_DEV="/dev/tty"
PDC_VERSION="0.4.1-beta"

# Обновляемся по последнему релизу, а не по ветке: в ветку попадает и работа
# в процессе. PDC_SCRIPT_URL перекрывает всё и берёт файл напрямую.
SCRIPT_REPO="${PDC_SCRIPT_REPO:-doxfie/Podkop-Domain-Capture}"
SCRIPT_FILE="podkop-domain-capture.sh"
SCRIPT_URL="${PDC_SCRIPT_URL:-}"
RELEASE_API="https://api.github.com/repos/$SCRIPT_REPO/releases/latest"
UPDATE_STAMP="/etc/podkop-domain-capture.stamp"
UPDATE_INTERVAL="86400"
# Маркер конца файла: по нему видно, что закачка дошла до конца, а не оборвалась.
EOF_MARK="# PDC-EOF"
TCPDUMP_PKG="tcpdump-mini"
TCPDUMP_SIZE="~385 КБ"
MAINTENANCE_NOTED="0"

# Отдельная таблица, чтобы не трогать fw4/podkop/zapret и снимать всё разом.
NFT_TABLE="pdc_capture"

# PDC_SOURCE=dns запускает утилиту без требования tcpdump - нужно, когда пакет
# принципиально не поставить. Умолчание не меняется: без переменной отсутствие
# tcpdump останавливает запуск, чтобы сбор молча не деградировал.
CAPTURE_SOURCE="${PDC_SOURCE:-both}"
case "$CAPTURE_SOURCE" in
	dns|sni|both) ;;
	*) CAPTURE_SOURCE="both" ;;
esac

OPT_DNS_HIJACK="1"
OPT_BLOCK_DOT="1"
OPT_BLOCK_QUIC="1"
NFT_ACTIVE="0"
SNI_ACTIVE="0"
DNS_ACTIVE="0"

ESC_CHAR="$(printf '\033')"
CR_CHAR="$(printf '\r')"
MENU_CHOICE=""
SELECTED_IPS=""
SELECTED_IPS6=""
SELECTED_MACS=""
# По одному ключу на клиента: MAC, если он известен, иначе адрес.
SELECTED_KEYS=""
SELECTED_LOG_IP=""
CAPTURE_ALL_SELECTED="0"
CAPTURE_MESSAGE=""
LOGS_ENABLED="0"

TUI_LINE="---------------------------------------------------------"
if [ -n "$NO_COLOR" ]; then
	TUI_RESET=""; TUI_BOLD=""; TUI_DIM=""
	TUI_GREEN=""; TUI_CYAN=""; TUI_YELLOW=""; TUI_SELECTED=""
else
	TUI_RESET="$(printf '\033[0m')"
	TUI_BOLD="$(printf '\033[1m')"
	TUI_DIM="$(printf '\033[2m')"
	TUI_GREEN="$(printf '\033[32m')"
	TUI_CYAN="$(printf '\033[36m')"
	TUI_YELLOW="$(printf '\033[33m')"
	TUI_SELECTED="$(printf '\033[1;30;42m')"
fi

# Домены и строки логов не должны раскрываться как glob.
set -f

ensure_interactive_input() {
	[ -t 0 ] && [ -c "$TTY_DEV" ] && return 0

	if [ -c "$TTY_DEV" ]; then
		exec < "$TTY_DEV"
		[ -t 0 ] && return 0
	fi

	echo "Интерактивный ввод недоступен."
	echo "Не запускайте меню через pipe вида: wget -O - ... | sh"
	echo "Запустите скрипт напрямую: pdc"
	exit 1
}

clear_screen() {
	printf '\033[H\033[J'
}

dashes() {
	awk -v n="$1" 'BEGIN { while (length(s) < n) s = s "-"; print s }'
}

# Читает строку в ANSWER и срезает хвост: Windows-терминалы присылают CR,
# из-за чего "q" приходит как "q\r" и не совпадает ни с одним шаблоном.
read_answer() {
	if [ "$1" = "tty" ]; then
		IFS= read -r ANSWER < "$TTY_DEV" || return 1
	else
		IFS= read -r ANSWER || return 1
	fi

	while :; do
		case "$ANSWER" in
			*"$CR_CHAR") ANSWER="${ANSWER%"$CR_CHAR"}" ;;
			*' ') ANSWER="${ANSWER% }" ;;
			*) break ;;
		esac
	done
	return 0
}

# После посимвольного чтения в буфере остаётся перевод строки и молча отвечает
# на следующий вопрос вместо пользователя. Забираем его чтением с таймаутом:
# вариант с -t 0 на этой сборке busybox возвращает успех, ничего не прочитав.
drain_input() {
	IFS= read -r -t 1 DRAIN_REST < "$TTY_DEV" 2>/dev/null
	return 0
}

pause_enter() {
	echo
	printf "Нажмите Enter, чтобы продолжить..."
	IFS= read -r DUMMY || return 0
	clear_screen
}

tui_start() {
	if [ ! -r "$TTY_DEV" ]; then
		echo "Ошибка: интерактивный терминал $TTY_DEV недоступен."
		return 1
	fi
	printf '\033[?25l'
	trap 'tui_stop; echo; exit 130' INT TERM HUP
	return 0
}

tui_stop() {
	printf '\033[?25h'
	trap - INT TERM HUP
}

read_char() {
	READ_CHAR=""
	IFS= read -r -s -n 1 READ_CHAR < "$TTY_DEV" 2>/dev/null
}

read_key() {
	if ! read_char; then
		echo "unsupported"
		return
	fi
	KEY1="$READ_CHAR"

	if [ "$KEY1" = "$ESC_CHAR" ]; then
		read_char || { echo "other"; return; }
		KEY2="$READ_CHAR"
		read_char || { echo "other"; return; }
		case "$KEY2$READ_CHAR" in
			"[A"|"OA") echo "up" ;;
			"[B"|"OB") echo "down" ;;
			*) echo "other" ;;
		esac
		return
	fi

	case "$KEY1" in
		""|"$CR_CHAR") echo "enter" ;;
		" ") echo "space" ;;
		q|Q) echo "quit" ;;
		*) echo "other" ;;
	esac
}

show_tui_unsupported() {
	tui_stop
	clear_screen
	echo "Ошибка: эта сборка BusyBox ash не поддерживает read -s -n 1."
	echo
	echo "Без stty или read -n shell не может читать стрелки по одному нажатию."
	echo "Нужен BusyBox ash с поддержкой read -n/read -s, applet stty или"
	echo "внешний TUI вроде dialog/whiptail. Цифрового меню в проекте нет."
	pause_enter
}

tui_header() {
	clear_screen
	printf '%s%s%s\n' "$TUI_CYAN" "$TUI_LINE" "$TUI_RESET"
	printf '%s%s%s %s[%s]%s\n' "$TUI_BOLD" "$TUI_GREEN" "$1" "$TUI_DIM" "$PDC_VERSION" "$TUI_RESET"
	[ -n "$2" ] && printf '%s%s%s\n' "$TUI_DIM" "$2" "$TUI_RESET"
	printf '%s%s%s\n\n' "$TUI_CYAN" "$TUI_LINE" "$TUI_RESET"
}

# Заголовок прямо в потоке вывода: не чистит экран, поэтому напечатанное выше
# остаётся. $3 = "open" - без нижней полосы, когда под ним идёт длинный список.
tui_block() {
	printf '\n%s%s%s\n' "$TUI_CYAN" "$TUI_LINE" "$TUI_RESET"
	printf '%s%s%s%s\n' "$TUI_BOLD" "$TUI_GREEN" "$1" "$TUI_RESET"
	[ -n "$2" ] && printf '%s%s%s\n' "$TUI_DIM" "$2" "$TUI_RESET"
	[ "$3" != "open" ] && printf '%s%s%s\n' "$TUI_CYAN" "$TUI_LINE" "$TUI_RESET"
	return 0
}

tui_hint()    { printf '%s%s%s\n' "$TUI_DIM" "$1" "$TUI_RESET"; }
tui_section() { printf '%s%s%s\n' "$TUI_CYAN" "$1" "$TUI_RESET"; }
tui_message() { printf '%s%s%s\n' "$TUI_YELLOW" "$1" "$TUI_RESET"; }

# Строка прогресса. Подготовка к сбору - служебный шум рядом с живыми данными,
# поэтому печатается тем же приглушённым стилем, что и подсказки.
tui_step()      { printf '%s%s' "$TUI_DIM" "$1"; }
tui_step_done() { printf '%s%s\n' "$1" "$TUI_RESET"; }
# Обрывает строку прогресса перед сообщением об ошибке, сбрасывая стиль.
tui_step_fail() { printf '%s\n' "$TUI_RESET"; }

# $1 - индекс под курсором, $2 - индекс строки, $3 - текст.
render_menu_line() {
	if [ "$1" -eq "$2" ]; then
		printf '%s > %s %s\n' "$TUI_SELECTED" "$3" "$TUI_RESET"
	else
		printf '   %s\n' "$3"
	fi
}

render_main_menu() {
	tui_header "Podkop Domain Capture" "Сбор доменов из DNS-лога и TLS ClientHello"
	tui_hint "Стрелки вверх/вниз - выбор   Enter - открыть   q - выход"
	echo
	tui_section "Действия"
	render_menu_line "$1" 1 "Собрать домены"
	render_menu_line "$1" 2 "Показать домены из последнего лога"
	render_menu_line "$1" 3 "Показать домены по клиенту из последнего лога"
	render_menu_line "$1" 4 "Сбросить временные логи"
	render_menu_line "$1" 5 "Выход"
}

select_main_menu() {
	MENU_INDEX="1"
	MENU_MAX="5"
	MENU_CHOICE=""
	tui_start || return 1

	while :; do
		render_main_menu "$MENU_INDEX"
		case "$(read_key)" in
			up)   MENU_INDEX=$((MENU_INDEX - 1)); [ "$MENU_INDEX" -lt 1 ] && MENU_INDEX="$MENU_MAX" ;;
			down) MENU_INDEX=$((MENU_INDEX + 1)); [ "$MENU_INDEX" -gt "$MENU_MAX" ] && MENU_INDEX="1" ;;
			enter)
				MENU_CHOICE="$MENU_INDEX"
				tui_stop
				# На выходе экран не чистим: пусть меню останется на виду.
				[ "$MENU_CHOICE" != "5" ] && clear_screen
				return 0
				;;
			quit)
				MENU_CHOICE="5"
				tui_stop
				return 0
				;;
			unsupported)
				show_tui_unsupported
				return 1
				;;
		esac
	done
}

# /tmp/dhcp.leases: expires_epoch mac ip hostname client_id
load_clients() {
	if [ ! -s "$LEASES_FILE" ]; then
		: > "$CLIENTS_FILE"
		return
	fi

	awk '
	function remaining(expire,	left, d, h, m) {
		if (expire == 0) return "never"
		if (now == 0) return "expires=" expire
		left = expire - now
		if (left <= 0) return "expired"
		d = int(left / 86400); h = int((left % 86400) / 3600); m = int((left % 3600) / 60)
		if (d > 0) return d "d " h "h " m "m"
		if (h > 0) return h "h " m "m"
		if (m > 0) return m "m " left % 60 "s"
		return left % 60 "s"
	}
	BEGIN { now = systime() }
	{
		host = $4
		if (host == "" || host == "*") host = "-"
		printf "%s|%s|%s|%s\n", $3, $2, host, remaining($1)
	}' "$LEASES_FILE" > "$CLIENTS_FILE"
}

client_count()    { awk 'END { print NR + 0 }' "$CLIENTS_FILE"; }
get_client_line() { sed -n "${1}p" "$CLIENTS_FILE"; }

split_client_line() {
	OLD_IFS="$IFS"
	IFS="|"
	set -- $1
	IFS="$OLD_IFS"
	CLIENT_IP="$1"; CLIENT_MAC="$2"; CLIENT_HOST="$3"; CLIENT_REMAINING="$4"
}

is_ip_selected() {
	for CHECK_IP in $SELECTED_IPS; do
		[ "$CHECK_IP" = "$1" ] && return 0
	done
	return 1
}

toggle_ip_selection() {
	if is_ip_selected "$1"; then
		NEW_SELECTED=""
		for CHECK_IP in $SELECTED_IPS; do
			[ "$CHECK_IP" != "$1" ] && NEW_SELECTED="$NEW_SELECTED $CHECK_IP"
		done
		SELECTED_IPS="$NEW_SELECTED"
	else
		SELECTED_IPS="$SELECTED_IPS $1"
	fi
	CAPTURE_ALL_SELECTED="0"
}

toggle_all_clients() {
	if [ "$CAPTURE_ALL_SELECTED" = "1" ]; then
		CAPTURE_ALL_SELECTED="0"
	else
		CAPTURE_ALL_SELECTED="1"
		SELECTED_IPS=""
	fi
}

render_capture_menu() {
	CAPTURE_INDEX="$1"
	CLIENT_TOTAL="$2"

	tui_header "Сбор доменов" "Выберите клиентов, от которых нужно поймать домены"
	tui_hint "Стрелки - выбор   Space/Enter - отметить   Enter на действии - подтвердить   q - назад"
	echo
	printf '   Источник:  %s\n' "$(capture_source_label)"
	printf '   Правила:   %s\n\n' "$(capture_rules_label)"

	if [ "$CLIENT_TOTAL" -eq 0 ]; then
		tui_message "DHCP leases не найдены или пусты. Можно выбрать сбор от всех клиентов."
		echo
	fi

	tui_section "Клиенты"
	[ "$CAPTURE_ALL_SELECTED" = "1" ] && CHECK="[x]" || CHECK="[ ]"
	render_menu_line "$CAPTURE_INDEX" 1 "$CHECK Все клиенты"

	if [ "$CLIENT_TOTAL" -gt 0 ]; then
		printf '%s   %-3s %-15s %-36s %-19s %s%s\n' "$TUI_DIM" "" "IP" "Name" "MAC" "Lease" "$TUI_RESET"
	fi

	# Файл читаем один раз и печатаем напрямую: раньше каждая строка стоила
	# sed плюс подстановку, то есть два форка на клиента на каждое нажатие.
	I="0"
	while IFS='|' read -r CLIENT_IP CLIENT_MAC CLIENT_HOST CLIENT_REMAINING; do
		I=$((I + 1))
		is_ip_selected "$CLIENT_IP" && CHECK="[x]" || CHECK="[ ]"
		if [ "$CAPTURE_INDEX" -eq $((I + 1)) ]; then
			printf '%s > %s %-15s %-36.36s %-19s %s %s\n' "$TUI_SELECTED" \
				"$CHECK" "$CLIENT_IP" "$CLIENT_HOST" "$CLIENT_MAC" "$CLIENT_REMAINING" "$TUI_RESET"
		else
			printf '   %s %-15s %-36.36s %-19s %s\n' \
				"$CHECK" "$CLIENT_IP" "$CLIENT_HOST" "$CLIENT_MAC" "$CLIENT_REMAINING"
		fi
	done < "$CLIENTS_FILE"

	echo
	tui_section "Действия"
	render_menu_line "$CAPTURE_INDEX" $((CLIENT_TOTAL + 2)) "Начать сбор доменов"
	render_menu_line "$CAPTURE_INDEX" $((CLIENT_TOTAL + 3)) "Настройки сбора"
	render_menu_line "$CAPTURE_INDEX" $((CLIENT_TOTAL + 4)) "Назад"

	if [ -n "$CAPTURE_MESSAGE" ]; then
		echo
		tui_message "$CAPTURE_MESSAGE"
	fi
}

select_capture_targets() {
	load_clients
	CLIENT_TOTAL="$(client_count)"
	CAPTURE_INDEX="1"
	CAPTURE_MAX=$((CLIENT_TOTAL + 4))
	CAPTURE_ALL_SELECTED="0"
	SELECTED_IPS=""
	CAPTURE_MESSAGE=""
	tui_start || return 1

	while :; do
		START_INDEX=$((CLIENT_TOTAL + 2))
		render_capture_menu "$CAPTURE_INDEX" "$CLIENT_TOTAL"
		KEY="$(read_key)"
		CAPTURE_MESSAGE=""

		case "$KEY" in
			up)   CAPTURE_INDEX=$((CAPTURE_INDEX - 1)); [ "$CAPTURE_INDEX" -lt 1 ] && CAPTURE_INDEX="$CAPTURE_MAX" ;;
			down) CAPTURE_INDEX=$((CAPTURE_INDEX + 1)); [ "$CAPTURE_INDEX" -gt "$CAPTURE_MAX" ] && CAPTURE_INDEX="1" ;;
			space|enter)
				if [ "$CAPTURE_INDEX" -eq 1 ]; then
					toggle_all_clients
					continue
				fi

				if [ "$CAPTURE_INDEX" -le $((CLIENT_TOTAL + 1)) ]; then
					split_client_line "$(get_client_line $((CAPTURE_INDEX - 1)))"
					toggle_ip_selection "$CLIENT_IP"
					continue
				fi

				[ "$KEY" = "space" ] && continue

				if [ "$CAPTURE_INDEX" -eq "$START_INDEX" ]; then
					if [ "$CAPTURE_ALL_SELECTED" != "1" ] && [ -z "$SELECTED_IPS" ]; then
						CAPTURE_MESSAGE="Выберите хотя бы одного клиента или пункт Все клиенты."
						continue
					fi
					tui_stop
					clear_screen
					if [ "$CAPTURE_ALL_SELECTED" = "1" ]; then
						start_capture "all" ""
					else
						start_capture "selected" "$SELECTED_IPS"
					fi
					return 0
				fi

				if [ "$CAPTURE_INDEX" -eq $((CLIENT_TOTAL + 3)) ]; then
					tui_stop
					clear_screen
					configure_capture_advanced
					tui_start || return 1
					continue
				fi

				tui_stop
				clear_screen
				return 0
				;;
			quit)
				tui_stop
				clear_screen
				return 0
				;;
			unsupported)
				show_tui_unsupported
				return 1
				;;
		esac
	done
}

# Имя LAN-моста из конфигурации: br-lan это частый случай, а не данность.
lan_device() {
	LAN_DEV="$(uci -q get network.lan.device 2>/dev/null)"
	[ -z "$LAN_DEV" ] && LAN_DEV="$(uci -q get network.lan.ifname 2>/dev/null)"
	printf '%s\n' "${LAN_DEV:-br-lan}"
}

# Все подсети LAN, а не первая: при втором адресе на интерфейсе вторая подсеть
# иначе выпадала и из правил, и из проверки принадлежности клиента.
lan_subnets()  { ip -4 route show dev "$(lan_device)" proto kernel 2>/dev/null | awk '{ print $1 }'; }
lan_subnets6() { ip -6 route show dev "$(lan_device)" proto kernel 2>/dev/null | awk '{ print $1 }'; }

# Собственные адреса роутера - их исключаем в режиме "все клиенты".
router_lan_ips() {
	LAN_IF="$(lan_device)"
	ip -4 addr show dev "$LAN_IF" 2>/dev/null | awk '$1 == "inet"  { split($2, a, "/"); print a[1] }'
	ip -6 addr show dev "$LAN_IF" 2>/dev/null | awk '$1 == "inet6" { split($2, a, "/"); print a[1] }'
}

# Лежит ли IPv4 внутри CIDR. Без побитовых операций: busybox awk их не имеет,
# поэтому сравниваем номера блоков размером 2^(32-префикс).
ip_in_subnet() {
	awk -v ip="$1" -v cidr="$2" '
	function toint(a,	p, i, v) {
		if (split(a, p, ".") != 4) return -1
		for (i = 1; i <= 4; i++) v = v * 256 + (p[i] + 0)
		return v
	}
	BEGIN {
		if (split(cidr, c, "/") != 2) exit 1
		size = 1
		for (i = 0; i < 32 - (c[2] + 0); i++) size = size * 2
		x = toint(ip); y = toint(c[1])
		if (x < 0 || y < 0) exit 1
		exit !(int(x / size) == int(y / size))
	}'
}

# В /tmp/dhcp.leases нет колонки интерфейса, поэтому клиент гостевой сети или
# IoT-VLAN попадает в список выбора: DNS по нему собирается, а tcpdump слушает
# другой мост и SNI молчит без признака ошибки. Судим по подсети, а не по
# таблице соседей: у давно молчавшего устройства записи там нет.
client_off_capture_net() {
	OFF_SUBNETS="$(lan_subnets)"
	[ -z "$OFF_SUBNETS" ] && return 1
	for OFF_ONE in $OFF_SUBNETS; do
		ip_in_subnet "$1" "$OFF_ONE" && return 1
	done
	return 0
}

mac_for_ip() {
	awk -v ip="$1" '$3 == ip { print tolower($2); exit }' "$LEASES_FILE" 2>/dev/null
}

# IPv6 берём из таблицы соседей: DHCPv6-аренды не покрывают SLAAC и приватные
# адреса, а сюда попадает всё, с чем роутер реально общался.
ipv6_for_mac() {
	ip -6 neigh show dev "$(lan_device)" 2>/dev/null |
		awk -v mac="$1" '$2 == "lladdr" && tolower($3) == mac { print $1 }' | sort -u
}

# MAC покрывает клиента целиком: обе версии протокола и адреса, созданные уже
# во время сбора, - privacy extensions плодят их десятками. Где MAC не нашёлся,
# в ключи идёт сам адрес: иначе такой клиент выпадал бы из правил и BPF совсем,
# потому что ветка по MAC выбиралась по наличию хотя бы одного MAC на всех.
# Список IPv6 нужен отдельно фильтру DNS-лога: в логе dnsmasq MAC взять негде.
expand_selected_clients() {
	SELECTED_MACS=""
	SELECTED_IPS6=""
	SELECTED_KEYS=""
	for EXPAND_IP in $1; do
		EXPAND_MAC="$(mac_for_ip "$EXPAND_IP")"
		if [ -z "$EXPAND_MAC" ]; then
			SELECTED_KEYS="$SELECTED_KEYS $EXPAND_IP"
			continue
		fi
		SELECTED_MACS="$SELECTED_MACS $EXPAND_MAC"
		SELECTED_KEYS="$SELECTED_KEYS $EXPAND_MAC"
		for EXPAND_V6 in $(ipv6_for_mac "$EXPAND_MAC"); do
			SELECTED_IPS6="$SELECTED_IPS6 $EXPAND_V6"
		done
	done
	return 0
}

# Парсер TLS ClientHello держим отдельным файлом, а не inline-строкой: так
# проще отлаживать и не воевать с экранированием внутри ash.
write_sni_awk() {
	cat > "$SNI_AWK_FILE" <<'PDC_SNI_AWK'
function hv(c) { return index("0123456789abcdef", c) - 1 }

function b(i,	s) {
	s = substr(HEX, i * 2 + 1, 2)
	if (length(s) < 2) return -1
	return hv(substr(s, 1, 1)) * 16 + hv(substr(s, 2, 1))
}

function b2(i,	h, l) {
	h = b(i); l = b(i + 1)
	if (h < 0 || l < 0) return -1
	return h * 256 + l
}

# Возвращает 1, если имя найдено и напечатано. Зовём после каждой строки с
# байтами: иначе домен появлялся бы лишь со следующим TLS-соединением.
function flush(	ver, tcp, doff, p, n, sidl, csl, cml, extl, et, el, end, nl, name, i, c) {
	if (HEX == "" || SRC == "") return 0
	if (b(0) < 0) return 0

	ver = int(b(0) / 16)
	if (ver == 4) {
		if (b(9) != 6) return 0			# protocol = TCP
		tcp = (b(0) % 16) * 4			# IHL в 32-битных словах
	} else if (ver == 6) {
		if (b(6) != 6) return 0			# next header = TCP, без расширений
		tcp = 40				# заголовок IPv6 фиксирован
	} else {
		return 0
	}

	doff = int(b(tcp + 12) / 16) * 4
	if (doff < 20) return 0
	p = tcp + doff
	if (b(p) != 22) return 0		# TLS handshake
	if (b(p + 5) != 1) return 0		# ClientHello

	# 5 record + 4 handshake + 2 version + 32 random = 43
	n = p + 43
	sidl = b(n); if (sidl < 0) return 0
	n += 1 + sidl
	csl = b2(n); if (csl < 0) return 0
	n += 2 + csl
	cml = b(n); if (cml < 0) return 0
	n += 1 + cml
	extl = b2(n); if (extl < 0) return 0
	n += 2
	end = n + extl

	while (n + 4 <= end) {
		et = b2(n); el = b2(n + 2)
		if (et < 0 || el < 0) return 0
		n += 4
		if (et == 0) {
			nl = b2(n + 3)
			if (nl <= 0 || nl > 253) return 0
			# Имя обязано умещаться в расширение: список (2) + тип (1) +
			# длина (2) + имя. Иначе разбор уполз бы в соседнее.
			if (nl + 5 > el) return 0
			name = ""
			for (i = 0; i < nl; i++) {
				c = b(n + 5 + i)
				if (c < 33 || c > 126) return 0
				name = name sprintf("%c", c)
			}
			printf "%s %s %s sni\n", TS, SRC, name
			fflush()
			return 1
		}
		n += el
	}
	return 0
}

/^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\./ {
	if (!DONE) flush()
	HEX = ""; SRC = ""; DONE = 0
	TS = substr($1, 1, 8)
	if ($2 == "IP") {
		# 192.168.1.130.54321 - адрес это первые четыре октета
		if (split($3, a, ".") >= 5) SRC = a[1] "." a[2] "." a[3] "." a[4]
	} else if ($2 == "IP6") {
		# fd6c:bfe7:e261::194.54321 - порт отделён последней точкой
		SRC = $3
		sub(/\.[0-9]+$/, "", SRC)
	}
	next
}

# [[:space:]] вместо [ \t]: escape-последовательности внутри скобочного
# выражения POSIX не определяет, хотя на практике их понимают все awk.
/^[[:space:]]+0x[0-9a-f]+:/ {
	line = $0
	sub(/^[[:space:]]+0x[0-9a-f]+:[[:space:]]*/, "", line)
	gsub(/[[:space:]]/, "", line)
	HEX = HEX line
	if (!DONE && flush()) DONE = 1
	next
}

END { if (!DONE) flush() }
PDC_SNI_AWK
}

# Обычный запуск - это "pdc" по имени из PATH, и тогда в $0 нет ни одного
# слэша: клеить его с текущим каталогом нельзя, надо искать в PATH.
self_path() {
	case "$0" in
		/*)   printf '%s\n' "$0" ;;
		*/*)  printf '%s/%s\n' "$(pwd)" "$0" ;;
		*)
			SELF_RESOLVED="$(command -v "$0" 2>/dev/null)"
			printf '%s\n' "${SELF_RESOLVED:-$0}"
			;;
	esac
}

fetch_url() {
	command -v wget >/dev/null 2>&1 && wget -q -O "$2" --timeout=15 "$1" 2>/dev/null && return 0
	command -v curl >/dev/null 2>&1 && curl -fsS --max-time 15 -o "$2" "$1" 2>/dev/null && return 0
	return 1
}

# Скачанный файл должен быть нашим скриптом целиком: не 404-страницей и не
# оборванной закачкой. Порог по размеру отсеивает только страницы с ошибкой -
# обрыв на любых 16-94% его проходит, - поэтому решает маркер конца файла.
script_complete() {
	head -n 1 "$1" | grep -q '^#!/bin/ash' || return 1
	[ "$(wc -c < "$1")" -ge 10000 ] || return 1
	tail -n 1 "$1" | grep -qx "$EOF_MARK" || return 1
	return 0
}

# 0, если версия $1 строго новее $2. При равных числах релиз новее одноимённого
# пререлиза: 0.3.2 обновляет 0.3.2-beta, но не наоборот.
version_newer() {
	awk -v a="$1" -v b="$2" '
	function norm(v,	n, p, i, s) {
		sub(/-.*$/, "", v)
		n = split(v, p, ".")
		for (i = 1; i <= 3; i++) s = s * 1000 + (i <= n ? p[i] + 0 : 0)
		return s
	}
	function pre(v) { return (v ~ /-/) ? 1 : 0 }
	BEGIN {
		na = norm(a); nb = norm(b)
		if (na != nb) exit !(na > nb)
		exit !(pre(a) == 0 && pre(b) == 1)
	}'
}

pkg_version() {
	if command -v apk >/dev/null 2>&1; then
		apk list -I "$1" 2>/dev/null | awk 'NR==1 { print $1 }'
	elif command -v opkg >/dev/null 2>&1; then
		opkg list-installed "$1" 2>/dev/null | awk 'NR==1 { print $3 }'
	fi
}

# tcpdump обязателен, потому что SNI - основной источник. Три попытки, дальше
# выходим: продолжать без него нет смысла.
install_tcpdump_or_die() {
	echo
	echo "Первый запуск: для перехвата SNI нужен tcpdump."
	printf 'Устанавливаю %s (%s, плюс libpcap)...\n' "$TCPDUMP_PKG" "$TCPDUMP_SIZE"

	INSTALL_OUT=""
	ATTEMPT="1"
	while [ "$ATTEMPT" -le 3 ]; do
		if [ "$ATTEMPT" -gt 1 ]; then
			echo "Попытка $ATTEMPT из 3..."
			sleep 3
		fi

		if command -v apk >/dev/null 2>&1; then
			apk update >/dev/null 2>&1
			INSTALL_OUT="$(apk add "$TCPDUMP_PKG" 2>&1)"
		elif command -v opkg >/dev/null 2>&1; then
			opkg update >/dev/null 2>&1
			INSTALL_OUT="$(opkg install "$TCPDUMP_PKG" 2>&1)"
		else
			INSTALL_OUT="не найден ни apk, ни opkg"
			break
		fi

		if command -v tcpdump >/dev/null 2>&1; then
			echo "tcpdump установлен."
			MAINTENANCE_NOTED="1"
			return 0
		fi
		ATTEMPT=$((ATTEMPT + 1))
	done

	echo
	echo "Ошибка: не удалось установить $TCPDUMP_PKG за 3 попытки."
	[ -n "$INSTALL_OUT" ] && printf '%s\n' "$INSTALL_OUT" | tail -5
	echo
	echo "Сбор по SNI - основной режим, без tcpdump он невозможен."
	echo "Проверьте интернет и свободное место, затем запустите pdc снова."
	echo
	echo "Если пакет не поставить в принципе - например, релиз OpenWrt уехал"
	echo "в архив и фид отдаёт 404, - можно собирать только по DNS:"
	echo
	echo "    PDC_SOURCE=dns pdc"
	echo
	echo "Учтите: без SNI в список не попадут домены с закешированным ответом,"
	echo "клиенты со своим DoH/DoT и с зашитым в прошивку IP."
	exit 1
}

update_tcpdump() {
	VER_BEFORE="$(pkg_version "$TCPDUMP_PKG")"

	if command -v apk >/dev/null 2>&1; then
		apk update >/dev/null 2>&1
		# Только этот пакет: голый apk upgrade потянул бы luci, hostapd и прочее.
		apk upgrade "$TCPDUMP_PKG" >/dev/null 2>&1
	elif command -v opkg >/dev/null 2>&1; then
		opkg update >/dev/null 2>&1
		opkg upgrade "$TCPDUMP_PKG" >/dev/null 2>&1
	else
		return 0
	fi

	VER_AFTER="$(pkg_version "$TCPDUMP_PKG")"
	if [ -n "$VER_AFTER" ] && [ "$VER_BEFORE" != "$VER_AFTER" ]; then
		echo "tcpdump обновлён: $VER_BEFORE -> $VER_AFTER"
		MAINTENANCE_NOTED="1"
	fi
	return 0
}

# jsonfilter входит в базовый OpenWrt, но если его нет - берём поле grep'ом.
latest_release_tag() {
	TAG_FILE="/tmp/podkop-domain-capture.release"
	rm -f "$TAG_FILE"
	fetch_url "$RELEASE_API" "$TAG_FILE" || { rm -f "$TAG_FILE"; return 1; }

	RELEASE_TAG=""
	command -v jsonfilter >/dev/null 2>&1 &&
		RELEASE_TAG="$(jsonfilter -i "$TAG_FILE" -e '@.tag_name' 2>/dev/null)"
	[ -z "$RELEASE_TAG" ] &&
		RELEASE_TAG="$(grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$TAG_FILE" |
			head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
	rm -f "$TAG_FILE"

	[ -z "$RELEASE_TAG" ] && return 1
	printf '%s\n' "$RELEASE_TAG"
}

update_script() {
	SELF="$(self_path)"
	[ -w "$SELF" ] || return 0

	if [ -n "$SCRIPT_URL" ]; then
		SRC_URL="$SCRIPT_URL"
	else
		RELEASE_TAG="$(latest_release_tag)" || return 0
		# Тег вида v0.4.0-beta: сверяем без "v" и не качаем лишнего.
		version_newer "${RELEASE_TAG#v}" "$PDC_VERSION" || return 0
		SRC_URL="https://raw.githubusercontent.com/$SCRIPT_REPO/$RELEASE_TAG/$SCRIPT_FILE"
	fi

	# Временный файл кладём рядом с целевым: mv в пределах одной ФС - это
	# rename(2). Из /tmp (tmpfs) в /usr/bin (overlay) busybox копировал бы
	# содержимое, то есть переписывал бы исполняемый прямо сейчас файл.
	NEW_FILE="$(dirname "$SELF")/.podkop-domain-capture.new"
	rm -f "$NEW_FILE"
	fetch_url "$SRC_URL" "$NEW_FILE" || { rm -f "$NEW_FILE"; return 0; }

	if ! script_complete "$NEW_FILE"; then
		rm -f "$NEW_FILE"
		return 0
	fi

	REMOTE_VERSION="$(grep -m1 '^PDC_VERSION=' "$NEW_FILE" | cut -d'"' -f2)"
	if [ -z "$REMOTE_VERSION" ] || ! version_newer "$REMOTE_VERSION" "$PDC_VERSION"; then
		rm -f "$NEW_FILE"
		return 0
	fi

	echo "Доступна версия $REMOTE_VERSION (установлена $PDC_VERSION), обновляю..."
	chmod +x "$NEW_FILE" 2>/dev/null

	# Подменяем переименованием, а не перезаписью: работающий шелл продолжит
	# читать старый inode, который доживёт до его выхода.
	if ! mv "$NEW_FILE" "$SELF"; then
		echo "Предупреждение: не удалось заменить $SELF, продолжаю на текущей версии."
		rm -f "$NEW_FILE"
		return 0
	fi

	echo "Обновлено до $REMOTE_VERSION, перезапускаю..."
	PDC_UPDATED=1 exec "$SELF"
}

update_due() {
	[ -f "$UPDATE_STAMP" ] || return 0
	NOW="$(date +%s 2>/dev/null)"
	THEN="$(cat "$UPDATE_STAMP" 2>/dev/null)"
	case "$NOW$THEN" in
		*[!0-9]*|"") return 0 ;;
	esac
	[ "$((NOW - THEN))" -ge "$UPDATE_INTERVAL" ]
}

startup_maintenance() {
	# Требуем tcpdump, только если SNI вообще может понадобиться.
	if ! command -v tcpdump >/dev/null 2>&1 && [ "$CAPTURE_SOURCE" != "dns" ]; then
		install_tcpdump_or_die
		date +%s > "$UPDATE_STAMP" 2>/dev/null
	# Уже перезапускались после обновления - второй круг не нужен.
	elif [ -z "$PDC_UPDATED" ] && update_due; then
		echo "Проверяю обновления..."
		date +%s > "$UPDATE_STAMP" 2>/dev/null
		command -v tcpdump >/dev/null 2>&1 && update_tcpdump
		# Может не вернуться: обновит скрипт и сделает exec.
		update_script
		[ "$MAINTENANCE_NOTED" = "0" ] && echo "Всё актуально."
	fi

	[ "$MAINTENANCE_NOTED" = "1" ] && pause_enter
	return 0
}

# Форма значения решает, чем матчить: MAC, IPv6 или IPv4.
nft_family() {
	case "$1" in
		??:??:??:??:??:??) printf 'ether\n' ;;
		*:*)               printf 'ip6\n' ;;
		*)                 printf 'ip\n' ;;
	esac
}

bpf_term() {
	case "$1" in
		??:??:??:??:??:??) printf 'ether src %s' "$1" ;;
		*)                 printf 'src host %s' "$1" ;;
	esac
}

# BPF-фильтр: только TLS ClientHello от нужных клиентов.
build_bpf_filter() {
	BPF_HOSTS=""

	if [ "$1" = "all" ]; then
		for ONE in $(router_lan_ips); do
			BPF_HOSTS="$BPF_HOSTS or src host $ONE"
		done
		BPF_HOSTS="${BPF_HOSTS# or }"
		[ -n "$BPF_HOSTS" ] && BPF_HOSTS="not ($BPF_HOSTS)"
	else
		for ONE in ${SELECTED_KEYS:-$2}; do
			BPF_HOSTS="$BPF_HOSTS or $(bpf_term "$ONE")"
		done
		BPF_HOSTS="${BPF_HOSTS# or }"
		[ -n "$BPF_HOSTS" ] && BPF_HOSTS="($BPF_HOSTS)"
	fi

	# Первый байт TCP-payload 0x16 = начало TLS-хендшейка. Для IPv6 через tcp[]
	# нельзя - libpcap отвергает такой фильтр, - поэтому адресуемся от начала
	# пакета: 40 байт фиксированного заголовка плюс длина TCP-заголовка.
	BPF_BASE='((ip and tcp and tcp[((tcp[12:1]&0xf0)>>2)]=0x16) or (ip6 and tcp and ip6[40+((ip6[52]&0xf0)>>2)]=0x16))'

	if [ -n "$BPF_HOSTS" ]; then
		printf '%s and %s\n' "$BPF_BASE" "$BPF_HOSTS"
	else
		printf '%s\n' "$BPF_BASE"
	fi
}

nft_guard_enable() {
	if ! command -v nft >/dev/null 2>&1; then
		echo "Предупреждение: nft не найден, сетевые правила пропущены."
		return 1
	fi

	if [ "$OPT_DNS_HIJACK" != "1" ] && [ "$OPT_BLOCK_DOT" != "1" ] && [ "$OPT_BLOCK_QUIC" != "1" ]; then
		return 0
	fi

	if [ "$1" = "all" ]; then
		NFT_SRC_LIST="$(lan_subnets) $(lan_subnets6)"
	else
		NFT_SRC_LIST="${SELECTED_KEYS:-$2}"
	fi

	if [ -z "$(printf '%s' "$NFT_SRC_LIST" | tr -d ' ')" ]; then
		echo "Предупреждение: не удалось определить адреса клиентов, правила пропущены."
		return 1
	fi

	nft delete table inet "$NFT_TABLE" 2>/dev/null

	{
		printf 'table inet %s {\n' "$NFT_TABLE"
		if [ "$OPT_DNS_HIJACK" = "1" ]; then
			printf '\tchain pdc_nat_pre {\n'
			printf '\t\ttype nat hook prerouting priority dstnat - 5; policy accept;\n'
			for ONE in $NFT_SRC_LIST; do
				FAM="$(nft_family "$ONE")"
				printf '\t\t%s saddr %s udp dport 53 counter redirect to :53 comment "pdc-dns-hijack"\n' "$FAM" "$ONE"
				printf '\t\t%s saddr %s tcp dport 53 counter redirect to :53 comment "pdc-dns-hijack"\n' "$FAM" "$ONE"
			done
			printf '\t}\n'
		fi
		if [ "$OPT_BLOCK_DOT" = "1" ] || [ "$OPT_BLOCK_QUIC" = "1" ]; then
			printf '\tchain pdc_fwd {\n'
			printf '\t\ttype filter hook forward priority filter - 5; policy accept;\n'
			for ONE in $NFT_SRC_LIST; do
				FAM="$(nft_family "$ONE")"
				if [ "$OPT_BLOCK_DOT" = "1" ]; then
					printf '\t\t%s saddr %s tcp dport 853 counter reject with tcp reset comment "pdc-block-dot"\n' "$FAM" "$ONE"
					printf '\t\t%s saddr %s udp dport 853 counter drop comment "pdc-block-dot"\n' "$FAM" "$ONE"
				fi
				[ "$OPT_BLOCK_QUIC" = "1" ] &&
					printf '\t\t%s saddr %s udp dport 443 counter drop comment "pdc-block-quic"\n' "$FAM" "$ONE"
			done
			printf '\t}\n'
		fi
		printf '}\n'
	} > "$NFT_FILE"

	if ! nft -f "$NFT_FILE"; then
		echo "Ошибка: не удалось загрузить временные nft-правила."
		rm -f "$NFT_FILE"
		return 1
	fi

	rm -f "$NFT_FILE"
	NFT_ACTIVE="1"
	tui_hint "Временные сетевые правила включены (таблица inet $NFT_TABLE)"
	return 0
}

nft_guard_disable() {
	[ "$NFT_ACTIVE" = "1" ] || return 0
	if nft delete table inet "$NFT_TABLE" 2>/dev/null; then
		tui_hint "Временные сетевые правила сняты"
	else
		echo "Предупреждение: не удалось снять таблицу inet $NFT_TABLE."
		echo "Снимите вручную: nft delete table inet $NFT_TABLE"
	fi
	NFT_ACTIVE="0"
	return 0
}

# Можно ли вообще начинать сбор по SNI. Проверяем до того, как трогать лог:
# иначе отказ единственного источника уносил бы предыдущий сбор впустую.
sni_available() {
	command -v tcpdump >/dev/null 2>&1 && ip link show "$(lan_device)" >/dev/null 2>&1
}

sni_start() {
	SNI_DEV="$(lan_device)"
	if ! sni_available; then
		echo "Ошибка: tcpdump или интерфейс $SNI_DEV недоступны, SNI-источник отключён."
		return 1
	fi

	write_sni_awk
	SNI_FILTER="$(build_bpf_filter "$1" "$2")"
	rm -f "$SNI_PID_FILE" "$SNI_ERR_FILE"

	# Внутренний sh пишет свой PID и делает exec, поэтому в PID-файле оказывается
	# именно tcpdump. stderr в файл, а не в /dev/null: при неудачном старте это
	# единственный источник причины.
	sh -c 'echo $$ > "$1"; exec tcpdump -i "$4" -nn -l -s 0 -x "$2" 2>"$3"' \
		_ "$SNI_PID_FILE" "$SNI_FILTER" "$SNI_ERR_FILE" "$SNI_DEV" |
		awk -f "$SNI_AWK_FILE" |
		while IFS= read -r SNI_LINE; do
			printf '%s\n' "$SNI_LINE" >> "$LOG_FILE"
			# shellcheck disable=SC2086
			set -- $SNI_LINE
			printf "%-8s %-${CLIENT_COL_W}s %-3s %s\n" "$1" "$2" "$4" "$3"
		done &

	SNI_ACTIVE="1"

	# Фильтр мог не скомпилироваться уже после того, как интерфейс нашёлся.
	sleep 1
	if [ ! -s "$SNI_PID_FILE" ] || ! kill -0 "$(cat "$SNI_PID_FILE")" 2>/dev/null; then
		echo "Ошибка: tcpdump не запустился, SNI-источник недоступен."
		[ -s "$SNI_ERR_FILE" ] && head -n 3 "$SNI_ERR_FILE"
		SNI_ACTIVE="0"
		return 1
	fi
	return 0
}

# DNS-источник тоже работает фоном - в переднем плане ждём нажатия клавиши.
dns_start() {
	rm -f "$DNS_PID_FILE"

	sh -c 'echo $$ > "$1"; exec logread -f -e dnsmasq' _ "$DNS_PID_FILE" |
		while IFS= read -r LINE; do
			parse_query_line "$LINE" || continue
			client_allowed "$1" "$2" || continue
			printf '%s %s %s dns\n' "$CAP_TIME" "$CAP_CLIENT" "$CAP_DOMAIN" >> "$LOG_FILE"
			printf "%-8s %-${CLIENT_COL_W}s %-3s %s\n" "$CAP_TIME" "$CAP_CLIENT" "dns" "$CAP_DOMAIN"
		done &

	DNS_ACTIVE="1"
	return 0
}

stop_pid_file() {
	[ -s "$1" ] && kill "$(cat "$1")" 2>/dev/null
	rm -f "$1"
	return 0
}

# Даём источникам дописать хвост: иначе последние строки вылезают уже поверх
# сообщений об остановке.
capture_stop_sources() {
	STOP_NEEDED="0"
	{ [ "$SNI_ACTIVE" = "1" ] || [ "$DNS_ACTIVE" = "1" ]; } && STOP_NEEDED="1"

	[ "$SNI_ACTIVE" = "1" ] && stop_pid_file "$SNI_PID_FILE"
	[ "$DNS_ACTIVE" = "1" ] && stop_pid_file "$DNS_PID_FILE"
	SNI_ACTIVE="0"
	DNS_ACTIVE="0"

	[ "$STOP_NEEDED" = "1" ] && sleep 1
	return 0
}

enable_logs() {
	tui_step 'Включаю dnsmasq logqueries... '

	# Пишем только если сохранённого значения ещё нет: иначе первый сбор сохранил
	# бы "unset", восстановление сорвалось, а второй сбор записал бы уже единицу,
	# потеряв исходное состояние навсегда. После восстановления файл намеренно
	# остаётся - пункт "Сбросить временные логи" доделывает работу за прерванным
	# сбором, а значение в нём к тому моменту совпадает с текущим.
	if [ ! -s "$PREV_FILE" ]; then
		CURRENT_LOGQUERIES="$(uci -q get 'dhcp.@dnsmasq[0].logqueries' 2>/dev/null)"
		printf '%s\n' "${CURRENT_LOGQUERIES:-unset}" > "$PREV_FILE" 2>/dev/null
	fi

	if ! uci set 'dhcp.@dnsmasq[0].logqueries=1' || ! uci commit dhcp; then
		tui_step_fail
		echo "Ошибка: не удалось изменить настройку dnsmasq"
		return 1
	fi
	# Перезапуск дёргает netifd, тот пишет в консоль udhcpc-строки. Прячем их,
	# но сохраняем вывод, чтобы показать при реальной ошибке.
	if ! RESTART_OUT="$(/etc/init.d/dnsmasq restart 2>&1)"; then
		tui_step_fail
		echo "Ошибка: не удалось перезапустить dnsmasq"
		printf '%s\n' "$RESTART_OUT"
		return 1
	fi

	tui_step_done 'готово'
	LOGS_ENABLED="1"
	return 0
}

# Возвращает logqueries к сохранённому значению, а не выставляет 0: иначе у тех,
# у кого лог запросов был включён до запуска, он оказывался выключён после.
# OpenWrt понимает у булевых опций не только 1/0 - get_bool в /lib/functions.sh
# принимает 1|on|true|yes|enabled и 0|off|false|no|disabled, - и схлопывать их
# в 0 нельзя: получилось бы ровно то выключение чужой настройки, от которого мы
# и защищаемся. В 0 отправляем только по-настоящему нераспознанное.
disable_logs() {
	RESTORE_TO="$(cat "$PREV_FILE" 2>/dev/null)"
	case "$RESTORE_TO" in
		0|1|unset|on|true|yes|enabled|off|false|no|disabled) ;;
		*) RESTORE_TO="0" ;;
	esac

	if [ "$RESTORE_TO" = "0" ]; then
		tui_step 'Выключаю dnsmasq logqueries... '
	else
		tui_step 'Возвращаю dnsmasq logqueries... '
	fi

	if [ "$RESTORE_TO" = "unset" ]; then
		# rc=1 здесь означает, что опции и так нет - это нужный нам результат,
		# поэтому проверяем итог, а не код возврата.
		uci -q delete 'dhcp.@dnsmasq[0].logqueries'
		if [ -n "$(uci -q get 'dhcp.@dnsmasq[0].logqueries')" ]; then
			tui_step_fail
			echo "Ошибка: не удалось убрать logqueries"
			return 1
		fi
	elif ! uci set "dhcp.@dnsmasq[0].logqueries=$RESTORE_TO"; then
		tui_step_fail
		echo "Ошибка: не удалось выполнить uci set"
		return 1
	fi

	if ! uci commit dhcp; then
		tui_step_fail
		echo "Ошибка: не удалось выполнить uci commit dhcp"
		return 1
	fi
	if ! RESTART_OUT="$(/etc/init.d/dnsmasq restart 2>&1)"; then
		tui_step_fail
		echo "Ошибка: не удалось перезапустить dnsmasq"
		printf '%s\n' "$RESTART_OUT"
		return 1
	fi

	tui_step_done 'готово'
	LOGS_ENABLED="0"
	return 0
}

capture_cleanup() {
	capture_stop_sources
	nft_guard_disable
	[ "$LOGS_ENABLED" = "1" ] && disable_logs
	return 0
}

capture_source_label() {
	case "$CAPTURE_SOURCE" in
		dns) printf 'только DNS (лог dnsmasq)\n' ;;
		sni) printf 'только SNI (TLS ClientHello)\n' ;;
		*)   printf 'DNS + SNI\n' ;;
	esac
}

capture_rules_label() {
	LBL=""
	[ "$OPT_DNS_HIJACK" = "1" ] && LBL="перехват DNS"
	[ "$OPT_BLOCK_DOT" = "1" ]  && LBL="${LBL:+$LBL, }блок DoT"
	[ "$OPT_BLOCK_QUIC" = "1" ] && LBL="${LBL:+$LBL, }блок QUIC"
	printf '%s\n' "${LBL:-выключены}"
}

# $1 - текст, $2 - текущее значение. Возвращает 0 = да, 1 = нет.
ask_yes_no() {
	if [ "$2" = "1" ]; then
		printf '%s [Y/n]: ' "$1"
	else
		printf '%s [y/N]: ' "$1"
	fi
	if ! read_answer tty; then
		echo
		[ "$2" = "1" ] && return 0 || return 1
	fi
	case "$ANSWER" in
		y|Y|yes|YES|д|Д|да|Да|ДА) return 0 ;;
		n|N|no|NO|н|Н|нет|Нет|НЕТ) return 1 ;;
		*) [ "$2" = "1" ] && return 0 || return 1 ;;
	esac
}

configure_capture_advanced() {
	tui_header "Настройки сбора" "Значения по умолчанию подходят почти всегда"

	tui_section "Источник доменов"
	echo "   1) DNS + SNI  - рекомендуется, ловит и запросы, и уже закешированные домены"
	echo "   2) только DNS - лог dnsmasq, без tcpdump"
	echo "   3) только SNI - имена из TLS ClientHello, dnsmasq не трогается вовсе"
	echo
	printf "Выбор [текущий: %s]: " "$(capture_source_label)"
	read_answer tty || { echo; return 1; }
	case "$ANSWER" in
		1) CAPTURE_SOURCE="both" ;;
		2) CAPTURE_SOURCE="dns" ;;
		3) CAPTURE_SOURCE="sni" ;;
	esac

	# Утилиту могли запустить с PDC_SOURCE=dns именно потому, что пакета нет.
	if [ "$CAPTURE_SOURCE" != "dns" ] && ! command -v tcpdump >/dev/null 2>&1; then
		echo
		tui_message "tcpdump не установлен, источник SNI недоступен - остаётся DNS."
		CAPTURE_SOURCE="dns"
	fi

	echo
	tui_section "Временные правила на время сбора"
	tui_message "   Живут в отдельной таблице nft и снимаются при остановке."
	echo
	ask_yes_no "   Перехват DNS - завернуть :53 клиента на роутер?" "$OPT_DNS_HIJACK" &&
		OPT_DNS_HIJACK="1" || OPT_DNS_HIJACK="0"
	ask_yes_no "   Блок DoT - закрыть :853?" "$OPT_BLOCK_DOT" &&
		OPT_BLOCK_DOT="1" || OPT_BLOCK_DOT="0"
	ask_yes_no "   Блок QUIC - закрыть udp:443, иначе SNI не виден?" "$OPT_BLOCK_QUIC" &&
		OPT_BLOCK_QUIC="1" || OPT_BLOCK_QUIC="0"

	echo
	tui_section "Сброс DNS-кеша на клиенте (выполнять на самом устройстве)"
	echo "   Windows:      ipconfig /flushdns"
	echo "   macOS:        sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
	echo "   Linux:        sudo resolvectl flush-caches"
	echo "   iOS/Android:  включите и выключите авиарежим"
	echo "   Smart TV:     перезагрузите устройство полностью"
	pause_enter
	return 0
}

parse_query_line() {
	CAP_TIME=""; CAP_DOMAIN=""; CAP_CLIENT=""
	WANT_DOMAIN="0"; WANT_CLIENT="0"

	for WORD in $1; do
		if [ "$WANT_DOMAIN" = "1" ]; then
			CAP_DOMAIN="$WORD"; WANT_DOMAIN="0"; continue
		fi
		if [ "$WANT_CLIENT" = "1" ]; then
			CAP_CLIENT="$WORD"; WANT_CLIENT="0"; continue
		fi
		case "$WORD" in
			[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) [ -z "$CAP_TIME" ] && CAP_TIME="$WORD" ;;
			query\[*\]) WANT_DOMAIN="1" ;;
			from) WANT_CLIENT="1" ;;
		esac
	done

	{ [ -n "$CAP_DOMAIN" ] && [ -n "$CAP_CLIENT" ]; } || return 1

	if [ -z "$CAP_TIME" ]; then
		CAP_TIME="$(awk 'BEGIN { print strftime("%H:%M:%S") }' 2>/dev/null)"
		CAP_TIME="${CAP_TIME:-00:00:00}"
	fi
	return 0
}

# Одно и то же устройство спрашивает DNS то с IPv4, то с IPv6-адреса, поэтому
# сверяемся с обоими списками.
client_allowed() {
	[ "$1" = "all" ] && return 0
	for FILTER_IP in $2 $SELECTED_IPS6; do
		[ "$CAP_CLIENT" = "$FILTER_IP" ] && return 0
	done
	return 1
}

capture_stream() {
	MODE="$1"
	IP_LIST="$2"

	case "$CAPTURE_SOURCE" in
		dns) SOURCE_LABEL="DNS (лог dnsmasq)" ;;
		sni) SOURCE_LABEL="SNI (TLS ClientHello)" ;;
		*)   SOURCE_LABEL="DNS + SNI" ;;
	esac

	if [ "$MODE" = "all" ]; then
		TARGET_LABEL="все клиенты"
	else
		TARGET_LABEL="$IP_LIST"
		# Сколько IPv6 подтянулось: если ноль, а трафик по IPv6 идёт, значит
		# устройства ещё нет в таблице соседей.
		IPV6_COUNT="$(printf '%s' "$SELECTED_IPS6" | wc -w | tr -d ' ')"
		[ "$IPV6_COUNT" -gt 0 ] && TARGET_LABEL="$TARGET_LABEL (+$IPV6_COUNT IPv6)"
	fi

	# Единственный источник недоступен - выходим не тронув прошлый лог.
	if [ "$CAPTURE_SOURCE" = "sni" ] && ! sni_available; then
		echo "Сбор не запущен: tcpdump или интерфейс $(lan_device) недоступны."
		return 1
	fi

	if ! : > "$LOG_FILE"; then
		echo "Ошибка: не удалось создать файл $LOG_FILE."
		return 1
	fi

	# Колонку под адрес расширяем только когда в сборе возможен IPv6: при чистом
	# IPv4 широкая колонка оставляет полэкрана пустоты.
	CLIENT_COL_W="15"
	{ [ "$MODE" = "all" ] || [ -n "$(printf '%s' "$SELECTED_IPS6" | tr -d ' ')" ]; } && CLIENT_COL_W="39"

	tui_header "Live-сбор доменов" "Источник: $SOURCE_LABEL   Клиенты: $TARGET_LABEL"
	tui_hint "Любая клавиша - остановить сбор"
	echo "Лог сохраняется в: $LOG_FILE"
	echo

	# Подготовка идёт уже под шапкой: её след остаётся на экране сбора, а не
	# мелькает отдельным кадром. Перезапуск dnsmasq занимает секунду-другую,
	# и строка прогресса объясняет паузу.
	nft_guard_enable "$MODE" "$IP_LIST"
	if [ "$CAPTURE_SOURCE" != "sni" ] && ! enable_logs; then
		return 1
	fi
	echo

	# Клиента вне подсети интерфейса tcpdump не увидит: DNS по нему пойдёт,
	# SNI нет, и со стороны это выглядит как потеря половины доменов.
	if [ "$MODE" != "all" ]; then
		OFF_NET_IPS=""
		for ONE_IP in $IP_LIST; do
			client_off_capture_net "$ONE_IP" && OFF_NET_IPS="$OFF_NET_IPS $ONE_IP"
		done
		if [ -n "$(printf '%s' "$OFF_NET_IPS" | tr -d ' ')" ]; then
			tui_message "Внимание:$OFF_NET_IPS вне подсети интерфейса $(lan_device)."
			tui_message "Похоже, это другая сеть (гостевая или VLAN): DNS по ней будет, SNI - нет."
			echo
		fi
	fi

	# SRC перед доменом: домен последний, поэтому его длина никому не мешает.
	printf "%-8s %-${CLIENT_COL_W}s %-3s %s\n" "TIME" "CLIENT_IP" "SRC" "DOMAIN"
	printf '%s %s %s %s\n' "$(dashes 8)" "$(dashes "$CLIENT_COL_W")" "---" "$(dashes 40)"

	SNI_STARTED="0"
	if [ "$CAPTURE_SOURCE" != "dns" ]; then
		sni_start "$MODE" "$IP_LIST" && SNI_STARTED="1"
	fi

	if [ "$CAPTURE_SOURCE" = "sni" ] && [ "$SNI_STARTED" = "0" ]; then
		echo
		echo "Сбор не запущен: SNI - единственный выбранный источник."
		return 1
	fi

	[ "$CAPTURE_SOURCE" != "sni" ] && dns_start "$MODE" "$IP_LIST"

	# Оба источника работают фоном, здесь просто ждём нажатия. Если сборка
	# BusyBox не умеет read -s -n 1, остаётся прежний путь - Ctrl+C.
	read_char || wait
	drain_input
	capture_stop_sources

	# Открытый блок: строки снятия правил печатает capture_cleanup уже после
	# возврата отсюда, и они должны попасть в эту же секцию.
	tui_block "Сбор остановлен" "Лог сохранен: $LOG_FILE" open
	return 0
}

start_capture() {
	MODE="$1"
	IP_LIST="$2"

	SELECTED_IPS6=""
	SELECTED_MACS=""
	SELECTED_KEYS=""
	[ "$MODE" != "all" ] && expand_selected_clients "$IP_LIST"

	# Ловушки до включения чего-либо: обрыв на этапе настройки не должен
	# оставить включённым logqueries или nft-таблицу.
	trap 'echo; echo "Останавливаю live-сбор..."; capture_cleanup' INT
	trap 'capture_cleanup; exit 130' TERM HUP

	# Правила и logqueries включает сам capture_stream, уже под своей шапкой:
	# иначе эти две строки мелькали бы на отдельном экране и стирались.
	capture_stream "$MODE" "$IP_LIST"
	CAPTURE_RC="$?"

	trap - INT TERM HUP
	capture_cleanup
	print_unique_domains
	pause_enter
	return "$CAPTURE_RC"
}

# Печатает список со своим заголовком, но без очистки экрана: после сбора он
# должен лечь под собранные строки, а не заменить их.
print_unique_domains() {
	if [ ! -s "$LOG_FILE" ]; then
		tui_block "Уникальные домены" "Лог $LOG_FILE не найден или пуст"
		return 1
	fi
	tui_block "Уникальные домены" "Найдено: $(awk '{print $3}' "$LOG_FILE" | sort -u | wc -l | tr -d ' ')" open
	awk '{print $3}' "$LOG_FILE" | sort -u
	return 0
}

render_log_ip_menu() {
	tui_header "Домены по клиенту" "Выберите IP из последнего сохраненного лога"
	tui_hint "Стрелки - выбор   Enter - показать   q - назад"
	echo
	tui_section "Клиенты из лога"
	I="0"
	while IFS= read -r LOG_IP; do
		I=$((I + 1))
		render_menu_line "$1" "$I" "$LOG_IP"
	done < "$LOG_IPS_FILE"
	echo
	tui_section "Действия"
	render_menu_line "$1" $(($2 + 1)) "Назад"
}

select_log_ip() {
	if [ ! -s "$LOG_FILE" ]; then
		echo
		echo "Лог $LOG_FILE не найден или пуст."
		return 1
	fi
	awk '{print $2}' "$LOG_FILE" | sort -u > "$LOG_IPS_FILE"

	LOG_IP_TOTAL="$(awk 'END { print NR + 0 }' "$LOG_IPS_FILE")"
	if [ "$LOG_IP_TOTAL" -eq 0 ]; then
		echo
		echo "В последнем логе нет IP клиентов."
		return 1
	fi

	LOG_IP_INDEX="1"
	LOG_IP_MAX=$((LOG_IP_TOTAL + 1))
	SELECTED_LOG_IP=""
	tui_start || return 1

	while :; do
		render_log_ip_menu "$LOG_IP_INDEX" "$LOG_IP_TOTAL"
		case "$(read_key)" in
			up)   LOG_IP_INDEX=$((LOG_IP_INDEX - 1)); [ "$LOG_IP_INDEX" -lt 1 ] && LOG_IP_INDEX="$LOG_IP_MAX" ;;
			down) LOG_IP_INDEX=$((LOG_IP_INDEX + 1)); [ "$LOG_IP_INDEX" -gt "$LOG_IP_MAX" ] && LOG_IP_INDEX="1" ;;
			enter)
				tui_stop
				clear_screen
				[ "$LOG_IP_INDEX" -eq "$LOG_IP_MAX" ] && return 2
				SELECTED_LOG_IP="$(sed -n "${LOG_IP_INDEX}p" "$LOG_IPS_FILE")"
				return 0
				;;
			quit)
				tui_stop
				clear_screen
				return 2
				;;
			unsupported)
				show_tui_unsupported
				return 1
				;;
		esac
	done
}

show_unique_by_ip() {
	select_log_ip
	RC="$?"
	[ "$RC" -ne 0 ] && return "$RC"

	COUNT="$(awk -v ip="$SELECTED_LOG_IP" '$2==ip{print $3}' "$LOG_FILE" | sort -u | wc -l | tr -d ' ')"
	tui_block "Уникальные домены" "Клиент: $SELECTED_LOG_IP   Найдено: $COUNT" open
	awk -v ip="$SELECTED_LOG_IP" '$2==ip{print $3}' "$LOG_FILE" | sort -u
	return 0
}

cleanup() {
	tui_header "Сброс временных логов" "Очистка сохраненного live-лога и служебных файлов"
	tui_section "Будет выполнено"
	echo "   Вернуть dnsmasq logqueries в состояние до сбора."
	echo "   Удалить последний live-лог: $LOG_FILE"
	echo "   Удалить служебные файлы pdc в /tmp."
	echo "   Перезапустить RAM-log роутера."
	echo
	tui_section "Не выполняется"
	tui_message "   DNS-кеш на ПК/телефоне клиента этим пунктом не очищается."
	echo
	printf "%sy%s - сбросить, Enter/q - назад: " "$TUI_GREEN" "$TUI_RESET"
	read_answer tty || { echo; return 1; }

	case "$ANSWER" in
		y|Y|yes|YES|д|Д|да|Да|ДА) ;;
		*) echo; echo "Сброс отменен."; return 0 ;;
	esac

	echo
	# Сверяем сохранённое с текущим: PREV_FILE живёт и после удачного сбора, и
	# без этой проверки пункт каждый раз ронял бы DNS всей сети перезапуском
	# dnsmasq ради записи уже стоящего значения.
	CURRENT_LOGQUERIES="$(uci -q get 'dhcp.@dnsmasq[0].logqueries' 2>/dev/null)"
	CURRENT_LOGQUERIES="${CURRENT_LOGQUERIES:-unset}"
	SAVED_LOGQUERIES="$(cat "$PREV_FILE" 2>/dev/null)"

	if [ -s "$PREV_FILE" ] && [ "$SAVED_LOGQUERIES" != "$CURRENT_LOGQUERIES" ]; then
		disable_logs
	elif [ ! -s "$PREV_FILE" ] && [ "$CURRENT_LOGQUERIES" = "1" ]; then
		disable_logs
	else
		echo "dnsmasq logqueries уже в исходном состоянии"
	fi

	if command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
		nft delete table inet "$NFT_TABLE" 2>/dev/null &&
			echo "Удалена оставшаяся таблица inet $NFT_TABLE."
	fi

	# Оба источника: после жёсткого обрыва здесь может висеть и logread.
	stop_pid_file "$SNI_PID_FILE"
	stop_pid_file "$DNS_PID_FILE"

	# Глобов вроде /tmp/*dns*.log здесь быть не должно: ни один файл утилиты под
	# них не подходит, удаляли они только чужое - тот же /tmp/dnsmasq.log.
	rm -f "$LOG_FILE" "$PREV_FILE" "$CLIENTS_FILE" "$LOG_IPS_FILE" \
		"$SNI_AWK_FILE" "$SNI_ERR_FILE" "$NFT_FILE"

	echo "Очищаю RAM-log роутера..."
	if /etc/init.d/log restart; then
		echo "Сброс временных логов завершен."
	else
		echo "Предупреждение: не удалось перезапустить log."
	fi
}

ensure_interactive_input
startup_maintenance

while :; do
	select_main_menu || exit 1

	case "$MENU_CHOICE" in
		1) select_capture_targets ;;
		2) clear_screen; print_unique_domains; pause_enter ;;
		3)
			show_unique_by_ip
			[ "$?" -ne 2 ] && pause_enter
			;;
		4) cleanup; pause_enter ;;
		5)
			# Меню остаётся на экране и говорит само за себя. Пустая строка -
			# чтобы приглашение шелла не липло к нему.
			echo
			exit 0
			;;
	esac
done

# PDC-EOF
