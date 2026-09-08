#!/usr/bin/env python3
"""Orca 안의 Claude Code 세션이 5시간 사용량 한도에 걸려 멈춰 있으면 자동으로 재개시킨다.

한 번 실행하면 살아 있는 모든 Claude 터미널을 한 바퀴 훑고 끝난다. 주기 실행은 launchd 가 맡는다.

감지 결과는 네 가지다.
  ARMED  Claude Code 가 이미 자동 재개를 예약해 둔 상태다. 건드리지 않는다.
  MENU   한도 옵션 메뉴가 떠 있다. "Wait here, then continue automatically" 항목을 골라준다.
  STUCK  한도에 걸린 채 아무 예약 없이 멈춰 있다. 프롬프트를 넣어 재개시킨다.
  NONE   한도와 무관한 상태다.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

ORCA = os.environ.get("ORCA_BIN", "/usr/local/bin/orca")

# 런타임 일체를 홈 아래 watchdog 디렉터리에 모은다.
HOME_DIR = Path(os.environ.get("WATCHDOG_HOME", os.path.expanduser("~/watchdog")))
BIN_DIR = HOME_DIR / "bin"
LOG_DIR = HOME_DIR / "logs"
SENDER = str(BIN_DIR / "orca-send-prompt.sh")
STATE_FILE = HOME_DIR / "state.json"

# 로그는 하루 단위로 파일을 새로 만들고, 오래된 것은 지운다.
LOG_RETENTION_DAYS = 30

# 한도에 걸렸다는 사실 자체를 알리는 표지.
LIMIT_MARKERS = (
    "Usage limit reached",
    "usage limit reached",
    "Claude usage limit reached",
    "You've hit your monthly spend limit",
    "You've hit your session limit",
)

# Claude Code의 동적 워크플로 한도 안내는 작업 상태의 자식 줄(⎿)로 그려진다. 이 줄은
# 일반 대화의 인용 줄과 모양이 같으므로, 상위 "Dynamic workflow" 상태와 /upgrade 안내까지
# 함께 있을 때만 화면 문자열만으로 인정한다.
WORKFLOW_SESSION_LIMIT_MARKER = "You've hit your session limit"
WORKFLOW_UPGRADE_HINT = "/upgrade to increase your usage limit."
WORKFLOW_STATUS_RE = re.compile(
    r"^[●•⏺]\s+Dynamic workflow\b.*\b(?:completed|failed|stopped)\b", re.IGNORECASE,
)

# Claude Code 가 이미 알아서 이어가기로 예약해 둔 상태의 표지.
ARMED_MARKERS = (
    "continuing automatically",
    "Continuing automatically at",
    "Continuing automatically when your limit resets",
    "Continuing shortly",
    "Claude Code will continue automatically",
    "Usage limit reset",
)

# 자동 재개가 취소되어 사람 손을 기다리는 상태의 표지.
CANCELLED_MARKERS = (
    "Automatic continue cancelled",
)

MENU_TITLE = "What do you want to do?"
MENU_AUTO_RESUME = "Wait here, then continue automatically"

# 표지가 화면 어딘가에 있다는 것만으로는 부족하다. 세션이 한도를 화제로 삼아 그 문구를
# 그냥 출력했을 수도 있기 때문이다. 진짜 배너는 입력창 바로 위에 놓이는 짧은 독립 줄이다.
# 그래서 화면 아래쪽 구간에서, 배너꼴로 생긴 줄만 표지로 인정한다.
TAIL_REGION_LINES = 15
BANNER_MAX_LENGTH = 120

# 줄 맨 앞에 붙는 상태 글리프. 배너 본문을 꺼내려면 떼어내야 한다.
BANNER_LEAD_GLYPHS = "✗✳✻⚠❗•▪●○◆◇· \t"

# 대화 기록임을 드러내는 글머리. 이런 줄은 배너가 아니라 누군가 한 말이다.
TRANSCRIPT_PREFIXES = ("❯", "⏺", "⎿", "│", "├", "└")

# 한도와 무관하게 세션이 답을 기다리는 중이면 손대지 않는다.
BUSY_MARKERS = (
    "esc to interrupt",
    "Do you want to proceed?",
    "Press up to edit queued messages",
)


def log_path() -> Path:
    """오늘 날짜의 로그 파일 경로. 날이 바뀌면 자동으로 새 파일이 된다."""
    return LOG_DIR / f"watchdog-{datetime.now():%Y-%m-%d}.log"


def prune_logs() -> None:
    """보존 기간이 지난 로그 파일을 지운다."""
    cutoff = time.time() - LOG_RETENTION_DAYS * 86400
    for old in LOG_DIR.glob("watchdog-*.log"):
        try:
            if old.stat().st_mtime < cutoff:
                old.unlink()
        except OSError:
            pass


def log(msg: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    line = f"{datetime.now().isoformat(timespec='seconds')} {msg}"
    print(line, flush=True)
    with log_path().open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def orca(*args: str) -> dict | None:
    """orca 하위 명령을 JSON 으로 실행한다. 실패하면 None 을 준다."""
    try:
        proc = subprocess.run(
            [ORCA, *args, "--json"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"WARN orca {' '.join(args)} 실행 실패: {exc}")
        return None
    if proc.returncode != 0:
        return None
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    return payload.get("result") if payload.get("ok") else None


def screen_text(terminal: str) -> tuple[str, str]:
    """터미널의 렌더링된 화면과 컴포저 초안을 돌려준다."""
    result = orca("terminal", "read", "--terminal", terminal, "--screen")
    if not result:
        return "", ""
    term = result.get("terminal") or {}
    tail = term.get("tail")
    if isinstance(tail, list):
        tail = "\n".join(str(x) for x in tail)
    return (tail or ""), (term.get("draft") or "")


def banner_bodies(screen: str) -> list[str]:
    """화면 아래쪽에서 배너처럼 생긴 줄만 골라 본문을 돌려준다.

    대화 기록 글머리로 시작하는 줄, 지나치게 긴 줄, 사용자 프롬프트 에코는 제외한다.
    """
    lines = screen.splitlines()
    bodies = []
    for raw in lines[-TAIL_REGION_LINES:]:
        line = raw.strip()
        if not line or len(line) > BANNER_MAX_LENGTH:
            continue
        if line.startswith(TRANSCRIPT_PREFIXES):
            continue
        bodies.append(line.lstrip(BANNER_LEAD_GLYPHS).strip())
    return bodies


def starts_with_marker(bodies: list[str], markers: tuple[str, ...]) -> bool:
    """배너 본문이 표지로 시작하는지 본다. 문장 한가운데 섞인 것은 인정하지 않는다."""
    return any(body.startswith(m) for body in bodies for m in markers)


def workflow_limit_bodies(screen: str) -> list[str]:
    """Claude Code 작업 상태 트리에 붙는 실제 한도 배너 본문만 돌려준다.

    `⎿`는 일반 대화 인용에도 쓰이므로 단독으로 신뢰하지 않는다.
    바로 위의 workflow 상태와 다음 줄의 업그레이드 안내가 모두 맞을 때만 허용한다.
    """
    lines = screen.splitlines()[-TAIL_REGION_LINES:]
    bodies = []
    for idx, raw in enumerate(lines):
        line = raw.strip()
        if not line.startswith(("⎿", "└")):
            continue
        body = line[1:].lstrip()
        if not body.startswith(WORKFLOW_SESSION_LIMIT_MARKER):
            continue

        previous = next((item.strip() for item in reversed(lines[:idx]) if item.strip()), "")
        following = next((item.strip() for item in lines[idx + 1:] if item.strip()), "")
        if WORKFLOW_STATUS_RE.match(previous) and following.startswith(WORKFLOW_UPGRADE_HINT):
            bodies.append(body)
    return bodies


def classify(screen: str, draft: str) -> tuple[str, dict]:
    """화면 텍스트를 보고 어떤 상태인지 판정한다."""
    info: dict = {}

    bodies = banner_bodies(screen)
    bodies.extend(workflow_limit_bodies(screen))
    has_limit = starts_with_marker(bodies, LIMIT_MARKERS)
    has_cancelled = starts_with_marker(bodies, CANCELLED_MARKERS)

    # 세션이 지금 답을 만들고 있거나 권한 승인을 기다리면 손대지 않는다.
    for marker in BUSY_MARKERS:
        if marker in screen and marker != "Press up to edit queued messages":
            info["reason"] = f"세션이 작업 중임: {marker!r}"
            return "NONE", info

    # 한도 옵션 메뉴가 떠 있고 자동 재개 항목이 있으면 그것부터 고른다.
    tail = "\n".join(screen.splitlines()[-TAIL_REGION_LINES:])
    if MENU_TITLE in tail and MENU_AUTO_RESUME in tail:
        target, current = parse_menu(screen)
        if target is not None and current is not None:
            info["menu_target"] = target
            info["menu_current"] = current
            return "MENU", info
        info["reason"] = "메뉴는 떴지만 항목 번호를 읽지 못함"
        return "NONE", info

    if not (has_limit or has_cancelled):
        return "NONE", info

    # 이미 자동 재개가 예약돼 있으면 그대로 둔다.
    if any(m in screen for m in ARMED_MARKERS) and not has_cancelled:
        return "ARMED", info

    # 사용자가 입력 중이면 절대 덮어쓰지 않는다.
    if draft and draft not in BUSY_MARKERS:
        info["reason"] = f"컴포저에 초안이 있음: {draft[:40]!r}"
        return "NONE", info

    reset_at = parse_reset_time("\n".join(bodies))
    if reset_at is not None:
        info["reset_at"] = reset_at.isoformat(timespec="minutes")
        if datetime.now() < reset_at:
            info["reason"] = f"아직 한도 재설정 전 (재설정 {reset_at:%H:%M})"
            return "NONE", info

    return "STUCK", info


def parse_menu(screen: str) -> tuple[int | None, int | None]:
    """선택 메뉴에서 자동 재개 항목의 번호와 현재 커서 번호를 찾는다."""
    target = current = None
    for line in screen.splitlines():
        m = re.search(r"(❯)?\s*(\d+)\.\s+(.*)", line)
        if not m:
            continue
        idx = int(m.group(2))
        if m.group(1) or line.lstrip().startswith("❯"):
            current = idx
        if MENU_AUTO_RESUME in m.group(3):
            target = idx
    return target, current


def parse_reset_time(screen: str) -> datetime | None:
    """'resets 3pm' 같은 표기에서 한도 재설정 시각을 뽑는다. 못 읽으면 None."""
    m = re.search(r"resets(?:\s+at)?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|AM|PM)?", screen)
    if not m:
        return None
    hour = int(m.group(1))
    minute = int(m.group(2) or 0)
    meridiem = (m.group(3) or "").lower()
    if meridiem == "pm" and hour != 12:
        hour += 12
    elif meridiem == "am" and hour == 12:
        hour = 0
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        return None
    # 화면에는 날짜 없이 시각만 나오므로 어제/오늘/내일 중 지금과 가장 가까운 것을 고른다.
    # 한도 재설정은 길어야 다섯 시간 뒤라서, 지금과 가장 가까운 후보가 언제나 정답이다.
    now = datetime.now()
    today = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    candidates = [today - timedelta(days=1), today, today + timedelta(days=1)]
    return min(candidates, key=lambda c: abs((c - now).total_seconds()))


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}
    return {}


def save_state(state: dict) -> None:
    HOME_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2), encoding="utf-8")


def claude_terminals(only: str | None) -> list[dict]:
    result = orca("terminal", "list")
    if not result:
        return []
    out = []
    for t in result.get("terminals", []):
        if only:
            if t.get("handle") == only:
                out.append(t)
            continue
        if t.get("agentIdentity") != "claude":
            continue
        if not (t.get("connected") and t.get("writable")) or t.get("orphaned"):
            continue
        out.append(t)
    return out


# 보내는 쪽이 "지금은 건드리면 안 된다"고 판단했을 때 쓰는 종료 코드.
SENDER_SKIP = 3


def send_prompt(terminal: str, text: str, dry: bool) -> tuple[bool, bool]:
    """(성공 여부, 보류 여부) 를 돌려준다. 보류는 실패로 세지 않는다."""
    if dry:
        log(f"  DRY-RUN 이므로 전송하지 않음 (보낼 값: {text!r})")
        return True, False
    proc = subprocess.run(
        [SENDER, "--terminal", terminal, "--text", text],
        capture_output=True, text=True, timeout=60,
    )
    for line in (proc.stdout + proc.stderr).strip().splitlines():
        log(f"  | {line}")
    if proc.returncode == SENDER_SKIP:
        return False, True
    return proc.returncode == 0, False


def pick_menu_option(terminal: str, target: int, current: int, dry: bool) -> bool:
    steps = target - current
    if dry:
        log(f"  DRY-RUN 이므로 메뉴 선택 안 함 (아래로 {steps}칸 이동 후 Enter)")
        return True
    if steps > 0:
        arrows = "\x1b[B" * steps
        subprocess.run([ORCA, "terminal", "send", "--terminal", terminal, "--text", arrows],
                       capture_output=True, timeout=30)
    elif steps < 0:
        arrows = "\x1b[A" * (-steps)
        subprocess.run([ORCA, "terminal", "send", "--terminal", terminal, "--text", arrows],
                       capture_output=True, timeout=30)
    time.sleep(1)
    proc = subprocess.run([ORCA, "terminal", "send", "--terminal", terminal, "--enter"],
                          capture_output=True, timeout=30)
    return proc.returncode == 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Orca 안의 Claude 세션을 한도 해제 후 자동 재개시킨다")
    ap.add_argument("--text", default="continue", help="재개할 때 넣을 프롬프트 (기본 continue)")
    ap.add_argument("--terminal", help="이 터미널 하나만 검사한다 (테스트용)")
    ap.add_argument("--cooldown", type=int, default=1800, help="같은 터미널 재발동 최소 간격(초)")
    ap.add_argument("--dry-run", action="store_true", help="감지만 하고 아무것도 보내지 않는다")
    ap.add_argument("--classify-file", help="파일에 담긴 화면 텍스트를 판정만 하고 끝낸다 (테스트용)")
    ap.add_argument("--draft", default="", help="--classify-file 과 함께 쓸 가짜 컴포저 초안")
    args = ap.parse_args()

    # 판정 로직만 단독으로 시험하는 경로.
    if args.classify_file:
        text = Path(args.classify_file).read_text(encoding="utf-8")
        verdict, info = classify(text, args.draft)
        print(json.dumps({"verdict": verdict, **info}, ensure_ascii=False))
        return 0

    prune_logs()

    terminals = claude_terminals(args.terminal)
    if not terminals:
        log("점검 완료 — 검사할 Claude 터미널이 없습니다.")
        return 0
    log(f"점검 시작 — Claude 터미널 {len(terminals)}개")

    state = load_state()
    now = time.time()
    acted = 0

    for t in terminals:
        handle = t["handle"]
        screen, draft = screen_text(handle)
        if not screen:
            continue
        verdict, info = classify(screen, draft)
        label = t.get("title") or t.get("worktreePath") or handle

        if verdict == "NONE":
            continue
        if verdict == "ARMED":
            log(f"ARMED  {label} — Claude Code 가 이미 자동 재개를 예약해 두었습니다. 넘어갑니다.")
            continue

        last = state.get(handle, {}).get("last_fired", 0)
        if now - last < args.cooldown:
            wait = int(args.cooldown - (now - last))
            log(f"SKIP   {label} — {verdict} 이지만 쿨다운이 {wait}초 남았습니다.")
            continue

        deferred = False
        if verdict == "MENU":
            log(f"MENU   {label} — 한도 옵션 메뉴에서 자동 재개 항목을 고릅니다 "
                f"({info['menu_current']} → {info['menu_target']}).")
            ok = pick_menu_option(handle, info["menu_target"], info["menu_current"], args.dry_run)
        else:
            log(f"STUCK  {label} — 한도에 걸린 채 멈춰 있어 {args.text!r} 를 넣습니다. {info.get('reason','')}")
            ok, deferred = send_prompt(handle, args.text, args.dry_run)

        if deferred:
            log(f"SKIP   {label} — 지금은 건드릴 수 없어 다음 순찰로 미룹니다.")
        elif ok and not args.dry_run:
            state.setdefault(handle, {})["last_fired"] = now
            state[handle]["label"] = label
            acted += 1
            log(f"OK     {label} — 재개 조치를 마쳤습니다.")
        elif not ok:
            log(f"FAIL   {label} — 재개 조치에 실패했습니다.")

    if acted:
        save_state(state)
    log(f"점검 완료 — 조치 {acted}건")
    return 0


if __name__ == "__main__":
    sys.exit(main())
