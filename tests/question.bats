#!/usr/bin/env bats
# Тесты подкоманды question (вопросы AskUserQuestion с кнопками в Telegram) против mock-сервера
# Bot API (tests/mock-telegram.py, нужен python3). Реальный ~/.claude и сеть не трогаются:
# HOME подменяется, Bot API — локальный mock. Запуск: bats tests/
# Имена @test — латиницей: bats делает из них имена shell-функций.

Q_SINGLE='[{"question":"Какой формат?","header":"Формат","multiSelect":false,"options":[{"label":"Кратко","description":"Пара строк"},{"label":"Подробно","description":"Полный разбор <b>с кодом</b> & примеры"}]}]'
Q_MULTI='[{"question":"Что включить?","header":"Разделы","multiSelect":true,"options":[{"label":"Введение","description":"Контекст"},{"label":"Код","description":"Примеры"},{"label":"Итоги","description":"Выводы"}]}]'
Q_SERIES='[{"question":"Язык?","header":"Язык","multiSelect":false,"options":[{"label":"Русский","description":"ru"},{"label":"English","description":"en"}]},{"question":"Тон?","header":"Тон","multiSelect":false,"options":[{"label":"Деловой","description":"строго"},{"label":"Дружеский","description":"мягко"}]}]'

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME/.claude/hooks"
  cp "$REPO_ROOT"/hooks/tg-notify*.sh "$HOME/.claude/hooks/"
  touch "$HOME/.claude/telegram-notify.on" "$HOME/.claude/telegram-question.on" "$HOME/.claude/telegram-permission.on"
  HOOK="$HOME/.claude/hooks/tg-notify.sh"
  # разработческая машина может ходить через прокси — mock на 127.0.0.1 идёт напрямую
  unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy ALL_PROXY
  export NO_PROXY='*' no_proxy='*'
  python3 "$REPO_ROOT/tests/mock-telegram.py" "$TEST_DIR/port" 42 3>&- &
  MOCK_PID=$!
  for _ in $(seq 1 50); do [ -s "$TEST_DIR/port" ] && break; sleep 0.1; done
  API="http://127.0.0.1:$(cat "$TEST_DIR/port")"
  export TELEGRAM_BOT_TOKEN=test TELEGRAM_CHAT_ID=42 TELEGRAM_API_BASE="$API"
  export TELEGRAM_QUESTION_POLL=0.2 TELEGRAM_QUESTION_TIMEOUT=30 TELEGRAM_TRANSLATE=0
  export CLAUDE_PROJECT_DIR=/work/demo
}

teardown() {
  kill "$MOCK_PID" 2>/dev/null || true
  pkill -f "$HOOK" 2>/dev/null || true
  rm -rf "$TEST_DIR" /tmp/claude_tg_q_t-* /tmp/claude_notif_msg_t-* /tmp/claude_notif_t-* 2>/dev/null || true
}

# ── помощники ────────────────────────────────────────────────────────────────

mock_state() { curl -s --noproxy '*' "$API/_state"; }
mock_post()  { curl -s --noproxy '*' -H 'Content-Type: application/json' -d "$2" "$API$1"; }

# ждать, пока команда $@ не вернёт 0 (до 10 с)
wait_for() { for _ in $(seq 1 100); do "$@" && return 0; sleep 0.1; done; return 1; }

# jq-выражение $1 над состоянием mock даёт значение $2 (проверяется заново на каждой попытке)
state_is() { [ "$(mock_state | jq -r "$1")" = "$2" ]; }
# в mock есть как минимум $1 сообщений
msgs_ge() { [ "$(mock_state | jq '.messages | length')" -ge "$1" ]; }
# хук сессии $1 завершился
finished() { [ -f "$TEST_DIR/done.$1" ]; }
# текст сообщения $1 содержит подстроку $2
msg_has() { mock_state | jq -e --argjson m "$1" --arg t "$2" '.messages[] | select(.message_id == $m) | .text | contains($t)' >/dev/null; }

# запустить хук question в фоне: $1 = session_id, $2 = JSON вопросов
start_question() {
  ( jq -nc --arg sid "$1" --argjson q "$2" \
      '{session_id: $sid, hook_event_name: "PermissionRequest", tool_name: "AskUserQuestion", tool_input: {questions: $q}}' \
      | sh "$HOOK" question > "$TEST_DIR/out.$1" 2> "$TEST_DIR/err.$1"
    echo done > "$TEST_DIR/done.$1" ) 3>&- &
}

# PostToolUse (подкоманда answered): $1 = sid, $2 = tool_name, $3 = tool_input (JSON), $4 = tool_response (JSON)
post_tool_use() {
  jq -nc --arg sid "$1" --arg t "$2" --argjson i "$3" --argjson r "$4" \
    '{session_id: $sid, hook_event_name: "PostToolUse", tool_name: $t, tool_input: $i, tool_response: $r}' \
    | sh "$HOOK" answered
}

