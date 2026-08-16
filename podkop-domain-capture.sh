#!/bin/ash

# Утилита для сбора DNS-доменов из dnsmasq logs для дальнейшего добавления в Podkop.
# Совместимо с OpenWrt BusyBox ash. Не использует bash-specific синтаксис.

LOG_FILE="/tmp/podkop-domain-capture.log"
PREV_FILE="/tmp/podkop-domain-capture.logqueries.prev"
LEASES_FILE="/tmp/dhcp.leases"
CLIENTS_FILE="/tmp/podkop-domain-capture.clients"
LOG_IPS_FILE="/tmp/podkop-domain-capture.log-ips"
SNI_AWK_FILE="/tmp/podkop-domain-capture.sni.awk"
SNI_PID_FILE="/tmp/podkop-domain-capture.tcpdump.pid"
DNS_PID_FILE="/tmp/podkop-domain-capture.logread.pid"
TTY_DEV="/dev/tty"
PDC_VERSION="0.3.1-beta"

# Самообновление и зависимости.
SCRIPT_URL="${PDC_SCRIPT_URL:-https://raw.githubusercontent.com/doxfie/Podkop-Domain-Capture/main/podkop-domain-capture.sh}"
UPDATE_STAMP="/etc/podkop-domain-capture.stamp"
UPDATE_INTERVAL="86400"
TCPDUMP_PKG="tcpdump-mini"
TCPDUMP_SIZE="~385 КБ"
MAINTENANCE_NOTED="0"

# Имя временной nft-таблицы. Отдельная таблица, чтобы не трогать fw4/podkop/zapret
# и чтобы весь набор правил снимался одной командой delete table.
NFT_TABLE="pdc_capture"

# Источник доменов: dns | sni | both
CAPTURE_SOURCE="both"
# Временные сетевые правила на время сбора
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
SELECTED_LOG_IP=""
CAPTURE_ALL_SELECTED="0"
CAPTURE_MESSAGE=""
LOGS_ENABLED="0"

TUI_LINE="---------------------------------------------------------"
if [ -n "$NO_COLOR" ]; then
	TUI_RESET=""
	TUI_BOLD=""
	TUI_DIM=""
	TUI_GREEN=""
	TUI_CYAN=""
	TUI_YELLOW=""
	TUI_SELECTED=""
else
	TUI_RESET="$(printf '\033[0m')"
	TUI_BOLD="$(printf '\033[1m')"
	TUI_DIM="$(printf '\033[2m')"
	TUI_GREEN="$(printf '\033[32m')"
	TUI_CYAN="$(printf '\033[36m')"
	TUI_YELLOW="$(printf '\033[33m')"
	TUI_SELECTED="$(printf '\033[1;30;42m')"
fi

# Отключаем pathname expansion, чтобы домены/строки логов не раскрывались как glob.
set -f

ensure_interactive_input() {
	if [ -t 0 ] && [ -c "$TTY_DEV" ]; then
		return 0
	fi

	if [ -c "$TTY_DEV" ]; then
		exec < "$TTY_DEV"
		if [ -t 0 ]; then
			return 0
		fi
	fi

	echo "Интерактивный ввод недоступен."
	echo "Не запускайте меню через pipe вида: wget -O - ... | sh"
	echo "Запустите скрипт напрямую:"
	echo "pdc"
	exit 1
}

clear_screen() {
	printf '\033[H\033[J'
}

# Читает строку в ANSWER и срезает хвост. Windows-терминалы присылают CR,
# из-за чего "q" приходит как "q\r" и не совпадает ни с одним шаблоном case.
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

pause_enter() {
	echo
	printf "Нажмите Enter, чтобы продолжить..."
	IFS= read -r DUMMY || return 0
	# Экран чистим только после того, как пользователь подтвердил, что прочитал вывод.
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

	if IFS= read -r -s -n 1 READ_CHAR < "$TTY_DEV" 2>/dev/null; then
		return 0
	fi

	return 1
}

read_key() {
	if ! read_char; then
		echo "unsupported"
		return
	fi

	KEY1="$READ_CHAR"

	if [ "$KEY1" = "$ESC_CHAR" ]; then
		if ! read_char; then
			echo "other"
			return
		fi
		KEY2="$READ_CHAR"

		if ! read_char; then
			echo "other"
			return
		fi
		KEY3="$READ_CHAR"

		case "$KEY2$KEY3" in
			"[A") echo "up" ;;
			"[B") echo "down" ;;
			"OA") echo "up" ;;
			"OB") echo "down" ;;
			*) echo "other" ;;
		esac
		return
	fi

	case "$KEY1" in
		"") echo "enter" ;;
		"$CR_CHAR") echo "enter" ;;
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
	echo "Для стрелочного меню нужен один из вариантов:"
	echo "- BusyBox ash с поддержкой read -n/read -s;"
	echo "- applet stty;"
	echo "- внешний TUI-инструмент вроде dialog/whiptail."
	echo
	echo "Цифрового fallback-меню в проекте нет, поэтому на этой прошивке"
	echo "стрелочное меню может быть недоступно."
	pause_enter
}

tui_header() {
	TITLE="$1"
	SUBTITLE="$2"

	clear_screen
	printf '%s%s%s\n' "$TUI_CYAN" "$TUI_LINE" "$TUI_RESET"
	printf '%s%s%s %s[%s]%s\n' "$TUI_BOLD" "$TUI_GREEN" "$TITLE" "$TUI_DIM" "$PDC_VERSION" "$TUI_RESET"
	if [ -n "$SUBTITLE" ]; then
		printf '%s%s%s\n' "$TUI_DIM" "$SUBTITLE" "$TUI_RESET"
	fi
	printf '%s%s%s\n\n' "$TUI_CYAN" "$TUI_LINE" "$TUI_RESET"
}

tui_hint() {
	printf '%s%s%s\n' "$TUI_DIM" "$1" "$TUI_RESET"
}

tui_section() {
	printf '%s%s%s\n' "$TUI_CYAN" "$1" "$TUI_RESET"
}

tui_message() {
	printf '%s%s%s\n' "$TUI_YELLOW" "$1" "$TUI_RESET"
}

