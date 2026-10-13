#!/bin/sh
# Общие примитивы для Telegram-хуков Claude Code.
# Подключается через: . "$HOME/.claude/hooks/tg-notify-lib.sh"
#
# Секреты (TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID) берутся:
#   1) из окружения, если заданы (например, блок env в ~/.claude/settings.json);
#   2) иначе — из файла ~/.claude/telegram-notify.env (НЕ коммитится в репозиторий).
# Так публичный репозиторий не содержит ключей, а механика работает в обоих случаях.

# подхватить секреты из env-файла, если их нет в окружении
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
  [ -f "$HOME/.claude/telegram-notify.env" ] && . "$HOME/.claude/telegram-notify.env"
fi

# база Bot API; переопределяется в тестах (mock-сервер) или для зеркала/прокси
TG_API="${TELEGRAM_API_BASE:-https://api.telegram.org}"

# разделитель-шапка: встроенные сообщения с 2026-10-13 без полосы сверху, константа оставлена
# только для сторонних хуков, подключающих эту библиотеку
# shellcheck disable=SC2034  # TG_SEP используется внешними хуками
TG_SEP="━━━━━━━━━━━━━━━"

# короткое имя машины («MacBook Pro» / «MacBook Mini») — бот общий для обеих машин, и без
# метки уведомления от них не различить. Зовётся только при сборке сообщения, не на
# каждом хуке (scutil — лишний процесс, а permit висит на КАЖДОМ PreToolUse).
tg_host() {
  # полный путь: /usr/sbin бывает не в PATH хука — тогда вместо «MacBook Pro» вышло бы
  # сетевое имя (hostname); на Linux scutil нет — сразу hostname
  h=$(/usr/sbin/scutil --get ComputerName 2>/dev/null | sed "s/^.*’s //")
  printf '%s' "${h:-$(hostname -s)}"
}

# HTML-экранирование для parse_mode=HTML
tg_esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# отладочный лог ($1 = строка). Пишет в /tmp/claude_notif_debug.log только если
# есть файл-флаг ~/.claude/telegram-notify.debug. Помогает поймать реальную
# последовательность событий (например, лишний Stop при compact).
tg_log() {
  [ -f "$HOME/.claude/telegram-notify.debug" ] || return 0
  printf '%s | %s\n' "$(date '+%H:%M:%S')" "$1" >> /tmp/claude_notif_debug.log 2>/dev/null
}

# строка со ссылкой Remote Control из транскрипта ($1 = transcript_path);
# печатает пустоту, если remote не включён или транскрипта нет
tg_rc_line() {
  [ -n "$1" ] && [ -f "$1" ] || return 0
  url=$(grep '"subtype":"bridge_status"' "$1" | tail -1 | jq -r '.url // empty')
  [ -n "$url" ] && printf '\n\n\360\237\214\220 %s' "$url"
}

# уведомления включены: файл-флаг ~/.claude/telegram-notify.on либо env TELEGRAM_NOTIFY=1
# (lib пересчитывается с диска на каждый хук — флаг видят и уже запущенные сессии)
tg_enabled() {
  [ -f "$HOME/.claude/telegram-notify.on" ] || [ "${TELEGRAM_NOTIFY:-0}" = "1" ]
}

# вызов метода Bot API ($1 = метод, остальное — аргументы curl); печатает JSON-ответ.
# Таймаут 10 с; для длинного опроса его поднимает tg_updates через tg_maxtime.
# TELEGRAM_CURL_OPTS — дополнительные опции curl для всех вызовов Bot API (например,
# `--noproxy api.telegram.org`, если прокси из окружения только замедляет обращение).
tg_api() {
  tg_m="$1"; shift
  # shellcheck disable=SC2086  # TELEGRAM_CURL_OPTS — набор опций, разбиение по пробелам нужно
  curl -s --max-time "${tg_maxtime:-10}" $TELEGRAM_CURL_OPTS -X POST "$TG_API/bot${TELEGRAM_BOT_TOKEN}/$tg_m" "$@" 2>/dev/null
}