# id первого сообщения бота
first_mid() { mock_state | jq -r '.messages[0].message_id'; }
# callback_data первой кнопки сообщения $1, текст которой содержит $2
btn() {
  mock_state | jq -r --argjson m "$1" --arg t "$2" \
    '.messages[] | select(.message_id == $m) | [.reply_markup.inline_keyboard[][] | select(.text | contains($t))][0].callback_data'
}
click() { mock_post /_click "$(jq -nc --argjson m "$1" --arg d "$2" '{message_id: $m, data: $d}')" >/dev/null; }
# нажать кнопку по подстроке её текста: $1 = message_id, $2 = подстрока
tap() { click "$1" "$(btn "$1" "$2")"; }
# ответ хука: поле answers для вопроса $2
answer_of() { jq -r --arg q "$2" '.hookSpecificOutput.decision.updatedInput.answers[$q]' "$TEST_DIR/out.$1"; }

# ── одиночный выбор ───────────────────────────────────────────────────────────

@test "single choice: tap returns the label and closes the message" {
  start_question t-single "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  # текст вопроса и описания экранированы (HTML), кнопки пронумерованы
  msg_has "$mid" "Какой формат?"
  msg_has "$mid" "&lt;b&gt;с кодом&lt;/b&gt; &amp; примеры"
  tap "$mid" "2. Подробно"
  wait_for finished t-single

  [ "$(jq -r '.hookSpecificOutput.hookEventName' "$TEST_DIR/out.t-single")" = "PermissionRequest" ]
  [ "$(jq -r '.hookSpecificOutput.decision.behavior' "$TEST_DIR/out.t-single")" = "allow" ]
  [ "$(answer_of t-single 'Какой формат?')" = "Подробно" ]
  # updatedInput заменяет ввод целиком — вопросы должны остаться на месте
  [ "$(jq '.hookSpecificOutput.decision.updatedInput.questions | length' "$TEST_DIR/out.t-single")" -eq 1 ]
  # сообщение прибрано: статус и ответ вместо клавиатуры
  wait_for msg_has "$mid" "Ответ отправлен"
  msg_has "$mid" "→ Подробно"
  [ "$(mock_state | jq --argjson m "$mid" '.messages[] | select(.message_id == $m) | .reply_markup.inline_keyboard | length')" -eq 0 ]
  # нажатие подтверждено в Telegram: очередь пуста, а state-файл убран
  wait_for state_is '.updates | length' 0
  [ ! -f /tmp/claude_tg_q_t-single ]
}

# ── несколько вариантов ───────────────────────────────────────────────────────

@test "multi select: toggles, then Done joins labels with comma" {
  start_question t-multi "$Q_MULTI"
  wait_for msgs_ge 1
  mid=$(first_mid)
  tap "$mid" "1. Введение"
  wait_for msg_has "$mid" "Выбрано: Введение"
  tap "$mid" "3. Итоги"
  wait_for msg_has "$mid" "Выбрано: Введение, Итоги"
  # повторное нажатие снимает отметку
  tap "$mid" "1. Введение"
  wait_for msg_has "$mid" "Выбрано: Итоги"
  tap "$mid" "2. Код"
  wait_for msg_has "$mid" "Выбрано: Код, Итоги"
  tap "$mid" "Готово"
  wait_for finished t-multi

  [ "$(answer_of t-multi 'Что включить?')" = "Код, Итоги" ]
}

@test "multi select: Done with nothing selected keeps waiting" {
  start_question t-empty "$Q_MULTI"
  wait_for msgs_ge 1
  mid=$(first_mid)
  tap "$mid" "Готово"
  wait_for state_is '[.answers[] | select(.text | contains("хотя бы один"))] | length' 1
  [ ! -f "$TEST_DIR/done.t-empty" ]
  tap "$mid" "2. Код"
  wait_for msg_has "$mid" "Выбрано: Код"
  tap "$mid" "Готово"
  wait_for finished t-empty
  [ "$(answer_of t-empty 'Что включить?')" = "Код" ]
}

# ── свой текст ────────────────────────────────────────────────────────────────

@test "custom text: Own option sends a force_reply prompt, the reply becomes the answer" {
  start_question t-text "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  tap "$mid" "Свой вариант"
  wait_for msgs_ge 2
  prompt=$(mock_state | jq -r '.messages[1].message_id')
  [ "$(mock_state | jq -r '.messages[1].reply_markup.force_reply')" = "true" ]
  mock_post /_text "$(jq -nc --argjson r "$prompt" '{text: "Таблицей, без воды", reply_to: $r}')" >/dev/null
  wait_for finished t-text
  [ "$(answer_of t-text 'Какой формат?')" = "Таблицей, без воды" ]
  # подсказка «Напишите свой вариант» убрана из чата
  wait_for state_is "[.messages[] | select(.message_id == $prompt)][0].deleted" true
}