render_menu_line() {
	CURRENT="$1"
	TEXT="$2"

	if [ "$CURRENT" = "1" ]; then
		printf '%s > %s %s\n' "$TUI_SELECTED" "$TEXT" "$TUI_RESET"
	else
		printf '   %s\n' "$TEXT"
	fi
}

render_client_table_header() {
	printf '%s   %-3s %-15s %-36s %-19s %s%s\n' "$TUI_DIM" "" "IP" "Name" "MAC" "Lease" "$TUI_RESET"
}

format_client_table_row() {
	CHECK="$1"
	IP="$2"
	HOST="$3"
	MAC="$4"
	LEASE="$5"

	printf '%s %-15s %-36.36s %-19s %s' "$CHECK" "$IP" "$HOST" "$MAC" "$LEASE"
}

render_main_menu() {
	tui_header "Podkop Domain Capture" "Сбор DNS-доменов из dnsmasq logs для Podkop"
	tui_hint "Стрелки вверх/вниз - выбор   Enter - открыть   q - выход"
	echo

	tui_section "Действия"
	if [ "$1" -eq 1 ]; then
		render_menu_line 1 "Собрать домены"
	else
		render_menu_line 0 "Собрать домены"
	fi

	if [ "$1" -eq 2 ]; then
		render_menu_line 1 "Показать домены из последнего лога"
	else
		render_menu_line 0 "Показать домены из последнего лога"
	fi

	if [ "$1" -eq 3 ]; then
		render_menu_line 1 "Показать домены по клиенту из последнего лога"
	else
		render_menu_line 0 "Показать домены по клиенту из последнего лога"
	fi

	if [ "$1" -eq 4 ]; then
		render_menu_line 1 "Сбросить временные логи"
	else
		render_menu_line 0 "Сбросить временные логи"
	fi

	if [ "$1" -eq 5 ]; then
		render_menu_line 1 "Выход"
	else
		render_menu_line 0 "Выход"
	fi
}

select_main_menu() {
	MENU_INDEX="1"
	MENU_MAX="5"
	MENU_CHOICE=""

	tui_start || return 1

	while :; do
		render_main_menu "$MENU_INDEX"
		KEY="$(read_key)"

		case "$KEY" in
			up)
				MENU_INDEX=$((MENU_INDEX - 1))
				if [ "$MENU_INDEX" -lt 1 ]; then
					MENU_INDEX="$MENU_MAX"
				fi
				;;
			down)
				MENU_INDEX=$((MENU_INDEX + 1))
				if [ "$MENU_INDEX" -gt "$MENU_MAX" ]; then
					MENU_INDEX="1"
				fi
				;;
			enter)
				MENU_CHOICE="$MENU_INDEX"
				tui_stop
				# На выходе экран не чистим: пусть меню останется на виду.
				if [ "$MENU_CHOICE" != "5" ]; then
					clear_screen
				fi
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

load_clients() {
	if [ ! -s "$LEASES_FILE" ]; then
		: > "$CLIENTS_FILE"
		return
	fi

	# На OpenWrt /tmp/dhcp.leases имеет формат:
	# expires_epoch mac ip hostname client_id
	awk '
	function remaining(expire, left, d, h, m, s) {
		if (expire == 0) {
			return "never"
		}
		if (now == 0) {
			return "expires=" expire
		}
		left = expire - now
		if (left <= 0) {
			return "expired"
		}
		d = int(left / 86400)
		h = int((left % 86400) / 3600)
		m = int((left % 3600) / 60)
		s = left % 60
		if (d > 0) {
			return d "d " h "h " m "m"
		}
		if (h > 0) {
			return h "h " m "m"
		}
		if (m > 0) {
			return m "m " s "s"
		}
		return s "s"
	}
	BEGIN {
		now = systime()
	}
	{
		host = $4
		if (host == "" || host == "*") {
			host = "-"
		}
		printf "%s|%s|%s|%s\n", $3, $2, host, remaining($1)
	}' "$LEASES_FILE" > "$CLIENTS_FILE"
}

client_count() {
	awk 'END { print NR + 0 }' "$CLIENTS_FILE"
}

get_client_line() {
	sed -n "${1}p" "$CLIENTS_FILE"
}

split_client_line() {
	OLD_IFS="$IFS"
	IFS="|"
	set -- $1
	IFS="$OLD_IFS"

	CLIENT_IP="$1"
	CLIENT_MAC="$2"
	CLIENT_HOST="$3"
	CLIENT_REMAINING="$4"
}

is_ip_selected() {
	for CHECK_IP in $SELECTED_IPS; do
		if [ "$CHECK_IP" = "$1" ]; then
			return 0
		fi
	done
	return 1
}

