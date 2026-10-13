#!/bin/sh
# Установщик Telegram-уведомлений для Claude Code.
# Можно запускать двумя способами:
#   • локально из клона:   ./install.sh   (для приватного репозитория — единственный способ)
#   • одной командой:      curl -fsSL https://raw.githubusercontent.com/olegopro/claude-code-telegram-notify/main/install.sh | sh
#                          (работает, только пока репозиторий публичен: raw у приватного отдаёт 404)
#
# Идемпотентен: повторный запуск не плодит дубли. Перед правкой делает бэкап
# settings.json. Секреты НЕ хранятся в репозитории — кладутся в отдельный
# ~/.claude/telegram-notify.env (или передаются через окружение при установке).
#
# Опции (через окружение):
#   WITH_DEBUG=1   — поставить и отладочный хук (PreCompact + SessionStart)
#   ENABLE=0       — не включать уведомления (не создавать флаг telegram-notify.on)
#   ENABLE_QUESTIONS=0 — не включать вопросы с кнопками (не создавать telegram-question.on)
#   ENABLE_PERMISSIONS=1 — включить кнопки «Разрешить/Отклонить» (telegram-permission.on);
#                  по умолчанию ВЫКЛЮЧЕНО: решать за Claude из Telegram сможет любой, у кого
#                  есть доступ к чату с ботом
#   REF=v1.0.0     — поставить из тега/ветки (по умолчанию main)
#   CLAUDE_DIR=... — каталог Claude Code (по умолчанию $CLAUDE_CONFIG_DIR или ~/.claude)
set -e

REPO="olegopro/claude-code-telegram-notify"
REF="${REF:-${BRANCH:-main}}"
RAW="https://raw.githubusercontent.com/$REPO/$REF"
CLAUDE_DIR="${CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
ENV_FILE="$CLAUDE_DIR/telegram-notify.env"

# С 2026-10-10 ставится ОДИН скрипт (было семь: start/stop/notification/permit/end/debug
# + lib) — ветвление по подкоманде. Старые имена файлов при обновлении просто перестают
# использоваться; их регистрации в settings.json убирает uninstall.sh (якорь знает оба вида).
HOOKS="tg-notify-lib.sh tg-notify.sh"

say()  { printf '  %s\n' "$1"; }
die()  { printf 'ОШИБКА: %s\n' "$1" >&2; exit 1; }

echo "▶ Установка Telegram-уведомлений для Claude Code"

# 0. зависимости
for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || die "нужен '$dep' (на macOS: brew install $dep)"
done

# 1. каталоги
mkdir -p "$HOOKS_DIR"

