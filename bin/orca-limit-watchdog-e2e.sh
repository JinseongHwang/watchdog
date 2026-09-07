#!/usr/bin/env bash
# orca-limit-watchdog-e2e.sh — 워치독의 종단 동작을 실제 Claude 세션으로 검증한다.
#
# 진짜 5시간 한도는 원할 때 만들 수 없다. 그래서 진짜 Claude Code 세션을 하나 띄우고
# 그 화면에 한도 배너 문구가 나타나게 만든 뒤, 워치독이 그 화면을 읽어 재개 프롬프트를
# 실제로 주입하는지 확인한다. 워치독이 지나는 경로는 실제 상황과 완전히 같고,
# 화면의 배너를 누가 그렸는지만 다르다.

set -uo pipefail
WD_HOME="${WATCHDOG_HOME:-$HOME/watchdog}"
WD="$WD_HOME/bin/orca-limit-watchdog.py"
ORCA="${ORCA_BIN:-/usr/local/bin/orca}"
WORKTREE="${1:-path:$HOME/blog}"
BANNER="Usage limit reached"
HANDLE=""
FAILED=0

cleanup() { [ -n "$HANDLE" ] && "$ORCA" terminal close --terminal "$HANDLE" --tab >/dev/null 2>&1; }
trap cleanup EXIT

screen_of() {
  "$ORCA" terminal read --terminal "$1" --screen --json 2>/dev/null | python3 -c '
import sys,json
try: t=json.load(sys.stdin)["result"]["terminal"]
except Exception: sys.exit(0)
tail=t.get("tail")
print(tail if isinstance(tail,str) else "\n".join(map(str,tail or [])))'
}

send_and_enter() {
  "$ORCA" terminal send --terminal "$1" --text "$2" >/dev/null 2>&1
  sleep 1
  "$ORCA" terminal send --terminal "$1" --enter >/dev/null 2>&1
}

wait_for() {  # wait_for <handle> <문자열> <최대초>
  local h="$1" needle="$2" limit="$3" waited=0
  while [ "$waited" -lt "$limit" ]; do
    sleep 3; waited=$((waited+3))
    screen_of "$h" | grep -qF "$needle" && return 0
  done
  return 1
}

fail() { echo "FAIL: $*"; FAILED=1; }

echo "1) 테스트용 Claude 세션을 띄웁니다"
HANDLE=$("$ORCA" terminal create --worktree "$WORKTREE" --title "WATCHDOG-E2E" \
  --command "claude --model haiku" --json 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["terminal"]["handle"])')
[ -z "$HANDLE" ] && { echo "FAIL: 터미널 생성 실패"; exit 1; }
echo "   터미널: $HANDLE"
wait_for "$HANDLE" "❯" 40 || { echo "FAIL: 세션이 뜨지 않았습니다"; exit 1; }
echo "   세션 준비 완료"

echo
echo "2) 세션 화면에 한도 배너가 나타나게 만듭니다"
# 판정기는 대화 글머리(⏺, ❯)로 시작하는 줄을 배너로 인정하지 않는다. 답변의 둘째 줄은
# 글머리 없이 들여쓰기만 되므로, 두 줄로 답하게 해서 진짜 배너와 같은 모양을 만든다.
send_and_enter "$HANDLE" "Reply with exactly two lines and nothing else. First line: STATUS. Second line: $BANNER"
wait_for "$HANDLE" "$BANNER" 60 || { echo "FAIL: 배너가 화면에 나타나지 않았습니다"; exit 1; }
sleep 5
echo "   화면에 '$BANNER' 확인"

echo
echo "3) dry-run: 워치독이 STUCK 으로 보는지, 아무것도 보내지 않는지 확인합니다"
BEFORE="$(screen_of "$HANDLE")"
DRY="$(python3 "$WD" --terminal "$HANDLE" --dry-run --cooldown 0 2>&1)"
printf '%s\n' "$DRY" | sed 's/^/   /'
printf '%s' "$DRY" | grep -q "STUCK" || fail "워치독이 STUCK 으로 판정하지 않았습니다"
sleep 2
if screen_of "$HANDLE" | grep -qF "❯ continue"; then
  fail "dry-run 인데 프롬프트가 제출되었습니다"
else
  echo "   dry-run 에서는 아무것도 보내지 않음 확인"
fi

echo
echo "4) 실제 실행: 워치독이 'continue' 를 주입하는지 확인합니다"
REAL="$(python3 "$WD" --terminal "$HANDLE" --cooldown 0 2>&1)"
printf '%s\n' "$REAL" | sed 's/^/   /'
if wait_for "$HANDLE" "❯ continue" 20; then
  echo "   세션 기록에 '❯ continue' 확인"
else
  fail "'continue' 가 세션에 제출되지 않았습니다"
fi

echo
echo "5) 쿨다운: 곧바로 다시 돌리면 재발동하지 않는지 확인합니다"
AGAIN="$(python3 "$WD" --terminal "$HANDLE" 2>&1)"
printf '%s\n' "$AGAIN" | sed 's/^/   /'
printf '%s' "$AGAIN" | grep -q "쿨다운" || fail "쿨다운이 동작하지 않았습니다"

echo
echo "6) 메뉴 조작: 실제 선택 메뉴에서 커서를 옮길 수 있는지 확인합니다"
send_and_enter "$HANDLE" "/rate-limit-options"
if wait_for "$HANDLE" "What do you want to do?" 20; then
  BEFORE_MENU="$(screen_of "$HANDLE" | grep -c '❯ 1\.')"
  "$ORCA" terminal send --terminal "$HANDLE" --text $'\033[B' >/dev/null 2>&1
  sleep 2
  AFTER_MENU="$(screen_of "$HANDLE" | grep -c '❯ 2\.')"
  if [ "$BEFORE_MENU" -ge 1 ] && [ "$AFTER_MENU" -ge 1 ]; then
    echo "   아래 화살표로 1번 → 2번 커서 이동 확인"
  else
    fail "메뉴 커서가 움직이지 않았습니다 (before1=$BEFORE_MENU after2=$AFTER_MENU)"
  fi
  "$ORCA" terminal send --terminal "$HANDLE" --text $'\033' >/dev/null 2>&1
  sleep 2
  screen_of "$HANDLE" | grep -q "What do you want to do?" && fail "ESC 로 메뉴가 닫히지 않았습니다"
else
  fail "선택 메뉴가 열리지 않았습니다"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "PASS: 종단 테스트를 모두 통과했습니다."; else echo "종단 테스트에 실패한 항목이 있습니다."; fi
exit "$FAILED"