toggle_ip_selection() {
	TOGGLE_IP="$1"

	if is_ip_selected "$TOGGLE_IP"; then
		NEW_SELECTED=""
		for CHECK_IP in $SELECTED_IPS; do
			if [ "$CHECK_IP" != "$TOGGLE_IP" ]; then
				NEW_SELECTED="$NEW_SELECTED $CHECK_IP"
			fi
		done
		SELECTED_IPS="$NEW_SELECTED"
	else
		SELECTED_IPS="$SELECTED_IPS $TOGGLE_IP"
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
	START_INDEX=$((CLIENT_TOTAL + 2))
	SETTINGS_INDEX=$((CLIENT_TOTAL + 3))
	BACK_INDEX=$((CLIENT_TOTAL + 4))

	tui_header "Сбор доменов" "Выберите клиентов, от которых нужно поймать домены"
	tui_hint "Стрелки - выбор   Space/Enter - отметить   Enter на действии - подтвердить   q - назад"
	echo

	printf '   Источник:  %s\n' "$(capture_source_label)"
	printf '   Правила:   %s\n' "$(capture_rules_label)"
	echo

	if [ "$CLIENT_TOTAL" -eq 0 ]; then
		tui_message "DHCP leases не найдены или пусты. Можно выбрать сбор от всех клиентов."
		echo
	fi

	tui_section "Клиенты"
	if [ "$CAPTURE_ALL_SELECTED" = "1" ]; then
		CHECK="[x]"
	else
		CHECK="[ ]"
	fi

	if [ "$CAPTURE_INDEX" -eq 1 ]; then
		render_menu_line 1 "$CHECK Все клиенты"
	else
		render_menu_line 0 "$CHECK Все клиенты"
	fi

	if [ "$CLIENT_TOTAL" -gt 0 ]; then
		render_client_table_header
	fi

	I="1"
	while [ "$I" -le "$CLIENT_TOTAL" ]; do
		LINE="$(get_client_line "$I")"
		split_client_line "$LINE"

		if is_ip_selected "$CLIENT_IP"; then
			CHECK="[x]"
		else
			CHECK="[ ]"
		fi

		DISPLAY="$(format_client_table_row "$CHECK" "$CLIENT_IP" "$CLIENT_HOST" "$CLIENT_MAC" "$CLIENT_REMAINING")"
		ROW_INDEX=$((I + 1))

		if [ "$CAPTURE_INDEX" -eq "$ROW_INDEX" ]; then
			render_menu_line 1 "$DISPLAY"
		else
			render_menu_line 0 "$DISPLAY"
		fi

		I=$((I + 1))
	done

	echo
	tui_section "Действия"
	if [ "$CAPTURE_INDEX" -eq "$START_INDEX" ]; then
		render_menu_line 1 "Начать сбор доменов"
	else
		render_menu_line 0 "Начать сбор доменов"
	fi

	if [ "$CAPTURE_INDEX" -eq "$SETTINGS_INDEX" ]; then
		render_menu_line 1 "Настройки сбора"
	else
		render_menu_line 0 "Настройки сбора"
	fi

	if [ "$CAPTURE_INDEX" -eq "$BACK_INDEX" ]; then
		render_menu_line 1 "Назад"
	else
		render_menu_line 0 "Назад"
	fi

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
		SETTINGS_INDEX=$((CLIENT_TOTAL + 3))
		BACK_INDEX=$((CLIENT_TOTAL + 4))

		render_capture_menu "$CAPTURE_INDEX" "$CLIENT_TOTAL"
		KEY="$(read_key)"
		CAPTURE_MESSAGE=""

		case "$KEY" in
			up)
				CAPTURE_INDEX=$((CAPTURE_INDEX - 1))
				if [ "$CAPTURE_INDEX" -lt 1 ]; then
					CAPTURE_INDEX="$CAPTURE_MAX"
				fi
				;;
			down)
				CAPTURE_INDEX=$((CAPTURE_INDEX + 1))
				if [ "$CAPTURE_INDEX" -gt "$CAPTURE_MAX" ]; then
					CAPTURE_INDEX="1"
				fi
				;;
			space|enter)
				if [ "$CAPTURE_INDEX" -eq 1 ]; then
					toggle_all_clients
					continue
				fi

				if [ "$CAPTURE_INDEX" -gt 1 ] && [ "$CAPTURE_INDEX" -le $((CLIENT_TOTAL + 1)) ]; then
					CLIENT_ROW=$((CAPTURE_INDEX - 1))
					LINE="$(get_client_line "$CLIENT_ROW")"
					split_client_line "$LINE"
					toggle_ip_selection "$CLIENT_IP"
					continue
				fi

				if [ "$KEY" = "space" ]; then
					continue
				fi

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

				if [ "$CAPTURE_INDEX" -eq "$SETTINGS_INDEX" ]; then
					tui_stop
					clear_screen
					configure_capture_advanced
					tui_start || return 1
					continue
				fi

				if [ "$CAPTURE_INDEX" -eq "$BACK_INDEX" ]; then
					tui_stop
					clear_screen
					return 0
				fi
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

lan_subnet() {
	# 192.168.1.0/24 для br-lan; пусто, если определить не удалось.
	ip -4 route show dev br-lan proto kernel 2>/dev/null | awk 'NR==1 { print $1 }'
}

router_lan_ip() {
	ip -4 addr show dev br-lan 2>/dev/null |
		awk '$1 == "inet" { split($2, a, "/"); print a[1]; exit }'
}

# Пишет awk-парсер TLS ClientHello. Держим его отдельным файлом, а не inline-строкой:
# так проще отлаживать и не воевать с экранированием внутри ash.
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

function flush(	ihl, tcp, doff, p, n, sidl, csl, cml, extl, et, el, end, nl, name, i, c) {
	if (HEX == "" || SRC == "") return
	if (b(0) < 0) return
	if (int(b(0) / 16) != 4) return
	if (b(9) != 6) return
	ihl = (b(0) % 16) * 4
	tcp = ihl
	doff = int(b(tcp + 12) / 16) * 4
	if (doff < 20) return
	p = tcp + doff
	if (b(p) != 22) return
	if (b(p + 5) != 1) return

	n = p + 43
	sidl = b(n); if (sidl < 0) return
	n += 1 + sidl
	csl = b2(n); if (csl < 0) return
	n += 2 + csl
	cml = b(n); if (cml < 0) return
	n += 1 + cml
	extl = b2(n); if (extl < 0) return
	n += 2
	end = n + extl

	while (n + 4 <= end) {
		et = b2(n); el = b2(n + 2)
		if (et < 0 || el < 0) return
		n += 4
		if (et == 0) {
			nl = b2(n + 3)
			if (nl <= 0 || nl > 253) return
			name = ""
			for (i = 0; i < nl; i++) {
				c = b(n + 5 + i)
				if (c < 33 || c > 126) return
				name = name sprintf("%c", c)
			}
			printf "%s %s %s sni\n", TS, SRC, name
			fflush()
			return
		}
		n += el
	}
}

/^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\./ {
	flush()
	HEX = ""; SRC = ""
	TS = substr($1, 1, 8)
	if ($2 == "IP") {
		nf = split($3, a, ".")
		if (nf >= 5) SRC = a[1] "." a[2] "." a[3] "." a[4]
	}
	next
}

/^[ \t]+0x[0-9a-f]+:/ {
	line = $0
	sub(/^[ \t]+0x[0-9a-f]+:[ \t]*/, "", line)
	gsub(/[ \t]/, "", line)
	HEX = HEX line
	next
}