@test "custom text: plain reply to the question message works without the button" {
  start_question t-reply "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  mock_post /_text "$(jq -nc --argjson r "$mid" '{text: "Как в прошлый раз", reply_to: $r}')" >/dev/null
  wait_for finished t-reply
  [ "$(answer_of t-reply 'Какой формат?')" = "Как в прошлый раз" ]
}

@test "custom text on multi select is appended to the ticked options" {
  start_question t-mtext "$Q_MULTI"
  wait_for msgs_ge 1
  mid=$(first_mid)
  tap "$mid" "2. Код"
  wait_for msg_has "$mid" "Выбрано: Код"
  mock_post /_text "$(jq -nc --argjson r "$mid" '{text: "ещё FAQ", reply_to: $r}')" >/dev/null
  wait_for finished t-mtext
  [ "$(answer_of t-mtext 'Что включить?')" = "Код, ещё FAQ" ]
}

# ── серия вопросов ────────────────────────────────────────────────────────────

@test "series: one message is reused, a review screen precedes sending" {
  start_question t-series "$Q_SERIES"
  wait_for msgs_ge 1
  mid=$(first_mid)
  msg_has "$mid" "1/2"
  tap "$mid" "2. English"
  wait_for msg_has "$mid" "2/2"
  msg_has "$mid" "Тон?"
  [ "$(mock_state | jq '.messages | length')" -eq 1 ]
  tap "$mid" "1. Деловой"
  # после последнего вопроса — экран проверки со сводкой; ответ ещё НЕ отправлен
  wait_for msg_has "$mid" "Проверка"
  msg_has "$mid" "→ English"
  msg_has "$mid" "→ Деловой"
  [ ! -f "$TEST_DIR/done.t-series" ]
  tap "$mid" "Отправить"
  wait_for finished t-series

  [ "$(answer_of t-series 'Язык?')" = "English" ]
  [ "$(answer_of t-series 'Тон?')" = "Деловой" ]
}

@test "series: a tap on a button of an outdated screen is rejected" {
  start_question t-old "$Q_SERIES"
  wait_for msgs_ge 1
  mid=$(first_mid)
  old=$(btn "$mid" "1. Русский")
  tap "$mid" "1. Русский"
  wait_for msg_has "$mid" "2/2"
  click "$mid" "$old"
  wait_for state_is '[.answers[] | select(.text | contains("уже обновился"))] | length' 1
  [ ! -f "$TEST_DIR/done.t-old" ]
  tap "$mid" "2. Дружеский"
  wait_for msg_has "$mid" "Проверка"
  tap "$mid" "Отправить"
  wait_for finished t-old
  [ "$(answer_of t-old 'Язык?')" = "Русский" ]
  [ "$(answer_of t-old 'Тон?')" = "Дружеский" ]
}

@test "series: Back returns to the previous question and its answer can be changed" {
  start_question t-back "$Q_SERIES"
  wait_for msgs_ge 1
  mid=$(first_mid)
  tap "$mid" "1. Русский"
  wait_for msg_has "$mid" "2/2"
  tap "$mid" "Назад"
  wait_for msg_has "$mid" "1/2"
  # прежний ответ виден и отмечен на кнопке
  msg_has "$mid" "✓ Ваш ответ: Русский"
  [ -n "$(btn "$mid" "✓ 1. Русский")" ]
  tap "$mid" "2. English"
  wait_for msg_has "$mid" "2/2"
  tap "$mid" "2. Дружеский"
  wait_for msg_has "$mid" "Проверка"
  msg_has "$mid" "→ English"
  tap "$mid" "Отправить"
  wait_for finished t-back
  [ "$(answer_of t-back 'Язык?')" = "English" ]
  [ "$(answer_of t-back 'Тон?')" = "Дружеский" ]
}

@test "series: skipped question is flagged on review and blocks sending until answered" {
  start_question t-skip "$Q_SERIES"
  wait_for msgs_ge 1
  mid=$(first_mid)
  tap "$mid" "Вперёд"
  wait_for msg_has "$mid" "2/2"
  tap "$mid" "1. Деловой"
  wait_for msg_has "$mid" "Проверка"
  msg_has "$mid" "⚠️ не отвечено"
  # кнопки «Отправить» нет, пока есть пропуск
  [ "$(btn "$mid" "Отправить")" = "null" ]
  # вернуться к первому вопросу прямо с экрана проверки
  tap "$mid" "✏️ 1"
  wait_for msg_has "$mid" "1/2"
  tap "$mid" "2. English"
  wait_for msg_has "$mid" "Проверка"
  [ "$(btn "$mid" "Отправить")" != "null" ]
  tap "$mid" "Отправить"
  wait_for finished t-skip
  [ "$(answer_of t-skip 'Язык?')" = "English" ]
  [ "$(answer_of t-skip 'Тон?')" = "Деловой" ]
}

