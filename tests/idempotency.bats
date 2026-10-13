#!/usr/bin/env bats
# Тесты идемпотентности установщика. Гоняют install.sh в изолированном CLAUDE_DIR
# (реальный ~/.claude не трогается, /tmp/claude_notif_* не очищается — uninstall тут
# не запускается намеренно). Запуск: bats tests/
# Имена @test — латиницей: bats делает из них имена shell-функций.

setup() {
  TEST_DIR="$(mktemp -d)"
  export CLAUDE_DIR="$TEST_DIR"
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # settings.json с ПОСТОРОННИМ хуком — он должен уцелеть
  printf '%s' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh /other/thing.sh"}]}]}}' > "$TEST_DIR/settings.json"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "double install does not duplicate hook registrations" {
  WITH_DEBUG=1 sh "$REPO_ROOT/install.sh"
  WITH_DEBUG=1 sh "$REPO_ROOT/install.sh"
  # с 2026-10-10 регистрация — один скрипт плюс подкоманда
  for sub in prompt stop ask permit end question answered; do
    n=$(jq --arg s "tg-notify.sh\" $sub" '[.hooks[]?[]?.hooks[]?|select((.command//"")|contains($s))]|length' "$TEST_DIR/settings.json")
    [ "$n" -eq 1 ]
  done
}

@test "question hooks are bound to AskUserQuestion only" {
  sh "$REPO_ROOT/install.sh"
  # PermissionRequest: ответ из Telegram; PostToolUse: сигнал «отвечено», чтобы прибрать чат
  m=$(jq -r '[.hooks.PermissionRequest[]? | select(.hooks[0].command | contains("tg-notify.sh\" question")) | .matcher] | first' "$TEST_DIR/settings.json")
  [ "$m" = "AskUserQuestion" ]
  m=$(jq -r '[.hooks.PostToolUse[]? | select(.hooks[0].command | contains("tg-notify.sh\" answered")) | .matcher] | first' "$TEST_DIR/settings.json")
  [ "$m" = "AskUserQuestion" ]
  # таймаут хука больше внутреннего (3300 с): сообщение успевает закрыться само
  t=$(jq -r '[.hooks.PermissionRequest[]?.hooks[]? | select(.command | contains("question")) | .timeout] | first' "$TEST_DIR/settings.json")
  [ "$t" -gt 3300 ]
}

@test "question flag is created, and ENABLE_QUESTIONS=0 skips it" {
  sh "$REPO_ROOT/install.sh"
  [ -f "$TEST_DIR/telegram-question.on" ]
  rm -f "$TEST_DIR/telegram-question.on"
  ENABLE_QUESTIONS=0 sh "$REPO_ROOT/install.sh"
  [ ! -f "$TEST_DIR/telegram-question.on" ]
}

@test "hooks registered by hand through HOME are recognised, not duplicated" {
  # ручная установка по settings.hooks.json пишет $HOME, установщик — абсолютный путь
  export HOME="$TEST_DIR/h"
  export CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$CLAUDE_DIR"
  printf '%s' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh \"$HOME/.claude/hooks/tg-notify.sh\" stop"}]}],"PermissionRequest":[{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"sh \"$HOME/.claude/hooks/tg-notify.sh\" question","timeout":3600}]}]}}' > "$CLAUDE_DIR/settings.json"
  sh "$REPO_ROOT/install.sh"
  sh "$REPO_ROOT/install.sh"
  n=$(jq '[.hooks.Stop[]?.hooks[]? | select((.command // "") | contains("tg-notify.sh\" stop"))] | length' "$CLAUDE_DIR/settings.json")
  [ "$n" -eq 1 ]
  n=$(jq '[.hooks.PermissionRequest[]?.hooks[]? | select((.command // "") | contains("tg-notify.sh\" question"))] | length' "$CLAUDE_DIR/settings.json")
  [ "$n" -eq 1 ]
  # недостающие записи при этом добавлены
  n=$(jq '[.hooks.UserPromptSubmit[]?.hooks[]? | select((.command // "") | contains("tg-notify.sh\" prompt"))] | length' "$CLAUDE_DIR/settings.json")
  [ "$n" -eq 1 ]
}

@test "foreign hook in settings.json is preserved" {
  WITH_DEBUG=1 sh "$REPO_ROOT/install.sh"
  n=$(jq '[.hooks.Stop[]?.hooks[]?|select((.command//"")|contains("other/thing"))]|length' "$TEST_DIR/settings.json")
  [ "$n" -eq 1 ]
}

@test "env file is created" {
  WITH_DEBUG=1 sh "$REPO_ROOT/install.sh"
  [ -f "$TEST_DIR/telegram-notify.env" ]
}

@test "both hook files are installed (lib + single script)" {
  WITH_DEBUG=1 sh "$REPO_ROOT/install.sh"
  [ -f "$TEST_DIR/hooks/tg-notify-lib.sh" ]
  [ -f "$TEST_DIR/hooks/tg-notify.sh" ]
  # старых файлов быть не должно
  for old in start stop notification permit end debug; do
    [ ! -f "$TEST_DIR/hooks/tg-notify-$old.sh" ]
  done
}

@test "debug hook is registered with its subcommand" {
  WITH_DEBUG=1 sh "$REPO_ROOT/install.sh"
  n=$(jq '[.hooks.PreCompact[]?.hooks[]?|select((.command//"")|contains("tg-notify.sh\" debug"))]|length' "$TEST_DIR/settings.json")
  [ "$n" -eq 1 ]
}

@test "custom CLAUDE_DIR is substituted into hooks" {
  WITH_DEBUG=1 sh "$REPO_ROOT/install.sh"
  grep -q "$TEST_DIR/telegram-notify.env" "$TEST_DIR/hooks/tg-notify-lib.sh"
  grep -q "$TEST_DIR" "$TEST_DIR/hooks/tg-notify.sh"
}