END { flush() }
PDC_SNI_AWK
}

# Путь к самому себе. Обычный запуск - это "pdc" по имени из PATH, и тогда
# в $0 нет ни одного слэша: клеить его с текущим каталогом нельзя, надо искать
# в PATH, иначе самообновление молча решает, что файла нет.
self_path() {
	case "$0" in
		/*)
			printf '%s\n' "$0"
			;;
		*/*)
			printf '%s/%s\n' "$(pwd)" "$0"
			;;
		*)
			SELF_RESOLVED="$(command -v "$0" 2>/dev/null)"
			if [ -n "$SELF_RESOLVED" ]; then
				printf '%s\n' "$SELF_RESOLVED"
			else
				printf '%s\n' "$0"
			fi
			;;
	esac
}

fetch_url() {
	if command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" --timeout=15 "$1" 2>/dev/null && return 0
	fi
	if command -v curl >/dev/null 2>&1; then
		curl -fsS --max-time 15 -o "$2" "$1" 2>/dev/null && return 0
	fi
	return 1
}

# 0, если версия $1 строго новее $2. Суффиксы вида -beta отбрасываем.
# Нужно именно "новее", а не "отличается": иначе скрипт откатит сам себя,
# если в репозитории лежит версия старее установленной.
version_newer() {
	awk -v a="$1" -v b="$2" '
	function norm(v,	n, p, i, s) {
		sub(/-.*$/, "", v)
		n = split(v, p, ".")
		s = 0
		for (i = 1; i <= 3; i++) s = s * 1000 + (i <= n ? p[i] + 0 : 0)
		return s
	}
	BEGIN { exit !(norm(a) > norm(b)) }'
}

pkg_version() {
	if command -v apk >/dev/null 2>&1; then
		apk list -I "$1" 2>/dev/null | awk 'NR==1 { print $1 }'
	elif command -v opkg >/dev/null 2>&1; then
		opkg list-installed "$1" 2>/dev/null | awk 'NR==1 { print $3 }'
	fi
}

# Первый запуск: tcpdump обязателен, потому что SNI - основной источник.
# Три попытки, дальше выходим: продолжать без него нет смысла.
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
	if [ -n "$INSTALL_OUT" ]; then
		printf '%s\n' "$INSTALL_OUT" | tail -5
	fi
	echo
	echo "Сбор по SNI - основной режим, без tcpdump он невозможен."
	echo "Проверьте интернет и свободное место, затем запустите pdc снова."
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

update_script() {
	SELF="$(self_path)"
	if [ ! -w "$SELF" ]; then
		return 0
	fi

	NEW_FILE="/tmp/podkop-domain-capture.new"
	rm -f "$NEW_FILE"
	if ! fetch_url "$SCRIPT_URL" "$NEW_FILE"; then
		rm -f "$NEW_FILE"
		return 0
	fi

	# Санитарная проверка: это должен быть наш скрипт целиком, а не 404-страница
	# и не обрезанная закачка.
	if ! head -n 1 "$NEW_FILE" | grep -q '^#!/bin/ash'; then
		rm -f "$NEW_FILE"
		return 0
	fi
	if [ "$(wc -c < "$NEW_FILE")" -lt 10000 ]; then
		rm -f "$NEW_FILE"
		return 0
	fi

	REMOTE_VERSION="$(grep -m1 '^PDC_VERSION=' "$NEW_FILE" | cut -d'"' -f2)"
	if [ -z "$REMOTE_VERSION" ]; then
		rm -f "$NEW_FILE"
		return 0
	fi

	if ! version_newer "$REMOTE_VERSION" "$PDC_VERSION"; then
		rm -f "$NEW_FILE"
		return 0
	fi

	echo "Доступна версия $REMOTE_VERSION (установлена $PDC_VERSION), обновляю..."
	if ! cat "$NEW_FILE" > "$SELF"; then
		echo "Предупреждение: не удалось записать $SELF, продолжаю на текущей версии."
		rm -f "$NEW_FILE"
		return 0
	fi
	chmod +x "$SELF"
	rm -f "$NEW_FILE"
	echo "Обновлено до $REMOTE_VERSION, перезапускаю..."
	PDC_UPDATED=1 exec "$SELF"
}

update_due() {
	if [ ! -f "$UPDATE_STAMP" ]; then
		return 0
	fi
	NOW="$(date +%s 2>/dev/null)"
	THEN="$(cat "$UPDATE_STAMP" 2>/dev/null)"
	case "$NOW$THEN" in
		*[!0-9]*|"") return 0 ;;
	esac
	if [ "$((NOW - THEN))" -ge "$UPDATE_INTERVAL" ]; then
		return 0
	fi
	return 1
}

mark_update_done() {
	date +%s > "$UPDATE_STAMP" 2>/dev/null
}

startup_maintenance() {
	if ! command -v tcpdump >/dev/null 2>&1; then
		install_tcpdump_or_die
		mark_update_done
	else
		# Уже перезапускались после обновления - второй круг не нужен.
		if [ -z "$PDC_UPDATED" ] && update_due; then
			echo "Проверяю обновления..."
			mark_update_done
			update_tcpdump
			# Может не вернуться: обновит скрипт и сделает exec.
			update_script
			if [ "$MAINTENANCE_NOTED" = "0" ]; then
				echo "Всё актуально."
			fi
		fi
	fi

	if [ "$MAINTENANCE_NOTED" = "1" ]; then
		pause_enter
	fi
	return 0
}