@test "series: ticks of a multi select survive Forward and Back" {
  Q_MIX='[{"question":"Что включить?","header":"Разделы","multiSelect":true,"options":[{"label":"Введение","description":"a"},{"label":"Код","description":"b"},{"label":"Итоги","description":"c"}]},{"question":"Язык?","header":"Язык","multiSelect":false,"options":[{"label":"Русский","description":"ru"},{"label":"English","description":"en"}]}]'
  start_question t-mix "$Q_MIX"
  wait_for msgs_ge 1
  mid=$(first_mid)
  tap "$mid" "1. Введение"
  wait_for msg_has "$mid" "Выбрано: Введение"
  tap "$mid" "3. Итоги"
  wait_for msg_has "$mid" "Выбрано: Введение, Итоги"
  # «Вперёд» без «Готово»: отметки считаются подтверждёнными
  tap "$mid" "Вперёд"
  wait_for msg_has "$mid" "2/2"
  tap "$mid" "Назад"
  wait_for msg_has "$mid" "1/2"
  msg_has "$mid" "Выбрано: Введение, Итоги"
  [ -n "$(btn "$mid" "☑ 1. Введение")" ]
  tap "$mid" "2. Код"
  wait_for msg_has "$mid" "Выбрано: Введение, Код, Итоги"
  tap "$mid" "Готово"
  wait_for msg_has "$mid" "2/2"
  tap "$mid" "2. English"
  wait_for msg_has "$mid" "Проверка"
  msg_has "$mid" "→ Введение, Код, Итоги"
  tap "$mid" "Отправить"
  wait_for finished t-mix
  [ "$(answer_of t-mix 'Что включить?')" = "Введение, Код, Итоги" ]
  [ "$(answer_of t-mix 'Язык?')" = "English" ]
}

@test "series: a double tap on Forward does not jump over a question" {
  Q_THREE='[{"question":"Один?","header":"1","multiSelect":false,"options":[{"label":"a","description":"a"},{"label":"b","description":"b"}]},{"question":"Два?","header":"2","multiSelect":false,"options":[{"label":"a","description":"a"},{"label":"b","description":"b"}]},{"question":"Три?","header":"3","multiSelect":false,"options":[{"label":"a","description":"a"},{"label":"b","description":"b"}]}]'
  start_question t-dbl "$Q_THREE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  data=$(btn "$mid" "Вперёд")
  click "$mid" "$data"
  click "$mid" "$data"
  wait_for msg_has "$mid" "2/3"
  sleep 1
  msg_has "$mid" "2/3"
  wait_for state_is '[.answers[] | select(.text | contains("уже обновился"))] | length' 1
}

@test "options are separated by an empty line" {
  start_question t-gap "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  mock_state | jq -e --argjson m "$mid" '.messages[] | select(.message_id == $m) | .text | contains("\n\n2. <b>Подробно</b>")' >/dev/null
}

# ── ответили не в Telegram ────────────────────────────────────────────────────

@test "answered in terminal: PostToolUse stops the wait and the message shows the answer" {
  start_question t-term "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  [ -f /tmp/claude_tg_q_t-term ]
  post_tool_use t-term AskUserQuestion "{\"questions\":$Q_SINGLE}" '{"answers":{"Какой формат?":"Кратко"}}'
  wait_for finished t-term
  # решения нет — диалог в терминале уже закрыт самим пользователем
  [ ! -s "$TEST_DIR/out.t-term" ]
  wait_for msg_has "$mid" "Отвечено в терминале"
  msg_has "$mid" "→ Кратко"
  [ ! -f /tmp/claude_tg_q_t-term ]
}

@test "new prompt closes a pending question without a decision" {
  start_question t-prompt "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  printf '%s' '{"session_id":"t-prompt","hook_event_name":"UserPromptSubmit"}' | sh "$HOOK" prompt
  wait_for finished t-prompt
  [ ! -s "$TEST_DIR/out.t-prompt" ]
  wait_for msg_has "$mid" "Вопрос закрыт"
}

@test "Stop closes a pending question (Chat about this in terminal)" {
  start_question t-stop "$Q_SINGLE"
  wait_for msgs_ge 1
  printf '%s' '{"session_id":"t-stop","hook_event_name":"Stop"}' | sh "$HOOK" stop
  wait_for finished t-stop
  [ ! -s "$TEST_DIR/out.t-stop" ]
}

