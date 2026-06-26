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
  for h in start stop notification permit end; do
    n=$(jq --arg h "tg-notify-$h.sh" '[.hooks[]?[]?.hooks[]?|select((.command//"")|contains($h))]|length' "$TEST_DIR/settings.json")
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

@test "all seven hook files are installed" {
  WITH_DEBUG=1 sh "$REPO_ROOT/install.sh"
  for h in lib start stop notification permit end debug; do
    [ -f "$TEST_DIR/hooks/tg-notify-$h.sh" ]
  done
}

@test "custom CLAUDE_DIR is substituted into hooks" {
  WITH_DEBUG=1 sh "$REPO_ROOT/install.sh"
  grep -q "$TEST_DIR/telegram-notify.env" "$TEST_DIR/hooks/tg-notify-lib.sh"
}