# BPF-фильтр: только TLS ClientHello от нужных клиентов.
build_bpf_filter() {
	BPF_MODE="$1"
	BPF_IPS="$2"
	BPF_HOSTS=""

	if [ "$BPF_MODE" = "all" ]; then
		ROUTER_IP="$(router_lan_ip)"
		if [ -n "$ROUTER_IP" ]; then
			BPF_HOSTS="not src host $ROUTER_IP"
		fi
	else
		for ONE_IP in $BPF_IPS; do
			if [ -z "$BPF_HOSTS" ]; then
				BPF_HOSTS="src host $ONE_IP"
			else
				BPF_HOSTS="$BPF_HOSTS or src host $ONE_IP"
			fi
		done
		if [ -n "$BPF_HOSTS" ]; then
			BPF_HOSTS="($BPF_HOSTS)"
		fi
	fi

	# tcp[12] старшие 4 бита - data offset; первый байт payload 0x16 = TLS handshake.
	BPF_BASE='tcp and tcp[((tcp[12:1]&0xf0)>>2)]=0x16'
	if [ -n "$BPF_HOSTS" ]; then
		printf '%s and %s\n' "$BPF_BASE" "$BPF_HOSTS"
	else
		printf '%s\n' "$BPF_BASE"
	fi
}

nft_guard_enable() {
	NFT_MODE="$1"
	NFT_IPS="$2"

	if ! command -v nft >/dev/null 2>&1; then
		echo "Предупреждение: nft не найден, сетевые правила пропущены."
		return 1
	fi

	if [ "$OPT_DNS_HIJACK" != "1" ] && [ "$OPT_BLOCK_DOT" != "1" ] && [ "$OPT_BLOCK_QUIC" != "1" ]; then
		return 0
	fi

	if [ "$NFT_MODE" = "all" ]; then
		NFT_SADDR="$(lan_subnet)"
		if [ -z "$NFT_SADDR" ]; then
			echo "Предупреждение: не удалось определить подсеть br-lan, правила пропущены."
			return 1
		fi
		NFT_SRC_LIST="$NFT_SADDR"
	else
		NFT_SRC_LIST="$NFT_IPS"
	fi

	nft delete table inet "$NFT_TABLE" 2>/dev/null

	{
		printf 'table inet %s {\n' "$NFT_TABLE"
		if [ "$OPT_DNS_HIJACK" = "1" ]; then
			printf '\tchain pdc_nat_pre {\n'
			printf '\t\ttype nat hook prerouting priority dstnat - 5; policy accept;\n'
			for ONE_SRC in $NFT_SRC_LIST; do
				printf '\t\tip saddr %s udp dport 53 counter redirect to :53 comment "pdc-dns-hijack"\n' "$ONE_SRC"
				printf '\t\tip saddr %s tcp dport 53 counter redirect to :53 comment "pdc-dns-hijack"\n' "$ONE_SRC"
			done
			printf '\t}\n'
		fi
		if [ "$OPT_BLOCK_DOT" = "1" ] || [ "$OPT_BLOCK_QUIC" = "1" ]; then
			printf '\tchain pdc_fwd {\n'
			printf '\t\ttype filter hook forward priority filter - 5; policy accept;\n'
			for ONE_SRC in $NFT_SRC_LIST; do
				if [ "$OPT_BLOCK_DOT" = "1" ]; then
					printf '\t\tip saddr %s tcp dport 853 counter reject with tcp reset comment "pdc-block-dot"\n' "$ONE_SRC"
					printf '\t\tip saddr %s udp dport 853 counter drop comment "pdc-block-dot"\n' "$ONE_SRC"
				fi
				if [ "$OPT_BLOCK_QUIC" = "1" ]; then
					printf '\t\tip saddr %s udp dport 443 counter drop comment "pdc-block-quic"\n' "$ONE_SRC"
				fi
			done
			printf '\t}\n'
		fi
		printf '}\n'
	} > /tmp/podkop-domain-capture.nft

	if ! nft -f /tmp/podkop-domain-capture.nft; then
		echo "Ошибка: не удалось загрузить временные nft-правила."
		rm -f /tmp/podkop-domain-capture.nft
		return 1
	fi

	rm -f /tmp/podkop-domain-capture.nft
	NFT_ACTIVE="1"
	echo "Временные сетевые правила включены (таблица inet $NFT_TABLE)"
	return 0
}

nft_guard_disable() {
	if [ "$NFT_ACTIVE" != "1" ]; then
		return 0
	fi
	if nft delete table inet "$NFT_TABLE" 2>/dev/null; then
		echo "Временные сетевые правила сняты"
	else
		echo "Предупреждение: не удалось снять таблицу inet $NFT_TABLE."
		echo "Снимите вручную: nft delete table inet $NFT_TABLE"
	fi
	NFT_ACTIVE="0"
	return 0
}

sni_start() {
	SNI_MODE="$1"
	SNI_IPS="$2"

	write_sni_awk
	SNI_FILTER="$(build_bpf_filter "$SNI_MODE" "$SNI_IPS")"
	rm -f "$SNI_PID_FILE"

	# Внутренний sh пишет свой PID и делает exec tcpdump, поэтому в PID-файле
	# оказывается именно tcpdump и мы можем остановить его точечно.
	sh -c 'echo $$ > "$1"; exec tcpdump -i br-lan -nn -l -s 0 -x "$2" 2>/dev/null' \
		_ "$SNI_PID_FILE" "$SNI_FILTER" |
		awk -f "$SNI_AWK_FILE" |
		while IFS= read -r SNI_LINE; do
			printf '%s\n' "$SNI_LINE"
			printf '%s\n' "$SNI_LINE" >> "$LOG_FILE"
		done &

	SNI_ACTIVE="1"
	return 0
}

sni_stop() {
	if [ "$SNI_ACTIVE" != "1" ]; then
		return 0
	fi
	if [ -s "$SNI_PID_FILE" ]; then
		kill "$(cat "$SNI_PID_FILE")" 2>/dev/null
	fi
	rm -f "$SNI_PID_FILE"
	SNI_ACTIVE="0"
	return 0
}

# DNS-источник тоже работает фоном - в переднем плане ждём нажатия клавиши.
dns_start() {
	DNS_MODE="$1"
	DNS_IPS="$2"
	rm -f "$DNS_PID_FILE"

	# Тот же приём, что и с tcpdump: внутренний sh пишет свой PID и делает
	# exec logread, поэтому в PID-файле оказывается именно logread.
	sh -c 'echo $$ > "$1"; exec logread -f -e dnsmasq' _ "$DNS_PID_FILE" |
		while IFS= read -r LINE; do
			if ! parse_query_line "$LINE"; then
				continue
			fi
			if ! client_allowed "$DNS_MODE" "$DNS_IPS"; then
				continue
			fi
			printf '%s %s %s dns\n' "$CAP_TIME" "$CAP_CLIENT" "$CAP_DOMAIN"
			printf '%s %s %s dns\n' "$CAP_TIME" "$CAP_CLIENT" "$CAP_DOMAIN" >> "$LOG_FILE"
		done &

	DNS_ACTIVE="1"
	return 0
}