# отправка готового HTML-текста в Telegram ($1 = текст)
# Выключено (нет флага и TELEGRAM_NOTIFY=1) — тихо ничего не шлёт.
tg_send() {
  tg_enabled || return 0
  resp=$(tg_api sendMessage \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode=HTML \
    -d disable_web_page_preview=true \
    --data-urlencode "text=$1")
  # печатает message_id отправленного сообщения (для последующего удаления)
  printf '%s' "$resp" | jq -r '.result.message_id // empty' 2>/dev/null
}

# то же с инлайн-клавиатурой ($1 = HTML-текст, $2 = JSON reply_markup); печатает message_id
tg_send_kb() {
  tg_enabled || return 0
  resp=$(tg_api sendMessage \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode=HTML \
    -d disable_web_page_preview=true \
    --data-urlencode "text=$1" \
    --data-urlencode "reply_markup=$2")
  printf '%s' "$resp" | jq -r '.result.message_id // empty' 2>/dev/null
}

# правка текста сообщения ($1 = message_id, $2 = HTML-текст, $3 = JSON reply_markup;
# без $3 клавиатура снимается); тихо
tg_edit() {
  [ -n "$1" ] || return 0
  tg_kb="${3:-}"
  [ -n "$tg_kb" ] || tg_kb='{"inline_keyboard":[]}'
  tg_api editMessageText \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d message_id="$1" \
    -d parse_mode=HTML \
    -d disable_web_page_preview=true \
    --data-urlencode "text=$2" \
    --data-urlencode "reply_markup=$tg_kb" >/dev/null
}

# правка только клавиатуры ($1 = message_id, $2 = JSON reply_markup; пусто — снять); тихо
tg_edit_kb() {
  [ -n "$1" ] || return 0
  tg_kb="${2:-}"
  [ -n "$tg_kb" ] || tg_kb='{"inline_keyboard":[]}'
  tg_api editMessageReplyMarkup \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d message_id="$1" \
    --data-urlencode "reply_markup=$tg_kb" >/dev/null
}

# ответ на нажатие кнопки ($1 = callback_query_id, $2 = всплывающий текст); гасит «часики».
# Уходит в фоне: один вызов Bot API через VPN занимает ~1 с, и ждать его незачем.
tg_cb_answer() {
  [ -n "$1" ] || return 0
  ( tg_api answerCallbackQuery \
      -d callback_query_id="$1" \
      --data-urlencode "text=${2:-}" >/dev/null 2>&1 & )
}

# непрочитанные обновления: только нажатия кнопок и сообщения ($1 = offset, пусто — все
# неподтверждённые; $2 = секунды длинного опроса, по умолчанию 0 — ответ сразу). Длинный
# опрос возвращается в момент нажатия, без ожидания следующего цикла. Если соседний хук или
# машина на том же боте опрашивает одновременно, Telegram обрывает старый запрос (409) —
# обновления при этом не теряются, опрос просто повторяется. Печатает JSON-ответ getUpdates.
tg_updates() {
  tg_maxtime=$(( ${2:-0} + 10 ))
  if [ -n "$1" ]; then
    tg_api getUpdates -d offset="$1" -d timeout="${2:-0}" -d limit=100 \
      --data-urlencode 'allowed_updates=["callback_query","message"]'
  else
    tg_api getUpdates -d timeout="${2:-0}" -d limit=100 \
      --data-urlencode 'allowed_updates=["callback_query","message"]'
  fi
  tg_maxtime=
}

# удаление ранее отправленного сообщения ($1 = message_id); тихо, без вывода
tg_delete() {
  [ -n "$1" ] || return 0
  # shellcheck disable=SC2086  # см. tg_api
  curl -s --max-time 5 $TELEGRAM_CURL_OPTS -X POST "$TG_API/bot${TELEGRAM_BOT_TOKEN}/deleteMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d message_id="$1" >/dev/null 2>&1
}
