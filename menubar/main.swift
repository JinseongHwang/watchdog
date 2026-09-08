// Orca 한도 워치독의 상태를 macOS 메뉴바에 띄우는 앱.
//
// 의존성 없이 AppKit 만 쓴다. launchctl 로 launchd 등록 상태를 읽고,
// ~/watchdog/logs 의 오늘 로그를 파싱해 최근 활동을 보여준다.

import AppKit
import Foundation

// MARK: - 설정

enum Config {
    static let label = "com.jinseonghwang.orca-limit-watchdog"
    static let home: URL = {
        if let override = ProcessInfo.processInfo.environment["WATCHDOG_HOME"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("watchdog")
    }()
    static var logsDir: URL { home.appendingPathComponent("logs") }
    static var watchdogScript: URL { home.appendingPathComponent("bin/orca-limit-watchdog.py") }
    static let python = "/usr/bin/python3"
    static let refreshInterval: TimeInterval = 15
    static let recentPatrols = 12 // 순찰 기록과 눈여겨볼 일의 공통 원본
}

// MARK: - 셸 실행

@discardableResult
func shell(_ command: String, timeout: TimeInterval = 10) -> (out: String, status: Int32) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", command]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() } catch { return ("", -1) }

    let deadline = Date().addingTimeInterval(timeout)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    while task.isRunning && Date() < deadline { usleep(20_000) }
    if task.isRunning { task.terminate() }
    task.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", task.terminationStatus)
}

// MARK: - 로그 한 줄

struct LogEntry {
    let time: Date
    let kind: String      // STUCK, MENU, ARMED, WAIT, OK, SKIP, FAIL, WARN
    let message: String
    let isToday: Bool

    /// 로그 본문은 "<터미널 이름> — <설명>" 꼴이다. 종류 라벨이 이미 무슨 일인지 말해주므로
    /// 메뉴에는 대상 이름만 보여준다. 자세한 내용은 일지 파일에 그대로 남아 있다.
    var target: String {
        if let sep = message.range(of: " — ") {
            let head = String(message[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head }
        }
        return message
    }

    var icon: String {
        switch kind {
        case "OK":    return "🦴"   // 구했다, 간식 하나
        case "STUCK": return "🚨"   // 멈춘 세션 발견
        case "MENU":  return "🎯"   // 메뉴에서 골라줌
        case "ARMED": return "😌"   // 이미 예약돼 있어 안심
        case "WAIT":  return "⏳"   // 한도 재설정 대기
        case "SKIP":  return "😴"   // 쿨다운, 잠깐 쉼
        case "FAIL":  return "💔"
        case "WARN":  return "⚠️"
        default:      return "🐾"
        }
    }
    var kindLabel: String {
        switch kind {
        case "OK":    return "구조 완료"
        case "STUCK": return "멈춤 발견"
        case "MENU":  return "메뉴 선택"
        case "ARMED": return "예약됨"
        case "WAIT":  return "한도 대기"
        case "SKIP":  return "쉬는 중"
        case "FAIL":  return "실패"
        case "WARN":  return "경고"
        default:      return kind
        }
    }
    var isAction: Bool { kind == "OK" || kind == "STUCK" || kind == "MENU" }
}

/// 한 순찰의 완료 로그와 그 사이에 생긴 예외 로그를 묶은 한 행.
struct PatrolRecord {
    let time: Date
    let sessions: Int
    let actions: Int
    let isToday: Bool
    let events: [LogEntry]