dns_stop() {
	if [ "$DNS_ACTIVE" != "1" ]; then
		return 0
	fi
	if [ -s "$DNS_PID_FILE" ]; then
		kill "$(cat "$DNS_PID_FILE")" 2>/dev/null
	fi
	rm -f "$DNS_PID_FILE"
	DNS_ACTIVE="0"
	return 0
}

# Останавливает оба источника и даёт им дописать хвост: иначе последние
# строки вылезают уже поверх сообщений об остановке.
capture_stop_sources() {
	STOP_NEEDED="0"
	if [ "$SNI_ACTIVE" = "1" ] || [ "$DNS_ACTIVE" = "1" ]; then
		STOP_NEEDED="1"
	fi

	sni_stop
	dns_stop

	if [ "$STOP_NEEDED" = "1" ]; then
		sleep 1
	fi
	return 0
}

enable_logs() {
	echo
	# Одна строка с прогрессом: перезапуск dnsmasq проходит быстро, и пара
	# сообщений "делаю"/"сделано" всё равно появлялась бы одновременно.
	printf 'Включаю dnsmasq logqueries... '

	CURRENT_LOGQUERIES="$(uci -q get 'dhcp.@dnsmasq[0].logqueries' 2>/dev/null)"
	if [ -z "$CURRENT_LOGQUERIES" ]; then
		CURRENT_LOGQUERIES="unset"
	fi
	printf '%s\n' "$CURRENT_LOGQUERIES" > "$PREV_FILE" 2>/dev/null

	if ! uci set 'dhcp.@dnsmasq[0].logqueries=1'; then
		echo
		echo "Ошибка: не удалось выполнить uci set"
		return 1
	fi
	if ! uci commit dhcp; then
		echo
		echo "Ошибка: не удалось выполнить uci commit dhcp"
		return 1
	fi
	# Перезапуск дёргает netifd, тот пишет в консоль udhcpc-строки. Прячем их,
	# но сохраняем вывод, чтобы показать при реальной ошибке.
	if ! RESTART_OUT="$(/etc/init.d/dnsmasq restart 2>&1)"; then
		echo
		echo "Ошибка: не удалось перезапустить dnsmasq"
		printf '%s\n' "$RESTART_OUT"
		return 1
	fi

	echo "готово"
	LOGS_ENABLED="1"
	return 0
}

# Возвращает logqueries к значению, сохранённому перед сбором. Раньше здесь
# всегда выставлялся 0, поэтому у тех, у кого лог запросов был включён до
# запуска утилиты, он оказывался выключён после выхода.
disable_logs() {
	RESTORE_TO="$(cat "$PREV_FILE" 2>/dev/null)"
	case "$RESTORE_TO" in
		0|1|unset) ;;
		*) RESTORE_TO="0" ;;
	esac

	if [ "$RESTORE_TO" = "0" ]; then
		printf 'Выключаю dnsmasq logqueries... '
	else
		printf 'Возвращаю dnsmasq logqueries... '
	fi

	if [ "$RESTORE_TO" = "unset" ]; then
		# rc=1 здесь означает, что опции и так нет, а это нужный нам результат,
		# поэтому проверяем итог, а не код возврата.
		uci -q delete 'dhcp.@dnsmasq[0].logqueries'
		if [ -n "$(uci -q get 'dhcp.@dnsmasq[0].logqueries')" ]; then
			echo
			echo "Ошибка: не удалось убрать logqueries"
			return 1
		fi
	elif ! uci set "dhcp.@dnsmasq[0].logqueries=$RESTORE_TO"; then
		echo
		echo "Ошибка: не удалось выполнить uci set"
		return 1
	fi
	if ! uci commit dhcp; then
		echo
		echo "Ошибка: не удалось выполнить uci commit dhcp"
		return 1
	fi
	# Перезапуск дёргает netifd, тот пишет в консоль udhcpc-строки. Прячем их,
	# но сохраняем вывод, чтобы показать при реальной ошибке.
	if ! RESTART_OUT="$(/etc/init.d/dnsmasq restart 2>&1)"; then
		echo
		echo "Ошибка: не удалось перезапустить dnsmasq"
		printf '%s\n' "$RESTART_OUT"
		return 1
	fi

	echo "готово"
	LOGS_ENABLED="0"
	return 0
}

capture_cleanup() {
	capture_stop_sources
	nft_guard_disable
	if [ "$LOGS_ENABLED" = "1" ]; then
		disable_logs
	fi
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
	RULES_LABEL=""
	if [ "$OPT_DNS_HIJACK" = "1" ]; then
		RULES_LABEL="перехват DNS"
	fi
	if [ "$OPT_BLOCK_DOT" = "1" ]; then
		if [ -n "$RULES_LABEL" ]; then
			RULES_LABEL="$RULES_LABEL, блок DoT"
		else
			RULES_LABEL="блок DoT"
		fi
	fi
	if [ "$OPT_BLOCK_QUIC" = "1" ]; then
		if [ -n "$RULES_LABEL" ]; then
			RULES_LABEL="$RULES_LABEL, блок QUIC"
		else
			RULES_LABEL="блок QUIC"
		fi
	fi
	if [ -z "$RULES_LABEL" ]; then
		RULES_LABEL="выключены"
	fi
	printf '%s\n' "$RULES_LABEL"
}