@test "timeout: message is closed, no decision, dialog stays in terminal" {
  export TELEGRAM_QUESTION_TIMEOUT=2
  start_question t-timeout "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  wait_for finished t-timeout
  [ ! -s "$TEST_DIR/out.t-timeout" ]
  wait_for msg_has "$mid" "Время ожидания вышло"
}

# ── выключатели и сбои ────────────────────────────────────────────────────────

@test "disabled: without telegram-question.on nothing is sent and nothing printed" {
  rm "$HOME/.claude/telegram-question.on"
  start_question t-off "$Q_SINGLE"
  wait_for finished t-off
  [ ! -s "$TEST_DIR/out.t-off" ]
  [ "$(mock_state | jq '.messages | length')" -eq 0 ]
}

@test "disabled: notifications switched off silences questions too" {
  rm "$HOME/.claude/telegram-notify.on"
  start_question t-off2 "$Q_SINGLE"
  wait_for finished t-off2
  [ ! -s "$TEST_DIR/out.t-off2" ]
  [ "$(mock_state | jq '.messages | length')" -eq 0 ]
}

@test "telegram unreachable at send: exits silently, terminal dialog untouched" {
  export TELEGRAM_API_BASE="http://127.0.0.1:1"
  start_question t-down "$Q_SINGLE"
  wait_for finished t-down
  [ ! -s "$TEST_DIR/out.t-down" ]
  [ ! -f /tmp/claude_tg_q_t-down ]
}

@test "getUpdates conflict (409) is survived and answers still arrive" {
  mock_post /_conflict '{"on": true}' >/dev/null
  start_question t-409 "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  sleep 1
  [ ! -f "$TEST_DIR/done.t-409" ]
  mock_post /_conflict '{"on": false}' >/dev/null
  tap "$mid" "1. Кратко"
  wait_for finished t-409
  [ "$(answer_of t-409 'Какой формат?')" = "Кратко" ]
}

# ── соседи: чужие нажатия и дубли уведомлений ─────────────────────────────────

@test "foreign callbacks are ignored and left unconfirmed for their owner" {
  start_question t-own "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  # нажатие на кнопку чужого (живого) вопроса: другой rid, свежее сообщение
  now=$(date +%s)
  mock_post /_raw_update "$(jq -nc --argjson d "$now" --argjson m "$mid" \
    '{callback_query: {id: "foreign1", from: {id: 42}, message: {message_id: 999, chat: {id: 42}, date: $d}, data: "qdeadbeef:0:o0"}}')" >/dev/null
  sleep 1
  [ ! -f "$TEST_DIR/done.t-own" ]
  tap "$mid" "1. Кратко"
  wait_for finished t-own
  [ "$(answer_of t-own 'Какой формат?')" = "Кратко" ]
  # чужое нажатие осталось в очереди — его хозяин ещё может его забрать
  [ "$(mock_state | jq '[.updates[] | select(.callback_query.id == "foreign1")] | length')" -eq 1 ]
  # и на него не было ответа от нашего хука
  [ "$(mock_state | jq '[.answers[] | select(.id == "foreign1")] | length')" -eq 0 ]
}

@test "stale callbacks of long-dead questions are answered and their keyboard stripped" {
  # сообщение с клавиатурой от «умершего» вопроса
  curl -s --noproxy '*' "$API/bottest/sendMessage" -d chat_id=42 --data-urlencode 'text=старый вопрос' \
    --data-urlencode 'reply_markup={"inline_keyboard":[[{"text":"x","callback_data":"qdeadbeef:0:o0"}]]}' >/dev/null
  mock_post /_raw_update "$(jq -nc \
    '{callback_query: {id: "stale1", from: {id: 42}, message: {message_id: 101, chat: {id: 42}, date: 1000}, data: "qdeadbeef:0:o0"}}')" >/dev/null
  start_question t-stale "$Q_SINGLE"
  wait_for state_is '[.answers[] | select(.id == "stale1")] | length' 1
  [ "$(mock_state | jq -r '.answers[] | select(.id == "stale1") | .text')" = "Этот запрос уже закрыт" ]
  [ "$(mock_state | jq '.messages[] | select(.message_id == 101) | .reply_markup.inline_keyboard | length')" -eq 0 ]
}

