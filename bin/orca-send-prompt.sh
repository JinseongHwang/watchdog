#!/usr/bin/env bash
# orca-send-prompt.sh — Orca 터미널의 Claude Code 세션에 프롬프트를 넣고 엔터로 제출한다.
#
# 사용법:
#   orca-send-prompt.sh [--terminal <handle>] [--text <프롬프트>] [--dry-run] [--force]
#
#   --terminal  대상 터미널 핸들. 생략하면 $ORCA_TERMINAL_HANDLE 을 쓴다.
#   --text      보낼 프롬프트. 기본값은 "continue".
#   --dry-run   컴포저에 텍스트만 올리고 엔터는 누르지 않는다. 확인 후 지운다.
#   --force     컴포저에 사용자가 입력하던 초안이 남아 있어도 강행한다.
#
# 종료 코드: 0 성공, 1 실패, 2 사용법 오류, 3 초안 보호로 중단

set -uo pipefail

TERMINAL="${ORCA_TERMINAL_HANDLE:-}"
TEXT="continue"
DRY_RUN=0
FORCE=0
# launchd 는 대화형 셸의 PATH를 물려받지 않는다. 감지 본체와 같은 절대 경로를 써야
# 메뉴바/launchd 순찰에서도 terminal show·send가 실제 Orca CLI를 실행한다.
ORCA="${ORCA_BIN:-/usr/local/bin/orca}"

while [ $# -gt 0 ]; do
  case "$1" in
    --terminal) TERMINAL="${2:-}"; shift 2 ;;
    --text)     TEXT="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$TERMINAL" ]; then
  echo "FAIL: 터미널 핸들이 없습니다. --terminal 을 주거나 Orca 터미널 안에서 실행하세요." >&2
  exit 2
fi

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

# 화면(rendered screen)에서 draft 필드만 뽑는다.
read_draft() {
  "$ORCA" terminal read --terminal "$TERMINAL" --screen --json 2>/dev/null \
    | python3 -c 'import sys,json
try:
    t=json.load(sys.stdin)["result"]["terminal"]
except Exception:
    print(""); sys.exit(0)
d=t.get("draft")
print(d if d else "")'
}

# 화면 전체 텍스트
read_screen() {
  "$ORCA" terminal read --terminal "$TERMINAL" --screen --json 2>/dev/null \
    | python3 -c 'import sys,json
try:
    t=json.load(sys.stdin)["result"]["terminal"]
except Exception:
    sys.exit(0)
tail=t.get("tail")
print(tail if isinstance(tail,str) else "\n".join(map(str,tail or [])))'
}

# 컴포저 초안을 백스페이스로 지운다.
clear_draft() {
  local n=$1 bs=""
  local i
  for ((i=0;i<n+8;i++)); do bs+=$'\177'; done
  "$ORCA" terminal send --terminal "$TERMINAL" --text "$bs" >/dev/null 2>&1
}

log "대상 터미널: $TERMINAL"

# 1) 터미널이 살아 있고 쓰기 가능한지 확인.
#    조회는 앱이 바쁠 때 간헐적으로 빈 응답을 주므로 한 번 더 시도한다.
probe_terminal() {
  "$ORCA" terminal show --terminal "$TERMINAL" --json 2>/dev/null \
    | python3 -c 'import sys,json
try:
    t=json.load(sys.stdin)["result"]["terminal"]
except Exception:
    print("missing"); sys.exit(0)
print("ok" if t.get("connected") and t.get("writable") and not t.get("orphaned") else "dead")'
}

ALIVE="$(probe_terminal)"
if [ "$ALIVE" = "missing" ]; then
  sleep 2
  ALIVE="$(probe_terminal)"
fi

case "$ALIVE" in
  ok) log "터미널 상태: 연결됨 / 쓰기 가능" ;;
  missing)
    # 조회 자체가 안 됐을 뿐 터미널이 죽었다고 단정할 수 없다. 실패가 아니라 보류로 다룬다.
    echo "SKIP: 터미널 상태를 조회하지 못해 이번에는 건너뜁니다." >&2
    exit 3
    ;;
  *)
    echo "FAIL: 터미널이 연결되지 않았거나 쓰기 불가 상태입니다 ($ALIVE)." >&2
    exit 1
    ;;
esac

# 2) 사용자가 쓰던 초안이 있으면 덮어쓰지 않는다
PRIOR_DRAFT="$(read_draft)"
if [ -n "$PRIOR_DRAFT" ] && [ "$FORCE" -eq 0 ]; then
  echo "SKIP: 컴포저에 입력 중인 초안이 있어 중단합니다: '${PRIOR_DRAFT:0:60}'" >&2
  exit 3
fi
log "컴포저 비어 있음 확인"

# 3) 텍스트 주입
"$ORCA" terminal send --terminal "$TERMINAL" --text "$TEXT" >/dev/null 2>&1 || {
  echo "FAIL: 텍스트 전송 실패" >&2; exit 1; }
sleep 1
AFTER="$(read_draft)"
if [ "$AFTER" != "$TEXT" ]; then
  echo "FAIL: 컴포저에 텍스트가 올라가지 않았습니다. draft='$AFTER'" >&2
  clear_draft "${#TEXT}"
  exit 1
fi
log "컴포저 주입 확인: draft='$AFTER'"

# 4) dry-run 이면 여기서 지우고 종료
if [ "$DRY_RUN" -eq 1 ]; then
  clear_draft "${#TEXT}"
  sleep 1
  RESIDUE="$(read_draft)"
  if [ -n "$RESIDUE" ]; then
    echo "WARN: 초안이 완전히 지워지지 않았습니다: '$RESIDUE'" >&2
    exit 1
  fi
  log "PASS(dry-run): 주입과 정리까지 성공. 엔터는 누르지 않았습니다."
  exit 0
fi

# 5) 엔터로 제출
"$ORCA" terminal send --terminal "$TERMINAL" --enter >/dev/null 2>&1 || {
  echo "FAIL: 엔터 전송 실패" >&2; exit 1; }
sleep 2

# 제출 직후 Claude Code 는 컴포저 자리에 안내 문구를 띄우므로,
# 비었는지가 아니라 "우리가 넣은 텍스트가 사라졌는지"로 판정한다.
SUBMITTED_DRAFT="$(read_draft)"
case "$SUBMITTED_DRAFT" in
  "$TEXT")
    echo "FAIL: 엔터 후에도 컴포저에 '$TEXT' 가 그대로 남아 있습니다. 제출되지 않았습니다." >&2
    exit 1
    ;;
esac
if [ -n "$SUBMITTED_DRAFT" ]; then
  log "컴포저 상태: '$SUBMITTED_DRAFT' (주입 텍스트는 사라짐 = 제출됨)"
fi

SCREEN="$(read_screen)"
if printf '%s' "$SCREEN" | grep -qF "❯ $TEXT"; then
  log "PASS: '$TEXT' 가 제출되어 대화 기록에 나타났습니다."
  exit 0
fi
if printf '%s' "$SCREEN" | grep -qiF "queued message"; then
  log "PASS: '$TEXT' 가 제출되어 큐에 들어갔습니다(세션이 응답 중이라 대기)."
  exit 0
fi

log "PASS(부분): 주입 텍스트가 컴포저에서 사라졌으니 제출은 됐습니다. 화면 기록 확인은 못 했습니다."
exit 0