ask_yes_no() {
	# $1 - текст, $2 - текущее значение. Возвращает 0 = да, 1 = нет.
	if [ "$2" = "1" ]; then
		printf '%s [Y/n]: ' "$1"
	else
		printf '%s [y/N]: ' "$1"
	fi
	if ! read_answer tty; then
		echo
		return "$([ "$2" = "1" ] && echo 0 || echo 1)"
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
	if ! read_answer tty; then
		echo
		return 1
	fi
	case "$ANSWER" in
		1) CAPTURE_SOURCE="both" ;;
		2) CAPTURE_SOURCE="dns" ;;
		3) CAPTURE_SOURCE="sni" ;;
	esac

	echo
	tui_section "Временные правила на время сбора"
	tui_message "   Живут в отдельной таблице nft и снимаются при остановке."
	echo
	if ask_yes_no "   Перехват DNS - завернуть :53 клиента на роутер?" "$OPT_DNS_HIJACK"; then
		OPT_DNS_HIJACK="1"
	else
		OPT_DNS_HIJACK="0"
	fi
	if ask_yes_no "   Блок DoT - закрыть :853?" "$OPT_BLOCK_DOT"; then
		OPT_BLOCK_DOT="1"
	else
		OPT_BLOCK_DOT="0"
	fi
	if ask_yes_no "   Блок QUIC - закрыть udp:443, иначе SNI не виден?" "$OPT_BLOCK_QUIC"; then
		OPT_BLOCK_QUIC="1"
	else
		OPT_BLOCK_QUIC="0"
	fi

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
	CAP_LINE="$1"
	CAP_TIME=""
	CAP_DOMAIN=""
	CAP_CLIENT=""
	WANT_DOMAIN="0"
	WANT_CLIENT="0"

	for WORD in $CAP_LINE; do
		if [ "$WANT_DOMAIN" = "1" ]; then
			CAP_DOMAIN="$WORD"
			WANT_DOMAIN="0"
			continue
		fi

		if [ "$WANT_CLIENT" = "1" ]; then
			CAP_CLIENT="$WORD"
			WANT_CLIENT="0"
			continue
		fi

		case "$WORD" in
			[0-9][0-9]:[0-9][0-9]:[0-9][0-9])
				if [ -z "$CAP_TIME" ]; then
					CAP_TIME="$WORD"
				fi
				;;
			query\[*\])
				WANT_DOMAIN="1"
				;;
			from)
				WANT_CLIENT="1"
				;;
		esac
	done

	if [ -z "$CAP_DOMAIN" ] || [ -z "$CAP_CLIENT" ]; then
		return 1
	fi

	if [ -z "$CAP_TIME" ]; then
		CAP_TIME="$(awk 'BEGIN { print strftime("%H:%M:%S") }' 2>/dev/null)"
		if [ -z "$CAP_TIME" ]; then
			CAP_TIME="00:00:00"
		fi
	fi

	return 0
}

client_allowed() {
	if [ "$1" = "all" ]; then
		return 0
	fi

	for FILTER_IP in $2; do
		if [ "$CAP_CLIENT" = "$FILTER_IP" ]; then
			return 0
		fi
	done

	return 1
}

capture_stream() {
	MODE="$1"
	IP_LIST="$2"

	if ! : > "$LOG_FILE"; then
		echo "Ошибка: не удалось создать файл $LOG_FILE."
		return 1
	fi

	# Чистим экран до старта сбора: сообщения про nft и logqueries уже не нужны,
	# а живые строки должны идти на пустом экране.
	case "$CAPTURE_SOURCE" in
		dns) SOURCE_LABEL="DNS (лог dnsmasq)" ;;
		sni) SOURCE_LABEL="SNI (TLS ClientHello)" ;;
		*)   SOURCE_LABEL="DNS + SNI" ;;
	esac

	if [ "$MODE" = "all" ]; then
		TARGET_LABEL="все клиенты"
	else
		TARGET_LABEL="$IP_LIST"
	fi

	tui_header "Live-сбор доменов" "Источник: $SOURCE_LABEL   Клиенты: $TARGET_LABEL"
	tui_hint "Любая клавиша - остановить сбор"
	echo "Лог сохраняется в: $LOG_FILE"
	echo
	echo "TIME     CLIENT_IP       DOMAIN                         SRC"
	echo "-------- --------------- ------------------------------ ---"

	if [ "$CAPTURE_SOURCE" = "sni" ] || [ "$CAPTURE_SOURCE" = "both" ]; then
		sni_start "$MODE" "$IP_LIST"
	fi
	if [ "$CAPTURE_SOURCE" = "dns" ] || [ "$CAPTURE_SOURCE" = "both" ]; then
		dns_start "$MODE" "$IP_LIST"
	fi

	# Оба источника работают фоном, здесь просто ждём нажатия. Если сборка
	# BusyBox не умеет read -s -n 1, остаётся прежний путь - Ctrl+C.
	if ! read_char; then
		wait
	fi

	capture_stop_sources

	echo
	echo "Сбор остановлен"
	echo "Лог сохранен: $LOG_FILE"
	return 0
}

ask_show_unique() {
	echo
	printf "Вывести уникальные домены из сохраненного лога? [y/N]: "
	if ! read_answer; then
		echo
		return 0
	fi

	case "$ANSWER" in
		y|Y|yes|YES|д|Д|да|Да|ДА)
			show_unique
			;;
		*)
			echo "Ок, можно посмотреть позже из главного меню."
			;;
	esac
}

start_capture() {
	MODE="$1"
	IP_LIST="$2"

	# Ставим ловушки до включения чего-либо: обрыв на этапе настройки
	# не должен оставить включённым logqueries или nft-таблицу.
	trap 'echo; echo "Останавливаю live-сбор..."; capture_cleanup' INT
	trap 'capture_cleanup; exit 130' TERM HUP

	nft_guard_enable "$MODE" "$IP_LIST"

	if [ "$CAPTURE_SOURCE" != "sni" ]; then
		if ! enable_logs; then
			capture_cleanup
			trap - INT TERM HUP
			pause_enter
			return 1
		fi
	fi

	capture_stream "$MODE" "$IP_LIST"
	CAPTURE_RC="$?"

	trap - INT TERM HUP
	capture_cleanup
	ask_show_unique
	pause_enter
	return "$CAPTURE_RC"
}

