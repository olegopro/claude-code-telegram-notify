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
  for sub in prompt stop ask permit end; do
    n=$(jq --arg s "tg-notify.sh\" $sub" '[.hooks[]?[]?.hooks[]?|select((.command//"")|contains($s))]|length' "$TEST_DIR/settings.json")
    [ "$n" -eq 1 ]
  done
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