# 2. источник хуков: локальная папка рядом со скриптом ИЛИ скачивание с raw
SRC=""
if [ -n "${BASH_SOURCE:-}" ]; then self="${BASH_SOURCE}"; else self="$0"; fi
case "$self" in
  */*) cand=$(cd "$(dirname "$self")" 2>/dev/null && pwd)/hooks ;;
  *)   cand="" ;;
esac
[ -n "$cand" ] && [ -d "$cand" ] && SRC="$cand"

if [ -n "$SRC" ]; then
  say "источник: локальная папка $SRC"
  for h in $HOOKS; do cp "$SRC/$h" "$HOOKS_DIR/$h"; done
else
  say "источник: $RAW/hooks"
  for h in $HOOKS; do
    curl -fsSL "$RAW/hooks/$h" -o "$HOOKS_DIR/$h" || die "не скачать $h"
  done
fi
chmod +x "$HOOKS_DIR"/tg-notify-*.sh
say "хуки установлены в $HOOKS_DIR"

# при нестандартном каталоге подставить его в хуки (по умолчанию они ссылаются на
# $HOME/.claude для библиотеки/секретов/флагов — иначе чтение шло бы не оттуда)
if [ "$CLAUDE_DIR" != "$HOME/.claude" ]; then
  for h in $HOOKS; do
    sed "s|\$HOME/.claude|$CLAUDE_DIR|g" "$HOOKS_DIR/$h" > "$HOOKS_DIR/$h.tmp" \
      && mv "$HOOKS_DIR/$h.tmp" "$HOOKS_DIR/$h"
  done
  chmod +x "$HOOKS_DIR"/tg-notify-*.sh
  say "хуки настроены на каталог $CLAUDE_DIR"
fi

# 3. секреты → ~/.claude/telegram-notify.env (не коммитится)
if [ ! -f "$ENV_FILE" ]; then
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' \
      "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID" > "$ENV_FILE"
    say "секреты записаны в $ENV_FILE (из окружения)"
  else
    cat > "$ENV_FILE" <<'EOF'
# Секреты Telegram-бота. Этот файл НЕ коммитится в репозиторий.
# Токен — от @BotFather; chat_id — из getUpdates (см. README).
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
# Порог уведомления в секундах (опц., по умолчанию 180 = 3 мин):
# TELEGRAM_MIN_SECONDS=180
EOF
    say "создан шаблон $ENV_FILE — впишите TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID"
  fi
  chmod 600 "$ENV_FILE"
else
  say "env-файл уже есть: $ENV_FILE (оставлен без изменений)"
fi

# 4. регистрация хуков в settings.json (идемпотентно, с бэкапом)
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS — невалидный JSON, поправьте вручную"
cp "$SETTINGS" "$SETTINGS.bak"

DEBUG_FILTER=""
if [ "${WITH_DEBUG:-0}" = "1" ]; then
  DEBUG_FILTER='
    | ensure("PreCompact";   {matcher:"", hooks:[{type:"command", command:hookcmd("debug")}]})
    | ensure("SessionStart"; {matcher:"", hooks:[{type:"command", command:hookcmd("debug")}]})'
fi

tmp=$(mktemp)
jq --arg H "$HOOKS_DIR" --arg HOME_DIR "$HOME" '
  # команда вызова: sh "<каталог хуков>/tg-notify.sh" <подкоманда>
  def hookcmd($sub): "sh \"" + $H + "/tg-notify.sh\" " + $sub;
  # $HOME в команде и тот же путь абсолютным — одна и та же запись: ручная установка по
  # settings.hooks.json пишет $HOME, установщик — абсолютный путь (иначе хуки задвоились бы)
  def norm: gsub("\\$HOME"; $HOME_DIR) | gsub("\\$\\{HOME\\}"; $HOME_DIR);
  # заменить запись с тем же command на $entry (так обновляется matcher у уже стоящей записи)
  def replace($e; $entry):
    .hooks = (.hooks // {})
    | .hooks[$e] = ((.hooks[$e] // [])
        | map(.hooks |= map(select(((.command // "") | norm) != ($entry.hooks[0].command | norm))))
        | map(select((.hooks | length) > 0)))
    | .hooks[$e] += [$entry];
  # добавить $entry в .hooks[$e], если такого command там ещё нет
  def ensure($e; $entry):
    .hooks = (.hooks // {})
    | .hooks[$e] = (.hooks[$e] // [])
    | if any(.hooks[$e][]?.hooks[]?; ((.command // "") | norm) == ($entry.hooks[0].command | norm))
      then .
      else .hooks[$e] += [$entry]
      end;
  ensure("UserPromptSubmit"; {matcher:"", hooks:[{type:"command", command:hookcmd("prompt")}]})
  | ensure("Stop";          {hooks:[{type:"command", command:hookcmd("stop")}]})
  | ensure("Notification";  {matcher:"permission_prompt", hooks:[{type:"command", command:hookcmd("ask")}]})
  | ensure("PreToolUse";    {matcher:"", hooks:[{type:"command", command:hookcmd("permit")}]})
  | ensure("SessionEnd";    {hooks:[{type:"command", command:hookcmd("end")}]})
  | ensure("PermissionRequest"; {matcher:"AskUserQuestion", hooks:[{type:"command", command:hookcmd("question"), timeout:3600}]})
  | ensure("PermissionRequest"; {matcher:"", hooks:[{type:"command", command:hookcmd("permission"), timeout:3600}]})
  | replace("PostToolUse";  {matcher:"", hooks:[{type:"command", command:hookcmd("answered")}]})
  '"$DEBUG_FILTER"'
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
say "хуки прописаны в $SETTINGS (бэкап: $SETTINGS.bak)"

# 5. включатель
if [ "${ENABLE:-1}" = "1" ]; then
  touch "$CLAUDE_DIR/telegram-notify.on"
  say "уведомления включены (флаг telegram-notify.on)"
else
  say "уведомления НЕ включены (ENABLE=0). Включить: touch $CLAUDE_DIR/telegram-notify.on"
fi

# 6. вопросы с кнопками (AskUserQuestion → Telegram); работают только при включённых уведомлениях
if [ "${ENABLE_QUESTIONS:-1}" = "1" ]; then
  touch "$CLAUDE_DIR/telegram-question.on"
  say "вопросы с кнопками включены (флаг telegram-question.on)"
else
  say "вопросы с кнопками НЕ включены (ENABLE_QUESTIONS=0). Включить: touch $CLAUDE_DIR/telegram-question.on"
fi

# 7. кнопки разрешений: ВЫКЛЮЧЕНЫ по умолчанию (меняют, кто может одобрять инструменты)
if [ "${ENABLE_PERMISSIONS:-0}" = "1" ]; then
  touch "$CLAUDE_DIR/telegram-permission.on"
  say "кнопки «Разрешить/Отклонить» включены (флаг telegram-permission.on)"
else
  say "кнопки «Разрешить/Отклонить» НЕ включены; включить: touch $CLAUDE_DIR/telegram-permission.on"
fi

echo
echo "✓ Готово."
echo "  1) Впишите токен и chat_id в:  $ENV_FILE"
echo "  2) Перезапустите сессию Claude Code (или откройте новую)."
echo "  3) Проверка отправки:  sh -c '. \"$HOOKS_DIR/tg-notify-lib.sh\"; id=\$(tg_send \"🧪 тест\"); echo mid=\$id; tg_delete \"\$id\"'"