show_unique() {
	tui_header "Уникальные домены" "Результат последнего сбора"

	if [ ! -s "$LOG_FILE" ]; then
		echo "Лог $LOG_FILE не найден или пуст."
		return 1
	fi

	echo "Уникальные домены из последнего лога:"
	awk '{print $3}' "$LOG_FILE" | sort -u

	# Домены, которые видны только по SNI, — это те, что клиент открыл без DNS-запроса
	# к роутеру: закешированный ответ, свой DoH/DoT или зашитый IP.
	# Именно они раньше терялись полностью.
	ONLY_SNI="$(awk '
		$4 == "dns" { seen_dns[$3] = 1 }
		$4 == "sni" { seen_sni[$3] = 1 }
		END { for (d in seen_sni) if (!(d in seen_dns)) print d }
	' "$LOG_FILE" | sort -u)"

	if [ -n "$ONLY_SNI" ]; then
		echo
		echo "Из них пойманы только по SNI (DNS-запроса к роутеру не было):"
		printf '%s\n' "$ONLY_SNI"
	fi

	return 0
}

build_log_ips() {
	if [ ! -s "$LOG_FILE" ]; then
		: > "$LOG_IPS_FILE"
		return 1
	fi

	awk '{print $2}' "$LOG_FILE" | sort -u > "$LOG_IPS_FILE"
	return 0
}

log_ip_count() {
	awk 'END { print NR + 0 }' "$LOG_IPS_FILE"
}

get_log_ip() {
	sed -n "${1}p" "$LOG_IPS_FILE"
}

render_log_ip_menu() {
	LOG_IP_INDEX="$1"
	LOG_IP_TOTAL="$2"
	LOG_IP_BACK=$((LOG_IP_TOTAL + 1))

	tui_header "Домены по клиенту" "Выберите IP из последнего сохраненного лога"
	tui_hint "Стрелки - выбор   Enter - показать   q - назад"
	echo

	tui_section "Клиенты из лога"
	I="1"
	while [ "$I" -le "$LOG_IP_TOTAL" ]; do
		LOG_IP="$(get_log_ip "$I")"
		if [ "$LOG_IP_INDEX" -eq "$I" ]; then
			render_menu_line 1 "$LOG_IP"
		else
			render_menu_line 0 "$LOG_IP"
		fi
		I=$((I + 1))
	done

	echo
	tui_section "Действия"
	if [ "$LOG_IP_INDEX" -eq "$LOG_IP_BACK" ]; then
		render_menu_line 1 "Назад"
	else
		render_menu_line 0 "Назад"
	fi
}

select_log_ip() {
	if ! build_log_ips; then
		echo
		echo "Лог $LOG_FILE не найден или пуст."
		return 1
	fi

	LOG_IP_TOTAL="$(log_ip_count)"
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
		LOG_IP_BACK=$((LOG_IP_TOTAL + 1))
		render_log_ip_menu "$LOG_IP_INDEX" "$LOG_IP_TOTAL"
		KEY="$(read_key)"

		case "$KEY" in
			up)
				LOG_IP_INDEX=$((LOG_IP_INDEX - 1))
				if [ "$LOG_IP_INDEX" -lt 1 ]; then
					LOG_IP_INDEX="$LOG_IP_MAX"
				fi
				;;
			down)
				LOG_IP_INDEX=$((LOG_IP_INDEX + 1))
				if [ "$LOG_IP_INDEX" -gt "$LOG_IP_MAX" ]; then
					LOG_IP_INDEX="1"
				fi
				;;
			enter)
				if [ "$LOG_IP_INDEX" -eq "$LOG_IP_BACK" ]; then
					tui_stop
					clear_screen
					return 2
				fi
				SELECTED_LOG_IP="$(get_log_ip "$LOG_IP_INDEX")"
				tui_stop
				clear_screen
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
	SELECT_LOG_IP_RC="$?"
	if [ "$SELECT_LOG_IP_RC" -ne 0 ]; then
		return "$SELECT_LOG_IP_RC"
	fi

	echo
	echo "Уникальные домены из последнего лога для $SELECTED_LOG_IP:"
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
	if ! read_answer tty; then
		echo
		return 1
	fi

	case "$ANSWER" in
		y|Y|yes|YES|д|Д|да|Да|ДА) ;;
		*)
			echo
			echo "Сброс отменен."
			return 0
			;;
	esac

	echo
	# Сохранённое значение важнее текущего: если сбор оборвался, восстанавливать
	# надо именно его, а не просто выставлять 0.
	CURRENT_LOGQUERIES="$(uci -q get 'dhcp.@dnsmasq[0].logqueries' 2>/dev/null)"
	if [ -s "$PREV_FILE" ] || [ "$CURRENT_LOGQUERIES" = "1" ]; then
		disable_logs
	else
		echo "dnsmasq logqueries уже в исходном состоянии"
	fi

	if command -v nft >/dev/null 2>&1; then
		if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
			nft delete table inet "$NFT_TABLE" 2>/dev/null &&
				echo "Удалена оставшаяся таблица inet $NFT_TABLE."
		fi
	fi

	if [ -s "$SNI_PID_FILE" ]; then
		kill "$(cat "$SNI_PID_FILE")" 2>/dev/null
	fi

	rm -f "$LOG_FILE"
	rm -f "$PREV_FILE"
	rm -f "$CLIENTS_FILE"
	rm -f "$LOG_IPS_FILE"
	rm -f "$SNI_AWK_FILE"
	rm -f "$SNI_PID_FILE"

	# Для удаления временных файлов по glob временно включаем pathname expansion.
	set +f
	rm -f /tmp/*domains*.log
	rm -f /tmp/*dns*.log
	set -f

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
		1)
			select_capture_targets
			;;
		2)
			show_unique
			pause_enter
			;;
		3)
			show_unique_by_ip
			SHOW_BY_IP_RC="$?"
			if [ "$SHOW_BY_IP_RC" -ne 2 ]; then
				pause_enter
			fi
			;;
		4)
			cleanup
			pause_enter
			;;
		5)
			# Ничего не печатаем: меню остаётся на экране и говорит само за себя.
			# Пустая строка - только чтобы приглашение шелла не липло к меню.
			echo
			exit 0
			;;
	esac
done