@test "two sessions at once: answers do not cross" {
  start_question t-a "$Q_SINGLE"
  start_question t-b "$Q_MULTI"
  wait_for msgs_ge 2
  mid_a=$(mock_state | jq -r '.messages[] | select(.text | contains("Какой формат?")) | .message_id')
  mid_b=$(mock_state | jq -r '.messages[] | select(.text | contains("Что включить?")) | .message_id')
  tap "$mid_b" "3. Итоги"
  tap "$mid_b" "Готово"
  wait_for finished t-b
  [ ! -f "$TEST_DIR/done.t-a" ]
  tap "$mid_a" "2. Подробно"
  wait_for finished t-a
  [ "$(answer_of t-a 'Какой формат?')" = "Подробно" ]
  [ "$(answer_of t-b 'Что включить?')" = "Итоги" ]
}

@test "Notification permission_prompt is suppressed while a question is pending" {
  start_question t-dup "$Q_SINGLE"
  wait_for msgs_ge 1
  printf '%s' '{"session_id":"t-dup","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission"}' \
    | sh "$HOOK" ask
  [ "$(mock_state | jq '.messages | length')" -eq 1 ]
  # без вопроса уведомление уходит как обычно
  printf '%s' '{"session_id":"t-other","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission"}' \
    | sh "$HOOK" ask
  [ "$(mock_state | jq '.messages | length')" -eq 2 ]
}

@test "question message is registered for cleanup by the next terminal action" {
  start_question t-reg "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  tap "$mid" "1. Кратко"
  wait_for finished t-reg
  wait_for grep -qx "$mid" /tmp/claude_notif_msg_t-reg
  # следующий PreToolUse (permit) убирает сообщение из чата
  printf '%s' '{"session_id":"t-reg","hook_event_name":"PreToolUse","tool_name":"Bash"}' | sh "$HOOK" permit
  [ "$(mock_state | jq --argjson m "$mid" '.messages[] | select(.message_id == $m) | .deleted')" = "true" ]
}

@test "taps and texts from a foreign chat are ignored" {
  start_question t-chat "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  data=$(btn "$mid" "1. Кратко")
  now=$(date +%s)
  # то же callback_data, но нажато в чужом чате — должно быть отброшено
  mock_post /_raw_update "$(jq -nc --argjson d "$now" --arg data "$data" \
    '{callback_query: {id: "evil1", from: {id: 777}, message: {message_id: 5, chat: {id: 777}, date: $d}, data: $data}}')" >/dev/null
  mock_post /_raw_update "$(jq -nc --argjson d "$now" --argjson r "$mid" \
    '{message: {message_id: 6, from: {id: 777}, chat: {id: 777}, date: $d, text: "взлом", reply_to_message: {message_id: $r, date: $d, chat: {id: 777}}}}')" >/dev/null
  sleep 1
  [ ! -f "$TEST_DIR/done.t-chat" ]
  tap "$mid" "2. Подробно"
  wait_for finished t-chat
  [ "$(answer_of t-chat 'Какой формат?')" = "Подробно" ]
}

@test "ask is not suppressed by a leftover state file of a dead hook" {
  printf 'pending 999999 deadbeef\n' > /tmp/claude_tg_q_t-ghost
  printf '%s' '{"session_id":"t-ghost","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission"}' \
    | sh "$HOOK" ask
  [ "$(mock_state | jq '.messages | length')" -eq 1 ]
}

@test "stop still sends the completion notice with the session title" {
  printf '%s\n' '{"type":"ai-title","aiTitle":"Refactoring auth module"}' > "$TEST_DIR/transcript.jsonl"
  echo $(( $(date +%s) - 600 )) > /tmp/claude_notif_t-done
  jq -nc --arg tp "$TEST_DIR/transcript.jsonl" '{session_id: "t-done", transcript_path: $tp}' \
    | TELEGRAM_MIN_SECONDS=60 sh "$HOOK" stop
  [ "$(mock_state | jq '.messages | length')" -eq 1 ]
  msg_has "$(first_mid)" "Завершено"
  msg_has "$(first_mid)" "Refactoring auth module"
  # новый формат шапки: машина отдельной строкой, без полосы сверху
  mock_state | jq -e '.messages[0].text | (contains("📁 demo\n💻 ") and (contains("━") | not))' >/dev/null
  rm -f /tmp/claude_notif_t-done
}