    /// 한 순찰 안에서 마지막으로 기록된 상태가 최종 결과다. 예를 들어 STUCK 뒤 OK가
    /// 오면 "구조 완료"로 보여 주되, 원본 이벤트는 순찰 일지 파일에 모두 남아 있다.
    var finalEvent: LogEntry? { events.last }
    var icon: String {
        if let event = finalEvent { return event.icon }
        if actions > 0 { return "🦴" }
        return sessions == 0 ? "🌙" : "🐾"
    }
    var kindLabel: String {
        if let event = finalEvent { return event.kindLabel }
        if actions > 0 { return "조치 \(actions)건" }
        return sessions == 0 ? "볼 것 없음" : "이상 없음"
    }
    var detail: String {
        if let event = finalEvent { return event.target }
        return sessions == 0 ? "" : "세션 \(sessions)개"
    }
    var isAction: Bool { finalEvent?.isAction == true || actions > 0 }
    var isNoteworthy: Bool { !events.isEmpty }
}

// MARK: - 수집한 상태

struct WatchdogStatus {
    var registered = false
    var runs = 0
    var lastExitCode: Int?
    var intervalSeconds = 600
    var lastScanStart: Date?
    var lastScanEnd: Date?
    var sessionCount: Int?
    var actionsToday = 0
    var scansToday = 0
    var patrols: [PatrolRecord] = []
    var noteworthy: [PatrolRecord] = []
    var logFile: URL?

    /// 마지막 점검이 주기의 2.5배를 넘겼으면 뭔가 잘못된 것으로 본다.
    var isStale: Bool {
        guard let last = lastScanEnd ?? lastScanStart else { return registered }
        return Date().timeIntervalSince(last) > Double(intervalSeconds) * 2.5
    }
    /// 최근 두 주기 안에 난 실패만 현재 상태로 친다.
    /// 오늘 아침에 한 번 실패했다고 저녁까지 경고를 띄우면 신호가 아니라 소음이 된다.
    var hasFailure: Bool {
        if let code = lastExitCode, code != 0 { return true }
        let window = Double(intervalSeconds) * 2
        return noteworthy.contains {
            $0.events.contains { $0.kind == "FAIL" } && Date().timeIntervalSince($0.time) < window
        }
    }
    enum Health { case healthy, stopped, warning }
    var health: Health {
        if !registered { return .stopped }
        if hasFailure || isStale { return .warning }
        return .healthy
    }
}

// MARK: - 상태 수집

enum StatusReader {
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func logURL(daysAgo: Int = 0) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return Config.logsDir.appendingPathComponent("watchdog-\(f.string(from: day)).log")
    }

    static func todayLogURL() -> URL { logURL() }

    static func read() -> WatchdogStatus {
        var s = WatchdogStatus()
        readLaunchd(into: &s)
        readLog(into: &s)
        return s
    }

