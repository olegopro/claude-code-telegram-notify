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

# разделитель-шапка сообщений (используется в хуках, подключающих эту библиотеку)
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

# отправка готового HTML-текста в Telegram ($1 = текст)
# выключатель: включено, если есть файл-флаг ~/.claude/telegram-notify.on
# (lib пересчитывается с диска на каждый хук — флаг видят и уже запущенные сессии)
# либо env TELEGRAM_NOTIFY=1. Иначе тихо ничего не шлёт.
tg_send() {
  if [ ! -f "$HOME/.claude/telegram-notify.on" ] && [ "${TELEGRAM_NOTIFY:-0}" != "1" ]; then
    return 0
  fi
  resp=$(curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode=HTML \
    -d disable_web_page_preview=true \
    --data-urlencode "text=$1" 2>/dev/null)
  # печатает message_id отправленного сообщения (для последующего удаления)
  printf '%s' "$resp" | jq -r '.result.message_id // empty' 2>/dev/null
}

# удаление ранее отправленного сообщения ($1 = message_id); тихо, без вывода
tg_delete() {
  [ -n "$1" ] || return 0
  curl -s --max-time 5 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d message_id="$1" >/dev/null 2>&1
}