@test "header shows the thread title above the folder, and no duplicate line without a title" {
  # названия нет (свежая сессия): строка 📋 не нужна — папка и так в строке 📁
  start_question t-notitle "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  ! mock_state | jq -e --argjson m "$mid" '.messages[] | select(.message_id == $m) | .text | contains("📋")' >/dev/null
  msg_has "$mid" "📁 demo"
  # машина — отдельной строкой под папкой; верхней полосы в сообщении нет
  mock_state | jq -e --argjson m "$mid" \
    '.messages[] | select(.message_id == $m) | .text | (contains("📁 demo\n💻 ") and (contains("━") | not))' >/dev/null
  tap "$mid" "1. Кратко"
  wait_for finished t-notitle
  # название есть (ai-title из транскрипта): оно выводится отдельной строкой над папкой
  printf '%s\n' '{"type":"ai-title","aiTitle":"Выбор вариантов из Telegram"}' > "$TEST_DIR/tr.jsonl"
  ( jq -nc --arg tp "$TEST_DIR/tr.jsonl" --argjson q "$Q_SINGLE" \
      '{session_id: "t-title", transcript_path: $tp, tool_input: {questions: $q}}' \
      | sh "$HOOK" question > "$TEST_DIR/out.t-title" 2>/dev/null
    echo done > "$TEST_DIR/done.t-title" ) 3>&- &
  wait_for msgs_ge 2
  mid2=$(mock_state | jq -r '.messages[-1].message_id')
  msg_has "$mid2" "📋 <b>Выбор вариантов из Telegram</b>"
  msg_has "$mid2" "📁 demo"
}

@test "TELEGRAM_CURL_OPTS is applied to Bot API calls (bypass a broken proxy)" {
  # прокси из окружения мёртв: без опции вопрос до mock не доходит, хук выходит молча
  export NO_PROXY="" no_proxy=""
  export http_proxy="http://127.0.0.1:1" HTTP_PROXY="http://127.0.0.1:1"
  start_question t-noopt "$Q_SINGLE"
  wait_for finished t-noopt
  [ ! -s "$TEST_DIR/out.t-noopt" ]
  [ "$(mock_state | jq '.messages | length')" -eq 0 ]
  # с опцией --noproxy вопрос доходит и отвечается
  export TELEGRAM_CURL_OPTS="--noproxy 127.0.0.1"
  start_question t-opt "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  tap "$mid" "1. Кратко"
  wait_for finished t-opt
  [ "$(answer_of t-opt 'Какой формат?')" = "Кратко" ]
}

@test "Stop right after the terminal answer does not erase the answer from the chat" {
  # Stop приходит через секунды после PostToolUse, а ждущий хук проверяет файл реже —
  # состояние «done» Stop стирать не должен, пока хук жив
  start_question t-race "$Q_SINGLE"
  wait_for msgs_ge 1
  mid=$(first_mid)
  post_tool_use t-race AskUserQuestion "{\"questions\":$Q_SINGLE}" '{"answers":{"Какой формат?":"Кратко"}}'
  printf '%s' '{"session_id":"t-race","hook_event_name":"Stop"}' | sh "$HOOK" stop
  wait_for finished t-race
  wait_for msg_has "$mid" "Отвечено в терминале"
  msg_has "$mid" "→ Кратко"
}

# ── разрешения на инструменты кнопками (подкоманда permission) ───────────────────────────────

PERM_BASH='{"tool_name":"Bash","tool_input":{"command":"rm -rf <build> && echo \"done\" & ls","description":"Clean build"}}'

# запустить хук permission в фоне: $1 = session_id, $2 = JSON {tool_name, tool_input}
start_perm() {
  ( jq -nc --arg sid "$1" --argjson t "$2" '{session_id: $sid, hook_event_name: "PermissionRequest"} + $t' \
      | sh "$HOOK" permission > "$TEST_DIR/out.$1" 2> "$TEST_DIR/err.$1"
    echo done > "$TEST_DIR/done.$1" ) 3>&- &
}
# поле decision из вывода хука
perm_of() { jq -r ".hookSpecificOutput.decision.$2" "$TEST_DIR/out.$1"; }

@test "permission: Allow returns allow; the message shows the tool and the escaped command" {
  start_perm t-allow "$PERM_BASH"
  wait_for msgs_ge 1
  mid=$(first_mid)
  msg_has "$mid" "Нужно разрешение"
  msg_has "$mid" "<b>Bash</b>"
  msg_has "$mid" "rm -rf &lt;build&gt; &amp;&amp; echo"
  msg_has "$mid" "Clean build"
  mock_state | jq -e --argjson m "$mid" '.messages[] | select(.message_id == $m) | .text | contains("━") | not' >/dev/null
  tap "$mid" "Разрешить"
  wait_for finished t-allow
  [ "$(jq -r '.hookSpecificOutput.hookEventName' "$TEST_DIR/out.t-allow")" = "PermissionRequest" ]
  [ "$(perm_of t-allow behavior)" = "allow" ]
  wait_for msg_has "$mid" "Разрешено"
  [ "$(mock_state | jq --argjson m "$mid" '.messages[] | select(.message_id == $m) | .reply_markup.inline_keyboard | length')" -eq 0 ]
}