    private static func readLaunchd(into s: inout WatchdogStatus) {
        let uid = getuid()
        let (out, status) = shell("launchctl print gui/\(uid)/\(Config.label) 2>/dev/null")
        guard status == 0, !out.isEmpty else { s.registered = false; return }
        s.registered = true
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("runs = ") {
                s.runs = Int(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("last exit code = ") {
                s.lastExitCode = Int(line.dropFirst(17).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("run interval = ") {
                let v = line.dropFirst(15).replacingOccurrences(of: " seconds", with: "")
                s.intervalSeconds = Int(v.trimmingCharacters(in: .whitespaces)) ?? 600
            }
        }
    }

    private static func readLog(into s: inout WatchdogStatus) {
        let today = todayLogURL()
        s.logFile = FileManager.default.fileExists(atPath: today.path) ? today : nil

        // 자정 직후에는 오늘 로그가 거의 비어 있다. 보여줄 줄이 모자라면 어제 것으로 채운다.
        var sources: [URL] = []
        for back in stride(from: 3, through: 0, by: -1) {
            let url = logURL(daysAgo: back)
            if FileManager.default.fileExists(atPath: url.path) { sources.append(url) }
        }
        guard !sources.isEmpty else { return }

        // 한 번의 "점검 시작"부터 "점검 완료"까지가 메뉴의 한 행이다. 그 사이의
        // STUCK/WAIT 같은 이벤트를 별도 행으로 쌓으면 정상 점검과 중복돼 보인다.
        var patrols: [PatrolRecord] = []
        // 예전 로그에는 수동 점검과 launchd 점검이 겹쳐 "시작, 이벤트, 시작"처럼
        // 끼어든 적이 있다. 스택으로 읽으면 그런 기존 기록도 각 순찰로 보존한다.
        struct PendingPatrol {
            let sessions: Int
            var events: [LogEntry]
        }
        var pendingPatrols: [PendingPatrol] = []
        var lines: [String] = []
        for url in sources {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let isToday = url == today
            for raw in text.split(separator: "\n") {
                // 오늘 것만 통계에 넣고, 지난 날짜는 최근 활동 목록을 채우는 데만 쓴다.
                lines.append((isToday ? "T" : "P") + String(raw))
            }
        }

        for tagged in lines {
            let isToday = tagged.hasPrefix("T")
            let raw = String(tagged.dropFirst())
            let line = String(raw)
            // 하위 프로세스 출력은 '  | ' 로 들여쓰기되어 있으므로 건너뛴다.
            if line.contains("  | ") { continue }
            guard line.count > 19 else { continue }
            let stampText = String(line.prefix(19))
            guard let time = stamp.date(from: stampText) else { continue }
            let rest = line.dropFirst(19).trimmingCharacters(in: .whitespaces)

            if rest.hasPrefix("점검 시작") {
                s.lastScanStart = time
                let sessions = firstInteger(in: rest) ?? 0
                pendingPatrols.append(PendingPatrol(sessions: sessions, events: []))
                s.sessionCount = sessions
                continue
            }
            if rest.hasPrefix("점검 완료") {
                s.lastScanEnd = time
                // "검사할 Claude 터미널이 없습니다" 로 끝나면 조치 수가 적히지 않는다.
                let acted = rest.contains("조치") ? (firstInteger(in: rest) ?? 0) : 0
                let pending = pendingPatrols.popLast()
                let seen = pending?.sessions ?? 0
                s.sessionCount = seen
                patrols.append(PatrolRecord(time: time, sessions: seen, actions: acted,
                                            isToday: isToday, events: pending?.events ?? []))
                if isToday {
                    s.scansToday += 1
                    s.actionsToday += acted
                }
                continue
            }
            let kinds = ["STUCK", "MENU", "ARMED", "WAIT", "OK", "SKIP", "FAIL", "WARN"]
            if let kind = kinds.first(where: { rest.hasPrefix($0) }), !pendingPatrols.isEmpty {
                let msg = rest.dropFirst(kind.count).trimmingCharacters(in: .whitespaces)
                pendingPatrols[pendingPatrols.count - 1].events.append(
                    LogEntry(time: time, kind: kind, message: msg, isToday: isToday))
            }
        }
        s.patrols = Array(patrols.suffix(Config.recentPatrols))
        s.noteworthy = s.patrols.filter { $0.isNoteworthy }
    }

    private static func firstInteger(in text: String) -> Int? {
        var digits = ""
        for ch in text {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        return Int(digits)
    }
}

// MARK: - 표시용 문자열

func shortTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: date)
}

/// 오늘이 아닌 기록에 붙일 표기. 날짜가 없으면 어제 일이 오늘 일처럼 보인다.
func dayTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: date)
}

