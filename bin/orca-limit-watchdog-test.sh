#!/usr/bin/env bash
# orca-limit-watchdog-test.sh — 한도 워치독의 판정 로직을 픽스처로 검증한다.
#
# 실제 5시간 한도 상황은 마음대로 재현할 수 없다. 그래서 Claude Code 바이너리에서
# 그대로 추출한 문구로 화면 픽스처를 만들고, 판정 결과가 기대와 맞는지 확인한다.
# 시각에 의존하는 항목은 실행 시점 기준으로 픽스처를 생성해 언제 돌려도 결과가 같다.

set -uo pipefail
WD_HOME="${WATCHDOG_HOME:-$HOME/watchdog}"
WD="$WD_HOME/bin/orca-limit-watchdog.py"
FIX="$WD_HOME/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

check() {
  local name="$1" file="$2" expected="$3" draft="${4:-}"
  local out verdict
  out="$(python3 "$WD" --classify-file "$file" --draft "$draft" 2>&1)"
  verdict="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["verdict"])' 2>/dev/null)"
  if [ "$verdict" = "$expected" ]; then
    printf '  PASS  %-30s → %-5s %s\n' "$name" "$verdict" "$out"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %-30s → 기대 %s, 실제 %s | %s\n' "$name" "$expected" "${verdict:-<파싱실패>}" "$out"
    FAIL=$((FAIL+1))
  fi
}

# 지금으로부터 상대적인 시각을 'resets 3pm' 형태로 만든다.
rel_time() { python3 -c "
import sys
from datetime import datetime, timedelta
t = datetime.now() + timedelta(minutes=int(sys.argv[1]))
print(t.strftime('%-I:%M%p').lower())
" "$1"; }

echo "== 기본 상태 판정 =="
check "한도에 걸려 멈춤"            "$FIX/stuck.txt"            STUCK
check "자동 재개 예약됨"            "$FIX/armed.txt"            ARMED
check "옵션 메뉴 떠 있음"           "$FIX/menu.txt"             MENU
check "자동 재개 취소됨"            "$FIX/cancelled.txt"        STUCK
check "평범한 유휴"                 "$FIX/idle.txt"             NONE
check "응답 생성 중이면 보호"       "$FIX/busy.txt"             NONE

echo
echo "== 사용자 입력 보호 =="
check "사용자가 입력 중이면 보호"   "$FIX/stuck-with-draft.txt" NONE  "커밋 메시지 써줘"
check "큐 안내문은 초안이 아님"     "$FIX/stuck.txt"            STUCK "Press up to edit queued messages"

echo
echo "== 오탐 방지 =="
check "실제 대화 화면 (회귀)"        "$FIX/false-positive-transcript.txt" NONE
check "마커를 말로만 언급"            "$FIX/prose-mention.txt"             NONE
check "위로 밀려난 옛 배너"           "$FIX/scrolled-away.txt"             NONE

echo
echo "== 한도 재설정 시각 게이트 =="
sed "s/Usage limit reached/Usage limit reached · resets $(rel_time 90)/" "$FIX/stuck.txt" > "$TMP/future.txt"
sed "s/Usage limit reached/Usage limit reached · resets $(rel_time -90)/" "$FIX/stuck.txt" > "$TMP/past.txt"
check "재설정 전이면 기다림"        "$TMP/future.txt"           NONE
check "재설정 후면 재개"            "$TMP/past.txt"             STUCK

echo
echo "합계: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