@test "permission: Deny returns deny with a message for Claude" {
  start_perm t-deny "$PERM_BASH"
  wait_for msgs_ge 1
  mid=$(first_mid)
  tap "$mid" "❌ Отклонить"
  wait_for finished t-deny
  [ "$(perm_of t-deny behavior)" = "deny" ]
  [[ "$(perm_of t-deny message)" == *"denied"* ]]
  wait_for msg_has "$mid" "Отклонено"
}

@test "permission: Deny with a reason passes the typed text to Claude" {
  start_perm t-why "$PERM_BASH"
  wait_for msgs_ge 1
  mid=$(first_mid)
  tap "$mid" "с причиной"
  wait_for msgs_ge 2
  prompt=$(mock_state | jq -r '.messages[1].message_id')
  [ "$(mock_state | jq -r '.messages[1].reply_markup.force_reply')" = "true" ]
  mock_post /_text "$(jq -nc --argjson r "$prompt" '{text: "Сначала сделай бэкап", reply_to: $r}')" >/dev/null
  wait_for finished t-why
  [ "$(perm_of t-why behavior)" = "deny" ]
  [[ "$(perm_of t-why message)" == *"Сначала сделай бэкап"* ]]
  wait_for msg_has "$mid" "Сначала сделай бэкап"
}

@test "permission: a plain reply to the request is NOT taken as an answer" {
  start_perm t-reply "$PERM_BASH"
  wait_for msgs_ge 1
  mid=$(first_mid)
  # «ок» ответом на сообщение не должно ни разрешать, ни отклонять
  mock_post /_text "$(jq -nc --argjson r "$mid" '{text: "ок", reply_to: $r}')" >/dev/null
  sleep 1.2
  [ ! -f "$TEST_DIR/done.t-reply" ]
  tap "$mid" "Разрешить"
  wait_for finished t-reply
  [ "$(perm_of t-reply behavior)" = "allow" ]
}

@test "permission: AskUserQuestion and plan approval are left to their own flows" {
  start_perm t-skipq '{"tool_name":"AskUserQuestion","tool_input":{"questions":[]}}'
  wait_for finished t-skipq
  [ ! -s "$TEST_DIR/out.t-skipq" ]
  start_perm t-skipp '{"tool_name":"ExitPlanMode","tool_input":{"plan":"x"}}'
  wait_for finished t-skipp
  [ ! -s "$TEST_DIR/out.t-skipp" ]
  [ "$(mock_state | jq '.messages | length')" -eq 0 ]
}

@test "permission: disabled by default (no flag) — silent, dialog untouched" {
  rm "$HOME/.claude/telegram-permission.on"
  start_perm t-poff "$PERM_BASH"
  wait_for finished t-poff
  [ ! -s "$TEST_DIR/out.t-poff" ]
  [ "$(mock_state | jq '.messages | length')" -eq 0 ]
}

@test "permission: timeout gives no decision — never allows by default" {
  export TELEGRAM_QUESTION_TIMEOUT=2
  start_perm t-ptime "$PERM_BASH"
  wait_for msgs_ge 1
  mid=$(first_mid)
  wait_for finished t-ptime
  [ ! -s "$TEST_DIR/out.t-ptime" ]
  wait_for msg_has "$mid" "Время ожидания вышло"
}

@test "permission: PostToolUse of the same call closes it; another tool's PostToolUse does not" {
  start_perm t-fp "$PERM_BASH"
  wait_for msgs_ge 1
  mid=$(first_mid)
  # параллельный вызов другого инструмента — ожидающее разрешение трогать нельзя
  post_tool_use t-fp Read '{"file_path":"/etc/hosts"}' '{}'
  sleep 1.2
  [ ! -f "$TEST_DIR/done.t-fp" ]
  # тот же вызов (ключи в другом порядке) — решено в терминале
  post_tool_use t-fp Bash '{"description":"Clean build","command":"rm -rf <build> && echo \"done\" & ls"}' '{}'
  wait_for finished t-fp
  [ ! -s "$TEST_DIR/out.t-fp" ]
  wait_for msg_has "$mid" "Решено в терминале"
}

@test "permission: the generic Notification is suppressed while the request is pending" {
  start_perm t-pdup "$PERM_BASH"
  wait_for msgs_ge 1
  printf '%s' '{"session_id":"t-pdup","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission"}' \
    | sh "$HOOK" ask
  [ "$(mock_state | jq '.messages | length')" -eq 1 ]
}

@test "ask notification uses the new header: no strip, machine on its own line" {
  printf '%s' '{"session_id":"t-ask","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission"}' \
    | sh "$HOOK" ask
  mid=$(first_mid)
  msg_has "$mid" "Нужно разрешение"
  mock_state | jq -e '.messages[0].text | (contains("📁 demo\n💻 ") and (contains("━") | not))' >/dev/null
}