/// 순찰이 없던 구간의 길이를 사람이 읽을 단위로 적는다.
func durationText(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int(seconds) / 60)
    if minutes < 60 { return "\(minutes)분" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)시간 \(minutes % 60)분" }
    return "\(hours / 24)일 \(hours % 24)시간"
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var status = WatchdogStatus()
    private weak var headerLabel: NSTextField?
    var selfTest = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        if selfTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.printSelfTest() }
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: Config.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// 화면을 볼 수 없는 환경에서 메뉴바 아이템과 파싱 결과를 검증하기 위한 자가 진단.
    private func printSelfTest() {
        var failures: [String] = []
        var notes: [String] = []

        print("== 메뉴바 아이템 ==")
        print("  statusItem 생성됨: \(statusItem != nil)")
        print("  button 존재: \(statusItem.button != nil)")
        print("  isVisible: \(statusItem.isVisible)")
        print("  아이콘: \(statusItem.button?.attributedTitle.string ?? "없음")")
        print("  툴팁: \(statusItem.button?.toolTip ?? "없음")")
        print("  화면상 너비: \(statusItem.button?.frame.width ?? -1)")
        if statusItem.button == nil { failures.append("메뉴바 버튼이 생성되지 않음") }
        if !statusItem.isVisible { failures.append("메뉴바 아이템이 보이지 않는 상태") }
        if (statusItem.button?.frame.width ?? 0) <= 0 { failures.append("메뉴바 아이템 너비가 0") }

        print("\n== 읽어들인 상태 ==")
        print("  launchd 등록: \(status.registered)")
        print("  총 실행 횟수: \(status.runs)")
        print("  마지막 종료 코드: \(status.lastExitCode.map(String.init) ?? "없음")")
        print("  점검 주기: \(status.intervalSeconds)초")
        print("  마지막 점검 시작: \(status.lastScanStart.map(shortTime) ?? "없음")")
        print("  마지막 점검 종료: \(status.lastScanEnd.map(shortTime) ?? "없음")")
        print("  감시 세션 수: \(status.sessionCount.map(String.init) ?? "없음")")
        print("  오늘 조치: \(status.actionsToday)건")
        print("  순찰 기록 항목: \(status.patrols.count)건 " +
              "(오늘 \(status.patrols.filter { $0.isToday }.count)건, " +
              "이전 \(status.patrols.filter { !$0.isToday }.count)건)")
        print("  눈여겨볼 일: \(status.noteworthy.count)건 (순찰 기록의 부분집합)")
        print("  오늘 순찰 횟수: \(status.scansToday)번")
        print("  건강 상태: \(headline())")
        print("  로그 파일: \(status.logFile?.lastPathComponent ?? "없음")")
        // 갓 설치해서 아직 한 번도 안 돌았으면 로그가 없는 게 정상이다. 실패가 아니라 안내로 다룬다.
        if status.logFile == nil { notes.append("오늘 로그 파일이 아직 없습니다 (첫 순찰 전이면 정상)") }
        if status.lastScanStart == nil { notes.append("오늘 점검 기록이 아직 없습니다") }

        print("\n== 상태 헤더 렌더링 ==")
        if let h = headerLabel {
            print("  문구: \(h.stringValue)")
            print("  글꼴 크기: \(h.font?.pointSize ?? -1)  굵기: \(h.font?.fontDescriptor.symbolicTraits.contains(.bold) == true ? "bold" : "regular")")
            print("  글씨 색: \(h.textColor?.description ?? "없음")")
            print("  커스텀 뷰 사용: true (회색 처리 회피)")
        } else {
            failures.append("상태 헤더가 그려지지 않음")
        }

        print("\n== 메뉴 구성 ==")
        print("  최상위 항목 수: \(menu.numberOfItems)")
        for item in menu.items where !item.isSeparatorItem {
            print("    \(item.title)")
        }
        if menu.numberOfItems < 8 { failures.append("메뉴 항목이 너무 적음") }

        print("")
        for note in notes { print("참고: " + note) }
        if failures.isEmpty {
            print("PASS: 자가 진단 통과")
        } else {
            print("FAIL: " + failures.joined(separator: " / "))
        }
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func refresh() {
        status = StatusReader.read()
        updateIcon()
        rebuildMenu()
    }

    /// 상태를 색으로도 알려준다. 초록은 정상, 주황은 주의, 빨강은 보호가 꺼진 상태다.
    private var stateColor: NSColor {
        switch status.health {
        case .healthy: return .systemGreen
        case .warning: return .systemOrange
        case .stopped: return .systemRed
        }
    }

    private var faceEmoji: String {
        switch status.health {
        case .healthy: return "🐶"
        case .warning: return "🐶❗"
        case .stopped: return "🐶💤"
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.attributedTitle = NSAttributedString(
            string: faceEmoji,
            attributes: [.font: NSFont.systemFont(ofSize: 14)])
        button.toolTip = "워치독 \(headline())"
    }

    private func headline() -> String {
        switch status.health {
        case .healthy: return "왈왈! 잘 지키고 있어요"
        case .warning: return status.hasFailure ? "끙... 문제가 좀 있었어요" : "음? 순찰이 늦어지고 있어요"
        case .stopped: return "쿨쿨 자는 중이에요"
        }
    }

    // MARK: 메뉴 구성

    private func rebuildMenu() {
        menu.removeAllItems()

        addStatusHeader("\(faceEmoji)  \(headline())", color: stateColor)

        if status.registered {
            // 마지막 순찰 시각과 다음 순찰 예정, 실행 횟수, 종료 코드는 빼기로 했다.
            // 바로 아래 순찰 기록에 같은 내용이 더 자세히 나오고, 순찰이 늦거나 오류로
            // 끝난 사실은 맨 위 상태 문구가 이미 알려준다. 줄이 길어지면 정작 볼 것이 묻힌다.
            addRow("🔁", "순찰 주기", "\(status.intervalSeconds / 60)분마다")
            if let n = status.sessionCount {
                addRow("👀", "지켜보는 세션", n == 0 ? "지금은 없어요" : "\(n)개")
            }
            addRow("🦴", "오늘 구조한 횟수", status.actionsToday == 0 ? "아직 없어요" : "\(status.actionsToday)번")
        } else {
            addRow("💤", "지금 상태", "잠들어 있어요. 아래에서 깨워주세요")
        }

        menu.addItem(.separator())

        // 로그는 한 번만 파싱한다. 순찰 기록은 완료된 순찰 전체이고, 눈여겨볼 일은
        // 예외 이벤트가 들어 있던 바로 그 순찰 행만 다시 고른 부분집합이다.
        addHeader("🐾  순찰 기록")
        if status.patrols.isEmpty {
            addRow("🌙", "", "아직 순찰 기록이 없어요")
        } else {
            // 컴퓨터를 꺼 두면 그 사이에는 순찰이 아예 돌지 않는다. 줄을 그냥 이어 붙이면
            // 몇 시간이 통째로 빠진 자리가 10분 간격처럼 보이므로, 빈 구간을 눈에 보이게 적는다.
            if let newest = status.patrols.last, let text = gapText(from: newest.time, to: Date()) {
                addGapLine("\(text) 지금까지")
            }
            var newer: Date?
            for patrol in status.patrols.reversed() {
                if let next = newer, let text = gapText(from: patrol.time, to: next) {
                    addGapLine(text)
                }
                addPatrolLine(patrol)
                newer = patrol.time
            }
        }

        menu.addItem(.separator())

        addHeader("🔔  눈여겨볼 일")
        if status.noteworthy.isEmpty {
            addRow("😌", "", "최근에 별일 없었어요")
        } else {
            for patrol in status.noteworthy.reversed() { addPatrolLine(patrol) }
        }

        // 실제로 무언가를 실행하는 항목이므로 비유를 빼고 하는 일을 그대로 적는다.
        menu.addItem(.separator())
        addAction("🔄  지금 점검 실행", #selector(runNow))
        addAction("🔍  점검 미리보기 (전송 없음)", #selector(runDryRun))
        menu.addItem(.separator())
        addAction("📄  오늘 로그 열기", #selector(openLog))
        addAction("📂  watchdog 폴더 열기", #selector(openFolder))
        menu.addItem(.separator())
        addAction(status.registered ? "⏹  워치독 중지" : "▶️  워치독 시작", #selector(toggleAgent))
        addAction("✕  메뉴바 앱 종료", #selector(quit))
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    /// 맨 위 상태 줄. NSMenuItem 을 비활성으로 두면 macOS 가 회색으로 흐리게 그려서
    /// 글씨 색과 크기를 지정해도 무시된다. 그래서 뷰를 직접 얹는다.
    private func addStatusHeader(_ text: String, color: NSColor) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        label.textColor = color
        label.sizeToFit()

        let padX: CGFloat = 14, padY: CGFloat = 9
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: max(label.frame.width + padX * 2, 280),
                                             height: label.frame.height + padY * 2))
        label.setFrameOrigin(NSPoint(x: padX, y: padY))
        container.addSubview(label)

        let item = NSMenuItem()
        item.view = container
        menu.addItem(item)
        headerLabel = label
    }

    private func addSubHeader(_ title: String) {
        let text = "  \(title)"
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.tertiaryLabelColor])
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addHeader(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)])
        item.isEnabled = false
        menu.addItem(item)
    }

    /// 정보 한 줄. 이모지, 이름, 값을 나란히 놓고 이름 폭을 맞춰 세로로 정렬한다.
    private func addRow(_ emoji: String, _ key: String, _ value: String) {
        let padded = key.isEmpty ? "" : key.padding(toLength: max(key.count, 9), withPad: " ", startingAt: 0)
        let title = "  \(emoji)  \(padded)   \(value)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor])
        // 값 부분만 진하게 해서 눈이 먼저 가게 한다.
        if !value.isEmpty, let range = title.range(of: value, options: .backwards) {
            attr.addAttributes(
                [.foregroundColor: NSColor.labelColor,
                 .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)],
                range: NSRange(range, in: title))
        }
        item.attributedTitle = attr
        item.isEnabled = false
        menu.addItem(item)
    }

    /// 순찰 한 줄. 이벤트가 있으면 그 최종 상태로, 없으면 세션 수로 요약한다.
    private func addPatrolLine(_ patrol: PatrolRecord) {
        let kind = patrol.kindLabel.padding(toLength: 6, withPad: " ", startingAt: 0)
        let stamp = patrol.isToday ? shortTime(patrol.time) : dayTime(patrol.time)
        let title = "  \(patrol.icon)  \(stamp)  \(kind)   \(truncate(patrol.detail, 44))"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: patrol.isAction ? NSColor.labelColor : NSColor.secondaryLabelColor])
        item.isEnabled = false
        menu.addItem(item)
    }

    /// 두 시각 사이가 주기의 2.5배를 넘으면 그동안 순찰이 돌지 않았다고 본다.
    private func gapText(from older: Date, to newer: Date) -> String? {
        let gap = newer.timeIntervalSince(older)
        guard gap > Double(status.intervalSeconds) * 2.5 else { return nil }
        return "\(durationText(gap)) 동안 순찰이 없었어요"
    }

    private func addGapLine(_ text: String) {
        let title = "  💤  \(text)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.tertiaryLabelColor])
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: 동작

    @objc private func runNow() { runWatchdog(dryRun: false) }
    @objc private func runDryRun() { runWatchdog(dryRun: true) }

    private func runWatchdog(dryRun: Bool) {
        let flag = dryRun ? " --dry-run" : ""
        DispatchQueue.global(qos: .userInitiated).async {
            let (out, _) = shell("\(Config.python) \(Config.watchdogScript.path)\(flag) 2>&1", timeout: 120)
            DispatchQueue.main.async {
                self.refresh()
                self.notify(title: dryRun ? "점검 미리보기 완료" : "점검 완료", body: self.summarize(out))
            }
        }
    }

    private func summarize(_ out: String) -> String {
        let lines = out.split(separator: "\n").map(String.init)
        let interesting = lines.filter {
            $0.contains("STUCK") || $0.contains("MENU") || $0.contains("WAIT") || $0.contains("OK ") || $0.contains("FAIL")
        }
        if let last = (interesting.last ?? lines.last(where: { $0.contains("점검 완료") })) {
            return String(last.dropFirst(min(20, last.count)))
        }
        return "결과를 읽지 못했습니다"
    }

    private func notify(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openLog() {
        let url = status.logFile ?? StatusReader.todayLogURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(Config.logsDir)
        }
    }

    @objc private func openFolder() { NSWorkspace.shared.open(Config.home) }

    @objc private func toggleAgent() {
        let uid = getuid()
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Config.label).plist").path
        if status.registered {
            shell("launchctl bootout gui/\(uid)/\(Config.label)")
        } else {
            shell("launchctl bootstrap gui/\(uid) '\(plist)'")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    /// 종료를 누르면 launchd 에서도 내려서 KeepAlive 가 되살리지 못하게 한다.
    /// plist 는 디스크에 그대로 남으므로 다음 로그인 때는 다시 뜬다.
    @objc private func quit() {
        shell("launchctl bootout gui/\(getuid())/\(Config.label)-menubar 2>/dev/null")
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
delegate.selfTest = CommandLine.arguments.contains("--selftest")
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
