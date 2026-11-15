import AppKit
import ApplicationServices

// AgentPill: a small always-on-top status pill.
// - Claude Code sessions report through hooks: pill-hook pipes each hook's JSON to a Unix socket.
// - Claude desktop chats have no hooks, so (with Accessibility permission) the app reads the
//   Claude window's text and looks for "needs your input" prompts.
// Neither path uses any model tokens.

let supportDir = NSHomeDirectory() + "/.agentpill"
let socketPath = supportDir + "/pill.sock"

// MARK: - Model

enum PillState: Int {
    case idle = 0, done, working, waiting   // raw value doubles as display priority

    var color: NSColor {
        switch self {
        case .idle: return NSColor(white: 1, alpha: 0.35)
        case .done: return NSColor(srgbRed: 0.30, green: 0.85, blue: 0.40, alpha: 1)
        case .working: return NSColor(srgbRed: 0.35, green: 0.68, blue: 1.0, alpha: 1)
        case .waiting: return NSColor(srgbRed: 1.0, green: 0.72, blue: 0.0, alpha: 1)
        }
    }

    var legend: String {
        switch self {
        case .idle: return "Idle"
        case .done: return "Done"
        case .working: return "Working"
        case .waiting: return "Needs you"
        }
    }
}

struct Session {
    var id: String
    var project = ""
    var title: String?          // the session's name, read from its transcript
    var label = ""              // title (or project folder), plus "#2" etc. when two rows would match
    var state = PillState.idle
    var text = "Ready"
    var created = Date()
    var updated = Date()
    var inFlight = 0            // tools started but not finished
    var thinkingAt: Date?       // when to fall back to "Thinking…" after a tool finishes
    var beforeCompact: (PillState, String)?
    var since = Date()          // when the current state + text began (the row's elapsed time)
    var appPID: pid_t?          // the app hosting this session (terminal, Claude desktop…)
    var appBundle: String?      // fallback when the process walk found nothing
    var hostSession: String?    // Claude desktop's id (local_...) when the session runs inside the Claude app

    var openable: Bool { appPID != nil || appBundle != nil || id.hasPrefix("chat:") }
}

/// "4m", "1h 5m"; nil under a minute (not worth the redraws) and for rows where it means nothing.
func elapsed(_ s: Session, now: Date = Date()) -> String? {
    guard s.state != .idle, !s.id.hasPrefix("_") else { return nil }
    let mins = Int(now.timeIntervalSince(s.since)) / 60
    guard mins >= 1 else { return nil }
    let span = mins < 60 ? "\(mins)m" : "\(mins / 60)h" + (mins % 60 == 0 ? "" : " \(mins % 60)m")
    return s.state == .done ? span + " ago" : span
}

func clean(_ s: String, max: Int = 120) -> String {
    let flat = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
}

/// If the final message ends by asking the user something, return that question.
func trailingQuestion(_ message: String) -> String? {
    let lines = message.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard var last = lines.last else { return nil }
    last = last.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
    guard last.hasSuffix("?") else { return nil }
    let body = last.dropLast()
    if let cut = body.lastIndex(where: { ".!?".contains($0) }) {
        let tail = body[body.index(after: cut)...].trimmingCharacters(in: .whitespaces)
        if tail.count > 12 { return tail + "?" }
    }
    return last
}

func describeTool(_ tool: String, _ input: [String: Any]) -> (text: String, waits: Bool) {
    func str(_ key: String) -> String { input[key] as? String ?? "" }
    func file(_ key: String = "file_path") -> String { (str(key) as NSString).lastPathComponent }
    switch tool {
    case "Bash":
        if !str("description").isEmpty { return (str("description"), false) }
        return (str("command").isEmpty ? "Running a command" : "Running " + str("command"), false)
    case "WebSearch": return ("Searching the web: " + str("query"), false)
    case "WebFetch": return ("Reading " + (URL(string: str("url"))?.host ?? "a web page"), false)
    case "Read": return ("Reading " + file(), false)
    case "Edit", "MultiEdit": return ("Editing " + file(), false)
    case "Write": return ("Writing " + file(), false)
    case "NotebookEdit": return ("Editing " + file("notebook_path"), false)
    case "Grep": return ("Searching for " + str("pattern"), false)
    case "Glob": return ("Finding files " + str("pattern"), false)
    case "Task", "Agent": return ("Subagent: " + str("description"), false)
    case "Skill": return ("Using skill " + str("skill"), false)
    case "TodoWrite", "TaskCreate", "TaskUpdate": return ("Updating task list", false)
    case "ExitPlanMode": return ("Plan ready for your review", true)
    case "AskUserQuestion":
        let first = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
        return (first ?? (str("question").isEmpty ? "Has a question for you" : str("question")), true)
    default:
        if tool.hasPrefix("mcp__") {
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            let name = (parts.last ?? tool).replacingOccurrences(of: "_", with: " ")
            return (parts.count > 1 ? "\(parts[0]): \(name)" : name, false)
        }
        return (tool, false)
    }
}

/// The session's name as Claude Code records it near the end of the transcript file.
func transcriptTitle(_ path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { handle.closeFile() }
    let size = handle.seekToEndOfFile()
    handle.seek(toFileOffset: size > 262_144 ? size - 262_144 : 0)
    let data = handle.readDataToEndOfFile()
    for key in ["\"customTitle\":\"", "\"aiTitle\":\"", "\"agentName\":\""] {
        guard let hit = data.range(of: Data(key.utf8), options: .backwards) else { continue }
        var end = hit.upperBound
        while end < data.endIndex, data[end] != 0x22 { end += data[end] == 0x5C ? 2 : 1 }
        guard end < data.endIndex else { continue }
        let fragment = data[(hit.upperBound - 1)...end]
        if let title = (try? JSONSerialization.jsonObject(with: fragment, options: .fragmentsAllowed)) as? String,
           !title.isEmpty {
            return title
        }
    }
    return nil
}

final class Store {
    enum Change { case none, now, later }

    private(set) var sessions: [String: Session] = [:]

    /// Most urgent first, labelled by session name (falling back to the project folder).
    var ordered: [Session] {
        var byName: [String: [Session]] = [:]
        for s in sessions.values {
            var name = s.title ?? s.project
            if name.count > 30 { name = String(name.prefix(29)) + "…" }
            byName[name, default: []].append(s)
        }
        var out: [Session] = []
        for (name, group) in byName {
            for (i, s) in group.sorted(by: { $0.created < $1.created }).enumerated() {
                var s = s
                s.label = group.count > 1 && !name.isEmpty ? "\(name) #\(i + 1)" : name
                out.append(s)
            }
        }
        return out.sorted {
            $0.state.rawValue != $1.state.rawValue ? $0.state.rawValue > $1.state.rawValue : $0.updated > $1.updated
        }
    }

    func setTitle(_ id: String, _ title: String) -> Bool {
        guard sessions[id] != nil, sessions[id]?.title != title else { return false }
        sessions[id]?.title = title
        return true
    }

    func remove(_ id: String) -> Bool { sessions.removeValue(forKey: id) != nil }

    func set(_ id: String, project: String = "", state: PillState, text: String) -> Bool {
        var s = sessions[id] ?? Session(id: id)
        if s.state == state, s.text == text, sessions[id] != nil {
            sessions[id]?.updated = Date()
            return false
        }
        s.project = project
        s.state = state
        s.text = text
        s.updated = Date()
        s.since = Date()
        sessions[id] = s
        return true
    }

    func clearAll() { sessions.removeAll() }

    func handle(_ e: [String: Any]) -> Change {
        guard let event = e["hook_event_name"] as? String else { return .none }
        let id = e["session_id"] as? String ?? "unknown"
        if event == "SessionEnd" { return remove(id) ? .now : .none }

        let isNew = sessions[id] == nil
        var s = sessions[id] ?? Session(id: id)
        let before = (s.state, s.text)
        if let cwd = e["cwd"] as? String, !cwd.isEmpty { s.project = (cwd as NSString).lastPathComponent }
        if let pid = e["_app"] as? Int { s.appPID = pid_t(pid) }
        if let bundle = e["_bundle"] as? String { s.appBundle = bundle }
        if let host = e["_host"] as? String { s.hostSession = host }
        let input = e["tool_input"] as? [String: Any] ?? [:]
        let tool = e["tool_name"] as? String ?? ""
        let agent = (e["agent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 + " › " } ?? ""
        let isPost = event == "PostToolUse" || event == "PostToolUseFailure"
        if !isPost { s.thinkingAt = nil }

        func set(_ state: PillState, _ text: String) {
            s.state = state
            s.text = clean(text)
        }

        switch event {
        case "SessionStart":
            if let saved = s.beforeCompact, e["source"] as? String == "compact" {
                set(saved.0, saved.1)
                s.beforeCompact = nil
            } else if !isNew {
                return .none
            }
        case "UserPromptSubmit":
            set(.working, "Thinking…")
            s.inFlight = 0
        case "PreToolUse":
            let d = describeTool(tool, input)
            set(d.waits ? .waiting : .working, agent + d.text)
            s.inFlight += 1
        case "PostToolUse", "PostToolUseFailure":
            s.inFlight = max(0, s.inFlight - 1)
            s.updated = Date()
            if s.inFlight == 0 {
                // Usually the next tool starts right away; only show "Thinking…" if it doesn't.
                s.thinkingAt = Date().addingTimeInterval(0.4)
                sessions[id] = s
                return .later
            }
            if s.state == .waiting { set(.working, "Working…") }
        case "PermissionRequest":
            set(.waiting, "Allow? " + describeTool(tool, input).text)
        case "Notification":
            let message = e["message"] as? String ?? "Needs your attention"
            switch e["notification_type"] as? String ?? "" {
            case "permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog":
                set(.waiting, message)
            case "idle_prompt":
                if s.state == .working { set(.waiting, message) } else { return .none }
            default:
                return .none
            }
        case "Stop":
            s.inFlight = 0
            if let q = trailingQuestion(e["last_assistant_message"] as? String ?? "") {
                set(.waiting, q)
            } else {
                set(.done, "Done")
            }
        case "StopFailure":
            s.inFlight = 0
            set(.waiting, "Stopped on an error")
        case "PreCompact":
            s.beforeCompact = (s.state, s.text)
            set(.working, "Compacting context…")
        case "Say":
            set(.working, e["message"] as? String ?? "")
        default:
            return .none
        }
        s.updated = Date()
        if before != (s.state, s.text) { s.since = Date() }
        sessions[id] = s
        return isNew || before != (s.state, s.text) ? .now : .none
    }

    func applyDeferred() -> Bool {
        var changed = false
        let now = Date().addingTimeInterval(0.05)
        for (id, s) in sessions {
            guard let at = s.thinkingAt, at <= now else { continue }
            sessions[id]?.thinkingAt = nil
            sessions[id]?.state = .working
            if s.text != "Thinking…" || s.state != .working { sessions[id]?.since = Date() }
            sessions[id]?.text = "Thinking…"
            changed = true
        }
        return changed
    }

    /// Ages out sessions that stopped reporting (e.g. interrupted with Escape, terminal closed).
    func sweep() -> Bool {
        var changed = false
        let now = Date()
        for (id, s) in sessions where !id.hasPrefix("_") {
            let age = now.timeIntervalSince(s.updated)
            switch s.state {
            case .working where age > (s.inFlight > 0 ? 1800 : 300):
                sessions[id]?.state = .idle
                sessions[id]?.text = "Idle"
                changed = true
            case .waiting where id.hasPrefix("chat:") && age > 600:
                sessions[id]?.state = .idle
                changed = true
            case .done where age > 600:
                sessions[id]?.state = .idle
                changed = true
            case .idle where age > 7200:
                sessions[id] = nil
                changed = true
            default:
                break
            }
        }
        return changed
    }
}

// MARK: - Socket server

func unixAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
            for (i, byte) in path.utf8CString.enumerated() where i < capacity - 1 { dst[i] = byte }
        }
    }
    return addr
}

func withSockaddr<T>(_ addr: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var a = addr
    return withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

/// pill-hook forwards only the first 64 KB of a payload, so big ones arrive cut off and are not
/// valid JSON. This pulls out every complete "key": "string" pair (first occurrence wins), which
/// is all the pill needs: the fields it reads come before any bulky content.
func lenientFields(_ data: Data) -> [String: Any]? {
    let bytes = [UInt8](data)
    var out: [String: Any] = [:]
    var key: String?
    var i = 0
    while i < bytes.count {
        let c = bytes[i]
        if c == 0x22 {
            var j = i + 1
            while j < bytes.count, bytes[j] != 0x22 { j += bytes[j] == 0x5C ? 2 : 1 }
            guard j < bytes.count else { break }
            let value = (try? JSONSerialization.jsonObject(with: Data(bytes[i...j]), options: .fragmentsAllowed)) as? String
            i = j + 1
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
            if i < bytes.count, bytes[i] == 0x3A {
                key = value
                i += 1
            } else {
                if let k = key, let v = value, out[k] == nil { out[k] = v }
                key = nil
            }
        } else {
            if c != 0x20 && c != 0x0A && c != 0x0D && c != 0x09 { key = nil }
            i += 1
        }
    }
    guard out["hook_event_name"] != nil else { return nil }
    out["tool_input"] = out
    return out
}

final class Server {
    private let queue = DispatchQueue(label: "agentpill.server")
    private var source: DispatchSourceRead?
    private let handler: ([String: Any]) -> Void

    init(handler: @escaping ([String: Any]) -> Void) { self.handler = handler }

    static func anotherInstanceIsRunning() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        return withSockaddr(unixAddress(socketPath)) { connect(fd, $0, $1) } == 0
    }

    func start() -> Bool {
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, withSockaddr(unixAddress(socketPath), { bind(fd, $0, $1) }) == 0, listen(fd, 32) == 0 else {
            return false
        }
        chmod(socketPath, 0o600)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            if client >= 0 { self?.read(client) }
        }
        src.resume()
        source = src
        return true
    }

    private func read(_ fd: Int32) {
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while data.count < 80_000 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        close(fd)
        // pill-hook puts "#key value" lines ahead of the JSON (see hook.c).
        var header: [String: String] = [:]
        while data.first == 0x23, let nl = data.firstIndex(of: 0x0A) {
            let line = String(decoding: data[data.startIndex..<nl], as: UTF8.self).dropFirst()
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { header[String(parts[0])] = String(parts[1]) }
            data = Data(data[data.index(after: nl)...])
        }
        guard !data.isEmpty else { return }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? lenientFields(data)
        guard var obj = parsed else { return }
        if let pids = header["pids"] { obj["_pids"] = pids.split(separator: " ").compactMap { Int32($0) } }
        if let bundle = header["bundle"] { obj["_bundle"] = bundle }
        if let host = header["host"] { obj["_host"] = host }
        DispatchQueue.main.async { self.handler(obj) }
    }
}

// MARK: - Claude desktop chat watcher (Accessibility)

/// What to look for in the Claude window. Every field can be overridden, without rebuilding,
/// in ~/.agentpill/chat-markers.json (same key names, arrays of strings).
struct ChatConfig {
    var waitingPrefix = ["Allow Claude to"]
    var waitingExact = ["Needs your input"]
    var workingExact = ["Claude is responding"]
    var skip: Set<String> = ["Chat messages"]   // subtrees not worth walking (the transcript)
    var codeSuffix = ["Claude Code"]            // window titles already covered by hooks

    init() {
        guard let data = FileManager.default.contents(atPath: supportDir + "/chat-markers.json"),
              let cfg = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String]] else { return }
        waitingPrefix = cfg["waitingPrefix"] ?? waitingPrefix
        waitingExact = cfg["waitingExact"] ?? waitingExact
        workingExact = cfg["workingExact"] ?? workingExact
        skip = cfg["skip"].map(Set.init) ?? skip
        codeSuffix = cfg["codeSuffix"] ?? codeSuffix
    }
}

func accessibilityWindows(pid: pid_t) -> [(element: AXUIElement, title: String)] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.4)
    // Electron apps only build their accessibility tree when asked.
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var windows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
          let list = windows as? [AXUIElement] else { return [] }
    return list.map { win in
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &title)
        return (win, title as? String ?? "")
    }
}

/// Collects the visible text under an element, in reading order.
func accessibilityStrings(root: AXUIElement, budget: Int, skip: Set<String>) -> [String] {
    let attrs = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute] as CFArray
    var out: [String] = []
    var remaining = budget

    func walk(_ element: AXUIElement, _ depth: Int) {
        guard remaining > 0, depth < 80 else { return }
        remaining -= 1
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attrs, AXCopyMultipleAttributeOptions(), &values) == .success,
              let v = values as? [Any], v.count == 4 else { return }
        for i in 0..<3 {
            guard let s = v[i] as? String, !s.isEmpty else { continue }
            if skip.contains(s) { return }
            if s.count < 400, out.last != s { out.append(s) }
        }
        if let children = v[3] as? [AXUIElement] { children.forEach { walk($0, depth + 1) } }
    }
    walk(root, 0)
    return out
}

func axString(_ e: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
    return v as? String
}

func axParent(_ e: AXUIElement) -> AXUIElement? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &v) == .success, let v else { return nil }
    return (v as! AXUIElement)
}

func axActions(_ e: AXUIElement) -> [String] {
    var v: CFArray?
    guard AXUIElementCopyActionNames(e, &v) == .success else { return [] }
    return v as? [String] ?? []
}

/// Elements under `root`, in reading order, whose title, description or value satisfies `match`.
func axFind(root: AXUIElement, budget: Int = 20000, limit: Int = 10, _ match: (String) -> Bool) -> [AXUIElement] {
    let attrs = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute] as CFArray
    var out: [AXUIElement] = []
    var remaining = budget
    func walk(_ e: AXUIElement, _ depth: Int) {
        guard remaining > 0, out.count < limit, depth < 80 else { return }
        remaining -= 1
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, attrs, AXCopyMultipleAttributeOptions(), &values) == .success,
              let v = values as? [Any], v.count == 4 else { return }
        if (0..<3).contains(where: { (v[$0] as? String).map(match) ?? false }) { out.append(e) }
        if let children = v[3] as? [AXUIElement] { children.forEach { walk($0, depth + 1) } }
    }
    walk(root, 0)
    return out
}

/// Addresses of the web pages in a window (Claude's UI is a web app; a chat's is https://claude.ai/chat/<id>).
func axWebURLs(_ win: AXUIElement, budget: Int = 3000) -> [String] {
    var out: [String] = []
    var remaining = budget
    func walk(_ e: AXUIElement, _ depth: Int) {
        guard remaining > 0, depth < 40 else { return }
        remaining -= 1
        if axString(e, "AXRole") == "AXWebArea" {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, "AXURL" as CFString, &v) == .success {
                if let url = v as? URL { out.append(url.absoluteString) } else if let s = v as? String { out.append(s) }
            }
            return      // don't descend into page content
        }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success,
              let children = kids as? [AXUIElement] else { return }
        children.forEach { walk($0, depth + 1) }
    }
    walk(win, 0)
    return out
}

/// Presses `e`, or the nearest ancestor that can be pressed (labels sit inside their buttons/links).
@discardableResult
func axPress(_ e: AXUIElement) -> Bool {
    var cur: AXUIElement? = e
    var first: AXUIElement?
    for _ in 0..<6 {
        guard let el = cur else { break }
        if axActions(el).contains(kAXPressAction as String) {
            if ["AXButton", "AXLink", "AXRadioButton", "AXMenuItem"].contains(axString(el, "AXRole") ?? "") {
                first = el
                break
            }
            if first == nil { first = el }
        }
        cur = axParent(el)
    }
    guard let target = first else { return false }
    return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
}

/// In the Claude desktop window: switch to `mode` ("Claude" for chats, "Code" for sessions), then
/// open the sidebar entry titled `title`. Returns false if the sidebar or the entry wasn't found
/// (sidebar hidden, or the chat has scrolled out of Recents). Call off the main thread.
@discardableResult
func openInClaude(pid: pid_t, mode: String, title: String) -> Bool {
    guard let win = accessibilityWindows(pid: pid).first?.element else { return false }
    func sidebar() -> AXUIElement? {
        axFind(root: win, budget: 4000, limit: 4) { $0 == "Sidebar" }
            .first { axString($0, "AXRole") == "AXGroup" }
    }
    guard var side = sidebar() else { return false }
    if let radio = axFind(root: side, budget: 400, limit: 4, { $0 == mode })
        .first(where: { axString($0, "AXRole") == "AXRadioButton" }) {
        var selected: CFTypeRef?
        AXUIElementCopyAttributeValue(radio, kAXValueAttribute as CFString, &selected)
        if (selected as? NSNumber)?.intValue != 1 {
            axPress(radio)
            Thread.sleep(forTimeInterval: 0.6)      // let the sidebar re-render for the new mode
            side = sidebar() ?? side
        }
    }
    guard let entry = axFind(root: side, budget: 6000, limit: 1, { $0 == title }).first else { return false }
    return axPress(entry)
}

struct ChatStatus {
    var title: String
    var state: PillState?   // nil = the chat is open but neither working nor waiting
    var text: String
    var chatID: String?     // from the page address (https://claude.ai/chat/<id>), when readable
}

/// The conversation id in a claude.ai chat address.
func chatID(fromURL url: String) -> String? {
    guard let r = url.range(of: #"/chat/[0-9a-fA-F-]{36}"#, options: .regularExpression) else { return nil }
    return String(url[r].dropFirst(6))
}

final class ChatWatcher {
    static let bundleID = "com.anthropic.claudefordesktop"

    private let config = ChatConfig()
    private let queue = DispatchQueue(label: "agentpill.chat", qos: .utility)
    private var timer: Timer?
    private var busy = false
    private var lastDump = Date.distantPast
    private let report: (ChatStatus?) -> Void

    init(report: @escaping (ChatStatus?) -> Void) { self.report = report }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        let t = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 2
        timer = t
    }

    private func tick() {
        guard ChatWatcher.trusted, !busy,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: ChatWatcher.bundleID).first
        else { return }
        busy = true
        let pid = app.processIdentifier
        queue.async {
            var status: ChatStatus?
            // Code-tab windows report through hooks already; only chat windows need reading.
            let chats = accessibilityWindows(pid: pid).filter { win in
                !win.title.isEmpty && !self.config.codeSuffix.contains(where: { win.title.hasSuffix($0) })
            }
            if let win = chats.first {
                let strings = accessibilityStrings(root: win.element, budget: 8000, skip: self.config.skip)
                // The Code tab's window is also titled "Claude"; its real title is one of the first strings.
                let isCode = strings.prefix(6).contains { str in self.config.codeSuffix.contains(where: { str.hasSuffix($0) }) }
                status = isCode ? nil : self.classify(title: win.title, strings)
                if status != nil { status?.chatID = axWebURLs(win.element).lazy.compactMap(chatID(fromURL:)).first }
                self.debugDump(win)
            }
            DispatchQueue.main.async {
                self.busy = false
                self.report(status)
            }
        }
    }

    func classify(title: String, _ strings: [String]) -> ChatStatus {
        // The window itself is just "Claude"; the chat's own title ("Name - Claude") is one of the first strings.
        let suffixes = [" - Claude", " – Claude", " — Claude"]
        var name = strings.prefix(6).first { str in suffixes.contains { str.hasSuffix($0) } } ?? title
        for suffix in [" - Claude", " – Claude", " — Claude"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        if name.isEmpty || name == "Claude" { name = "Claude chat" }

        for (i, s) in strings.enumerated() where config.waitingPrefix.contains(where: { s.hasPrefix($0) }) {
            var text = s
            var j = i + 1
            while !text.contains("?"), j < strings.count, j <= i + 3 {
                text += " " + strings[j]
                j += 1
            }
            if let end = text.firstIndex(of: "?") { text = String(text[...end]) }
            return ChatStatus(title: name, state: .waiting, text: clean(text))
        }
        if let s = strings.first(where: { config.waitingExact.contains($0) }) {
            return ChatStatus(title: name, state: .waiting, text: s)
        }
        if strings.contains(where: { config.workingExact.contains($0) }) {
            return ChatStatus(title: name, state: .working, text: "Responding…")
        }
        return ChatStatus(title: name, state: nil, text: "")
    }

    /// With ~/.agentpill/debug present, keeps the latest chat window text in chat-dump.txt for tuning.
    private func debugDump(_ win: (element: AXUIElement, title: String)) {
        guard Date().timeIntervalSince(lastDump) > 60,
              FileManager.default.fileExists(atPath: supportDir + "/debug") else { return }
        lastDump = Date()
        let start = Date()
        let all = accessibilityStrings(root: win.element, budget: 20000, skip: [])
        let head = "title=\(win.title) nodes=\(all.count) ms=\(Int(Date().timeIntervalSince(start) * 1000))"
        try? ([head] + all).joined(separator: "\n")
            .write(toFile: supportDir + "/chat-dump.txt", atomically: true, encoding: .utf8)
    }
}

// MARK: - Claude Code hook installer

enum Installer {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                         "PermissionRequest", "Notification", "Stop", "StopFailure", "PreCompact", "SessionEnd"]
    static let claudeDir = NSHomeDirectory() + "/.claude"
    static let settingsPath = claudeDir + "/settings.json"
    static let backupPath = claudeDir + "/settings.json.agentpill-backup"

    enum Result { case unchanged, installed, failed(String) }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            ($0["command"] as? String ?? "").hasSuffix("/pill-hook")
        }
    }

    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return [:] }
        guard let data = FileManager.default.contents(atPath: settingsPath) else { return nil }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func save(_ root: [String: Any]) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: settingsPath), !fm.fileExists(atPath: backupPath) {
            try? fm.copyItem(atPath: settingsPath, toPath: backupPath)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)) != nil
    }

    /// Adds (or repairs) our hooks in ~/.claude/settings.json, leaving every other setting and hook alone.
    static func install(hookPath: String) -> Result {
        guard FileManager.default.fileExists(atPath: claudeDir) else { return .failed("Claude Code not found") }
        guard let original = load() else { return .failed("Couldn't read Claude settings") }
        var root = original
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let ours: [String: Any] = ["hooks": [[
            "type": "command", "command": hookPath, "args": ["hook"], "async": true, "timeout": 5,
        ] as [String: Any]]]
        for event in events {
            if hooks[event] != nil, !(hooks[event] is [[String: Any]]) { continue }
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            groups.append(ours)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        if NSDictionary(dictionary: root).isEqual(to: original) { return .unchanged }
        return save(root) ? .installed : .failed("Couldn't write Claude settings")
    }

    static func uninstall() {
        guard let original = load(), var hooks = original["hooks"] as? [String: Any] else { return }
        var root = original
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        if !NSDictionary(dictionary: root).isEqual(to: original) { _ = save(root) }
    }
}

enum LoginItem {
    static let path = NSHomeDirectory() + "/Library/LaunchAgents/com.local.agentpill.plist"
    static var enabled: Bool { FileManager.default.fileExists(atPath: path) }

    static func set(_ on: Bool) {
        guard on, let exe = Bundle.main.executablePath else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let plist: [String: Any] = ["Label": "com.local.agentpill", "ProgramArguments": [exe], "RunAtLoad": true]
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        (plist as NSDictionary).write(toFile: path, atomically: true)
    }
}

// MARK: - View

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
    return base
}

/// The pill itself. The view is larger than the visible shape by `margin` so the glow has room.
final class PillView: NSView {
    var rows: [Session] = []
    var expanded = false
    var docked = true               // attached to the top edge (notch shape) vs floating (capsule)
    var barHeight: CGFloat = 24
    var onHover: ((Bool) -> Void)?
    var onDrag: ((NSPoint?) -> Void)?   // offset from drag start; nil when the drag ends
    var menuProvider: (() -> NSMenu)?
    var onDismiss: ((String) -> Void)?  // "viewed" tick clicked on a finished row
    var onOpen: ((String) -> Void)?     // anywhere else on a row: bring that session's app forward

    let margin: CGFloat = 16
    private let ear: CGFloat = 9
    private let padX: CGFloat = 14, mark: CGFloat = 14, gap: CGFloat = 8, rowHeight: CGFloat = 24
    private let checkWidth: CGFloat = 24
    private let nameFont = roundedFont(11.5, .semibold)
    private let textFont = roundedFont(12.5, .medium)

    private var marks: [CAShapeLayer] = []      // one animated status mark per visible row
    private let edge = CAGradientLayer()        // light running along the bottom edge
    private var edgeKey = ""
    private var checkRects: [(rect: NSRect, id: String)] = []
    private var rowRects: [(rect: NSRect, id: String)] = []
    private var hoverRow: String?
    private var dragStart: NSPoint?
    private var dragMoved = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        edge.startPoint = CGPoint(x: 0, y: 0.5)
        edge.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(edge)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Geometry

    private var firstRowHeight: CGFloat { docked ? barHeight : 30 }
    private var topInset: CGFloat { docked ? 0 : margin }
    private var pillRect: NSRect {
        NSRect(x: margin, y: topInset, width: bounds.width - margin * 2, height: bounds.height - margin - topInset)
    }
    private var radius: CGFloat { docked ? 14 : min(15, pillRect.height / 2) }

    private func dismissible(_ s: Session) -> Bool { s.state == .done || s.state == .idle }

    /// Collapsed: one line per agent that is working or waiting (up to 4). Expanded: everything.
    private var visible: [Session] {
        if expanded { return rows }
        let active = rows.filter { $0.state == .working || $0.state == .waiting }
        return Array((active.isEmpty ? rows : active).prefix(active.isEmpty ? 1 : 4))
    }

    private var extras: [Session] { expanded ? [] : Array(rows.dropFirst(visible.count).prefix(5)) }
    private var extrasWidth: CGFloat { extras.isEmpty ? 0 : CGFloat(extras.count) * 10 + 6 }

    private func rowTop(_ i: Int) -> CGFloat { topInset + (i == 0 ? 0 : firstRowHeight + CGFloat(i - 1) * rowHeight) }
    private func rowHeight(_ i: Int) -> CGFloat { i == 0 ? firstRowHeight : rowHeight }

    private func label(_ s: Session) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if !s.label.isEmpty {
            out.append(NSAttributedString(string: s.label + "  ", attributes: [
                .font: nameFont, .foregroundColor: NSColor(white: 1, alpha: 0.5), .kern: 0.1]))
        }
        out.append(NSAttributedString(string: s.text, attributes: [
            .font: textFont, .foregroundColor: NSColor(white: 1, alpha: 0.96)]))
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// " · 4m", drawn after the label and never truncated away.
    private func timeLabel(_ s: Session) -> NSAttributedString? {
        elapsed(s).map { NSAttributedString(string: "  ·  " + $0, attributes: [
            .font: nameFont, .foregroundColor: NSColor(white: 1, alpha: 0.45)]) }
    }

    /// Size of the whole view, glow margin included.
    var preferredSize: NSSize {
        let shown = visible
        let widest = shown.map { s -> CGFloat in
            min(ceil(label(s).size().width), expanded ? 520 : 340) + ceil(timeLabel(s)?.size().width ?? 0)
        }.max() ?? 0
        var width = padX * 2 + mark + gap + widest + extrasWidth
        if shown.contains(where: dismissible) { width += checkWidth }
        width = (width / 16).rounded(.up) * 16     // fewer resizes as the text changes
        let more = CGFloat(max(shown.count - 1, 0))
        let height = firstRowHeight + more * rowHeight + (more > 0 ? 8 : 0)
        return NSSize(width: width + margin * 2, height: height + margin + topInset)
    }

    // MARK: Animated layers

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeEdge()
    }

    private func placeEdge() {
        let p = pillRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.frame = NSRect(x: p.minX + radius, y: p.maxY - 1.5, width: max(p.width - radius * 2, 0), height: 1.5)
        CATransaction.commit()
    }

    /// Call after changing rows / expanded / docked / size.
    func refresh() {
        let shown = visible
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while marks.count < shown.count {
            let m = CAShapeLayer()
            m.bounds = CGRect(x: 0, y: 0, width: mark, height: mark)
            layer?.addSublayer(m)
            marks.append(m)
        }
        for (i, m) in marks.enumerated() {
            guard i < shown.count else {
                m.isHidden = true
                m.name = nil
                m.removeAllAnimations()
                continue
            }
            let s = shown[i]
            m.isHidden = false
            m.position = CGPoint(x: margin + padX + mark / 2, y: rowTop(i) + rowHeight(i) / 2)
            // Restart the animation only when this row's session or state actually changed.
            let key = s.id + "|\(s.state.rawValue)" + (s.state == .waiting ? s.text : "")
            if m.name != key {
                m.name = key
                style(m, s.state)
            }
        }
        CATransaction.commit()
        placeEdge()
        styleEdge(rows.first?.state ?? .idle)
        needsDisplay = true
    }

    private func style(_ m: CAShapeLayer, _ state: PillState) {
        m.removeAllAnimations()
        let c = mark / 2
        let color = state.color.cgColor
        m.shadowColor = color
        m.shadowOffset = .zero
        m.shadowRadius = 4
        m.lineCap = .round
        switch state {
        case .working:      // spinning arc
            m.path = CGPath(ellipseIn: CGRect(x: c - 5, y: c - 5, width: 10, height: 10), transform: nil)
            m.fillColor = nil
            m.strokeColor = color
            m.lineWidth = 2
            m.strokeStart = 0
            m.strokeEnd = 0.72
            m.shadowOpacity = 0.7
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 0.9
            spin.repeatCount = .infinity
            m.add(spin, forKey: "spin")
        case .waiting:      // glowing dot that pulses for a few seconds, then holds
            m.path = CGPath(ellipseIn: CGRect(x: c - 4.5, y: c - 4.5, width: 9, height: 9), transform: nil)
            m.fillColor = color
            m.strokeColor = nil
            m.strokeEnd = 1
            m.shadowOpacity = 1
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.0
            pulse.toValue = 0.55
            pulse.duration = 0.55
            pulse.autoreverses = true
            pulse.repeatCount = 11
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            m.add(pulse, forKey: "pulse")
        case .done:
            m.path = CGPath(ellipseIn: CGRect(x: c - 4, y: c - 4, width: 8, height: 8), transform: nil)
            m.fillColor = color
            m.strokeColor = nil
            m.strokeEnd = 1
            m.shadowOpacity = 0.8
        case .idle:
            m.path = CGPath(ellipseIn: CGRect(x: c - 3.5, y: c - 3.5, width: 7, height: 7), transform: nil)
            m.fillColor = nil
            m.strokeColor = color
            m.lineWidth = 1.5
            m.strokeEnd = 1
            m.shadowOpacity = 0
        }
    }

    private func styleEdge(_ state: PillState) {
        let key = "\(state.rawValue)" + (state == .waiting ? rows.first?.text ?? "" : "")
        guard key != edgeKey else { return }
        edgeKey = key
        edge.removeAllAnimations()
        let c = state.color.cgColor
        let clear = state.color.withAlphaComponent(0).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.isHidden = state == .idle
        edge.opacity = 1
        switch state {
        case .working:      // a light sweeping along the bottom edge
            edge.colors = [clear, c, clear]
            edge.locations = [-0.4, -0.2, 0.0]
            let sweep = CABasicAnimation(keyPath: "locations")
            sweep.fromValue = [-0.4, -0.2, 0.0]
            sweep.toValue = [1.0, 1.2, 1.4]
            sweep.duration = 1.8
            sweep.repeatCount = .infinity
            edge.add(sweep, forKey: "sweep")
        case .waiting:
            edge.colors = [clear, c, c, clear]
            edge.locations = [0, 0.25, 0.75, 1]
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.2
            pulse.duration = 0.55
            pulse.autoreverses = true
            pulse.repeatCount = 11
            edge.add(pulse, forKey: "pulse")
        case .done:
            edge.colors = [clear, c, c, clear]
            edge.locations = [0, 0.3, 0.7, 1]
            edge.opacity = 0.7
        case .idle:
            break
        }
        CATransaction.commit()
    }

    // MARK: Drawing

    private func shape() -> NSBezierPath {
        let p = pillRect
        guard docked else { return NSBezierPath(roundedRect: p, xRadius: radius, yRadius: radius) }
        // Notch: flush with the top of the screen, flaring out into it with small curved ears.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: p.minX - ear, y: 0))
        path.line(to: NSPoint(x: p.maxX + ear, y: 0))
        path.curve(to: NSPoint(x: p.maxX, y: ear),
                   controlPoint1: NSPoint(x: p.maxX + ear * 0.35, y: 0), controlPoint2: NSPoint(x: p.maxX, y: ear * 0.35))
        path.appendArc(from: NSPoint(x: p.maxX, y: p.maxY), to: NSPoint(x: p.minX, y: p.maxY), radius: radius)
        path.appendArc(from: NSPoint(x: p.minX, y: p.maxY), to: NSPoint(x: p.minX, y: ear), radius: radius)
        path.line(to: NSPoint(x: p.minX, y: ear))
        path.curve(to: NSPoint(x: p.minX - ear, y: 0),
                   controlPoint1: NSPoint(x: p.minX, y: ear * 0.35), controlPoint2: NSPoint(x: p.minX - ear * 0.35, y: 0))
        path.close()
        return path
    }

    /// The elapsed-time strings currently on screen; the app redraws when they change.
    var elapsedKey: String { visible.map { elapsed($0) ?? "" }.joined(separator: "|") }

    override func draw(_ dirtyRect: NSRect) {
        checkRects.removeAll()
        rowRects.removeAll()
        guard !rows.isEmpty else { return }
        let p = pillRect
        let path = shape()
        let top = rows[0].state

        // Glow in the colour of the most urgent agent, then the body on top of it.
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = top == .idle ? NSColor(white: 0, alpha: 0.45)
                                        : top.color.withAlphaComponent(top == .waiting ? 0.75 : 0.5)
        glow.shadowBlurRadius = 13
        glow.shadowOffset = NSSize(width: 0, height: -2)
        glow.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [NSColor.black, NSColor(srgbRed: 0.075, green: 0.075, blue: 0.09, alpha: 1)])?
            .draw(in: NSRect(x: p.minX - ear, y: 0, width: p.width + ear * 2, height: p.maxY), angle: 90)
        NSColor(white: 1, alpha: 0.13).setStroke()
        path.lineWidth = 2      // half of it is clipped away, leaving a hairline inside the edge
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let shown = visible
        let textX = p.minX + padX + mark + gap
        let firstCheck = shown.first.map(dismissible) == true ? checkWidth : 0
        for (i, s) in shown.enumerated() {
            let y = rowTop(i), h = rowHeight(i)
            if s.openable {
                let r = NSRect(x: p.minX + 4, y: y + (i == 0 && docked ? 2 : 1) + (i == 1 ? 1.5 : 0),
                               width: p.width - 8, height: h - (i == 0 && docked ? 3 : 2))
                rowRects.append((r, s.id))
                if expanded, hoverRow == s.id {
                    NSColor(white: 1, alpha: 0.08).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
                }
            }
            if expanded, i > 0 {
                NSColor(white: 1, alpha: 0.07).setFill()
                NSRect(x: textX, y: y + (i == 1 ? 3 : 0), width: p.maxX - padX - textX, height: 1).fill()
            }
            var trailing = i == 0 ? extrasWidth : 0
            if dismissible(s) {
                // "Viewed" tick: click to clear this finished row.
                trailing += checkWidth
                let r = NSRect(x: p.maxX - padX - 15 + 3, y: y + (h - 15) / 2 + (i == 1 ? 1.5 : 0), width: 15, height: 15)
                NSColor(white: 1, alpha: 0.12).setFill()
                NSBezierPath(ovalIn: r).fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: r.minX + 4.4, y: r.minY + 7.8))
                tick.line(to: NSPoint(x: r.minX + 6.6, y: r.minY + 10))
                tick.line(to: NSPoint(x: r.minX + 10.6, y: r.minY + 5.2))
                tick.lineWidth = 1.4
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                NSColor(white: 1, alpha: 0.8).setStroke()
                tick.stroke()
                checkRects.append((r, s.id))
            }
            let text = label(s)
            let textHeight = ceil(text.size().height)
            let ty = y + (h - textHeight) / 2 + (i == 1 ? 1.5 : 0)
            let room = p.maxX - padX - textX - trailing
            let time = timeLabel(s)
            let timeWidth = ceil(time?.size().width ?? 0)
            let textWidth = min(ceil(text.size().width), room - timeWidth)
            text.draw(with: NSRect(x: textX, y: ty, width: textWidth, height: textHeight),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if let time {
                let timeHeight = ceil(time.size().height)
                time.draw(with: NSRect(x: textX + textWidth, y: ty + (textHeight - timeHeight) / 2 + 0.5,
                                       width: timeWidth, height: timeHeight),
                          options: [.usesLineFragmentOrigin])
            }
        }
        for (i, s) in extras.enumerated() {
            s.state.color.setFill()
            let x = p.maxX - padX - firstCheck - CGFloat(extras.count - i) * 10 + 4
            NSBezierPath(ovalIn: NSRect(x: x, y: topInset + (firstRowHeight - 6) / 2, width: 6, height: 6)).fill()
        }
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) { if dragStart == nil { onHover?(true) } }
    override func mouseExited(with event: NSEvent) {
        setHover(nil)
        if dragStart == nil { onHover?(false) }
    }
    override func mouseMoved(with event: NSEvent) {
        guard dragStart == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let onTick = checkRects.contains { $0.rect.insetBy(dx: -5, dy: -5).contains(p) }
        setHover(onTick ? nil : rowRects.first { $0.rect.contains(p) }?.id)
    }
    private func setHover(_ id: String?) {
        guard hoverRow != id else { return }
        hoverRow = id
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        dragMoved = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        if !dragMoved, abs(now.x - start.x) < 3, abs(now.y - start.y) < 3 { return }
        dragMoved = true
        onDrag?(NSPoint(x: now.x - start.x, y: now.y - start.y))
    }
    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        if dragMoved {
            onDrag?(nil)
        } else {
            let p = convert(event.locationInWindow, from: nil)
            if let hit = checkRects.first(where: { $0.rect.insetBy(dx: -5, dy: -5).contains(p) }) {
                onDismiss?(hit.id)
            } else if let hit = rowRects.first(where: { $0.rect.contains(p) }) {
                onOpen?(hit.id)
            }
        }
        // Hover changes were ignored during the drag; settle on where the pointer is now.
        if let window { onHover?(window.frame.contains(NSEvent.mouseLocation)) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Always in the menu bar; the pill joins it while agents are working or recently finished.
    private var statusItem: NSStatusItem!

    private let store = Store()
    private let defaults = UserDefaults.standard
    private var server: Server?
    private var watcher: ChatWatcher?
    private var panel: PillPanel!
    private var view: PillView!
    private var sweepTimer: Timer?
    private var clockTimer: Timer?
    private var chatIDs: [String: String] = [:]     // chat title -> conversation id, as seen by the watcher
    private var layoutPending = false
    private var titleChecked: [String: Date] = [:]
    private var history: [String: Session] = [:]    // last known state of recent sessions, for the menu
    private var lastStates: [String: PillState] = [:]  // to spot rows that just started waiting / finished
    private var lastAlert = Date.distantPast

    /// Top-centre of the pill in screen coordinates; nil = default (top-centre of the main screen).
    private var anchor: NSPoint?
    private var dragOrigin: NSPoint?

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["chimeWaiting": true, "chimeDone": false])
        if Server.anotherInstanceIsRunning() { exit(0) }
        if defaults.object(forKey: "anchorX") != nil {
            anchor = NSPoint(x: defaults.double(forKey: "anchorX"), y: defaults.double(forKey: "anchorY"))
        }

        view = PillView(frame: .zero)
        view.onHover = { [weak self] inside in
            guard let self, self.view.expanded != inside else { return }
            self.view.expanded = inside
            self.layout(animated: true)
        }
        view.onDrag = { [weak self] offset in self?.drag(offset) }
        view.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        view.onDismiss = { [weak self] id in
            guard let self, self.store.remove(id) else { return }
            self.titleChecked[id] = nil
            self.changed()
        }
        view.onOpen = { [weak self] id in
            guard let self, let s = self.store.sessions[id] else { return }
            self.focus(s)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "AgentPill"
        statusItem.isVisible = true     // an earlier version hid it, and macOS remembers that
        let icon = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "AgentPill")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "AgentPill"
        let statusMenu = NSMenu()
        statusMenu.delegate = self
        statusItem.menu = statusMenu

        panel = PillPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = view
        layout(animated: false)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.layout(animated: false)
        }
        // .canJoinAllSpaces alone doesn't carry the panel into full-screen Spaces created or entered
        // after it was shown; re-ordering it on every Space or app switch does.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.panel.isVisible else { return }
                self.panel.orderFrontRegardless()
            }
        }

        let server = Server { [weak self] event in self?.receive(event) }
        self.server = server
        if !server.start() {
            notice(.waiting, "Couldn't open " + socketPath, seconds: 30)
            return
        }

        let testing = ProcessInfo.processInfo.environment["AGENTPILL_NO_INSTALL"] != nil
        let hookPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pill-hook").path
        if !testing, FileManager.default.isExecutableFile(atPath: hookPath) {
            switch Installer.install(hookPath: hookPath) {
            case .installed: notice(.done, "Connected to Claude Code", seconds: 8)
            case .failed(let why): notice(.waiting, why, seconds: 30)
            case .unchanged: break
            }
        }

        let watcher = ChatWatcher { [weak self] status in
            guard let self, let status else { return }
            if let cid = status.chatID, status.title != "Claude chat" { self.chatIDs[status.title] = cid }
            let id = "chat:" + status.title
            var changed = false
            if let state = status.state {
                changed = self.store.set(id, project: status.title, state: state, text: status.text)
            } else if let s = self.store.sessions[id], s.state == .working || s.state == .waiting {
                changed = self.store.set(id, project: status.title, state: .done, text: "Done")
            }
            if changed { self.changed() }
        }
        self.watcher = watcher
        watcher.start()
        if !testing, !ChatWatcher.trusted, !defaults.bool(forKey: "askedAccessibility") {
            defaults.set(true, forKey: "askedAccessibility")
            ChatWatcher.requestAccess()
        }
    }

    private func receive(_ event: [String: Any]) {
        switch event["hook_event_name"] as? String {
        case "_Snapshot": snapshot(event)
        case "_ChatDump": chatDump(event)
        case "_AXProbe": axProbe(event)
        case "_Click":  // debug aid: {"hook_event_name":"_Click","label":"<row label>"} runs a row click
            if let label = event["label"] as? String, let s = store.ordered.first(where: { $0.label == label }) { focus(s) }
        case "_Open":   // debug aid: {"hook_event_name":"_Open","path":..,"mode":"Code","title":".."}
            guard let path = event["path"] as? String, let mode = event["mode"] as? String,
                  let title = event["title"] as? String,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: ChatWatcher.bundleID).first
            else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = openInClaude(pid: app.processIdentifier, mode: mode, title: title)
                try? "opened=\(ok)".write(toFile: path, atomically: true, encoding: .utf8)
            }
        default:
            refreshTitle(event)
            var event = event
            if let pids = event["_pids"] as? [Int32], let app = hostApp(pids) {
                event["_app"] = Int(app.processIdentifier)
            }
            switch store.handle(event) {
            case .now: changed()
            case .later:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
                    guard let self, self.store.applyDeferred() else { return }
                    self.changed()
                }
            case .none: break
            }
        }
    }

    /// Looks up the session's name off the main thread; re-checks now and then since names can change.
    private func refreshTitle(_ event: [String: Any]) {
        guard let id = event["session_id"] as? String, let path = event["transcript_path"] as? String else { return }
        let hasTitle = store.sessions[id]?.title != nil
        guard Date().timeIntervalSince(titleChecked[id] ?? .distantPast) > (hasTitle ? 30 : 4) else { return }
        titleChecked[id] = Date()
        DispatchQueue.global(qos: .utility).async {
            guard let title = transcriptTitle(path) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.store.setTitle(id, title) else { return }
                self.changed()
            }
        }
    }

    /// Debug aid: {"hook_event_name":"_Snapshot","path":"/tmp/x.png","expanded":true,"anchor":[x,y]}
    private func snapshot(_ event: [String: Any]) {
        guard let path = event["path"] as? String else { return }
        let savedAnchor = anchor
        if let a = event["anchor"] as? [Double], a.count == 2 { anchor = NSPoint(x: a[0], y: a[1]) }
        view.expanded = event["expanded"] as? Bool ?? false
        layout(animated: false)
        view.displayIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        let info = "frame=\(panel.frame) docked=\(view.docked) trusted=\(ChatWatcher.trusted) "
            + "pill=\(panel.isVisible) icon=\(statusItem.isVisible)\n"
            + store.ordered.map { "row \($0.label) | \($0.text) | app=\($0.appPID.map(String.init) ?? "-") "
                + "bundle=\($0.appBundle ?? "-") host=\($0.hostSession ?? "-") elapsed=\(elapsed($0) ?? "-")\n" }.joined()
        try? info.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        view.expanded = false
        anchor = savedAnchor
        layout(animated: false)
    }

    /// Debug aid: {"hook_event_name":"_ChatDump","path":"/tmp/x.txt"} writes every Claude window's text.
    /// Debug aid: {"hook_event_name":"_AXProbe","path":"/tmp/x.txt","text":"Some label"} lists every
    /// element in the Claude window labelled exactly `text`, with role, actions and ancestors.
    private func axProbe(_ event: [String: Any]) {
        guard let path = event["path"] as? String, let text = event["text"] as? String,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: ChatWatcher.bundleID).first
        else { return }
        DispatchQueue.global(qos: .utility).async {
            var lines: [String] = []
            for win in accessibilityWindows(pid: app.processIdentifier) {
                for e in axFind(root: win.element, { $0 == text }) {
                    var chain: [String] = []
                    var cur: AXUIElement? = e
                    for _ in 0..<5 {
                        guard let el = cur else { break }
                        chain.append("\(axString(el, "AXRole") ?? "?")/\(axString(el, "AXSubrole") ?? "-")"
                            + " t=\(axString(el, "AXTitle") ?? "") d=\(axString(el, "AXDescription") ?? "")"
                            + " actions=\(axActions(el).joined(separator: ","))")
                        cur = axParent(el)
                    }
                    lines.append(chain.joined(separator: "\n    ^ "))
                }
            }
            try? lines.joined(separator: "\n\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func chatDump(_ event: [String: Any]) {
        guard let path = event["path"] as? String else { return }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: ChatWatcher.bundleID).first
        let trusted = ChatWatcher.trusted
        DispatchQueue.global(qos: .utility).async {
            var lines = ["trusted=\(trusted) app=\(app?.processIdentifier ?? -1)"]
            if trusted, let app {
                for win in accessibilityWindows(pid: app.processIdentifier) {
                    lines.append("=== window: \(win.title)")
                    lines += axWebURLs(win.element).map { "url: " + $0 }
                    lines += accessibilityStrings(root: win.element, budget: 20000, skip: [])
                }
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func notice(_ state: PillState, _ text: String, seconds: TimeInterval) {
        _ = store.set("_notice", state: state, text: text)
        changed()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.store.remove("_notice") else { return }
            self.changed()
        }
    }

    /// Coalesces bursts of events (parallel tool calls) into one redraw.
    private func changed() {
        guard !layoutPending else { return }
        layoutPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.layoutPending = false
            self.layout(animated: true)
            self.updateSweepTimer()
        }
    }

    /// The first ancestor of the hook that is a regular (Dock) app: the terminal, editor or Claude app.
    private func hostApp(_ pids: [Int32]) -> NSRunningApplication? {
        for pid in pids {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
        }
        return nil
    }

    /// Brings the app running this session to the front, then (with Accessibility) raises the
    /// window whose title mentions the session, since terminals and Claude title windows that way.
    private func focus(_ s: Session) {
        var app = s.appPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        if app == nil || app?.isTerminated == true {
            let bundle = s.id.hasPrefix("chat:") ? ChatWatcher.bundleID : s.appBundle
            app = bundle.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        }
        guard let app else { NSSound.beep(); return }

        let pid = app.processIdentifier
        let isChat = s.id.hasPrefix("chat:")
        let inClaude = app.bundleIdentifier == ChatWatcher.bundleID
        let title = (isChat ? s.project : s.title) ?? ""

        // Claude desktop links straight to a session or chat; these work with the sidebar hidden too.
        if inClaude, let host = s.hostSession, let url = URL(string: "claude://code/continue?session=" + host) {
            NSWorkspace.shared.open(url)
            return
        }
        if isChat, let cid = chatIDs[title], let url = URL(string: "claude://claude.ai/chat/" + cid) {
            NSWorkspace.shared.open(url)
            return
        }

        let hints = [s.title, isChat ? s.project : nil].compactMap { $0 }.filter { !$0.isEmpty }
        // The app may need to switch Spaces first; Accessibility can't see windows on other Spaces.
        let delay = 0.6
        if ChatWatcher.trusted, inClaude, !title.isEmpty, title != "Claude chat" {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                // Sidebar first; if it's collapsed, the chat can still be found on the Recents page.
                if openInClaude(pid: pid, mode: isChat ? "Claude" : "Code", title: title) || !isChat { return }
                DispatchQueue.main.async { NSWorkspace.shared.open(URL(string: "claude://claude.ai/recents")!) }
                Thread.sleep(forTimeInterval: 1.2)
                if let win = accessibilityWindows(pid: pid).first?.element,
                   let entry = axFind(root: win, budget: 12000, limit: 1, { $0 == title }).first {
                    axPress(entry)
                }
            }
        } else if ChatWatcher.trusted, !hints.isEmpty {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                let wins = accessibilityWindows(pid: pid)
                if let win = wins.first(where: { w in hints.contains { w.title.localizedCaseInsensitiveContains($0) } }) {
                    AXUIElementSetAttributeValue(win.element, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementPerformAction(win.element, kAXRaiseAction as CFString)
                }
            }
        }
        // A background app's activate() request can be declined; opening the app always comes forward.
        app.activate(options: [])
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }

    private func updateSweepTimer() {
        if store.sessions.isEmpty {
            clockTimer?.invalidate()
            clockTimer = nil
        } else if clockTimer == nil {
            // Elapsed times tick in minutes; redraw only when one of the visible ones changes.
            var lastKey = view.elapsedKey
            let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                guard let self, self.panel.isVisible else { return }
                let key = self.view.elapsedKey
                guard key != lastKey else { return }
                lastKey = key
                self.layout(animated: true)
            }
            timer.tolerance = 5
            clockTimer = timer
        }
        if store.sessions.isEmpty {
            sweepTimer?.invalidate()
            sweepTimer = nil
        } else if sweepTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                guard let self, self.store.sweep() else { return }
                self.changed()
            }
            timer.tolerance = 30
            sweepTimer = timer
        }
    }

    private func drag(_ offset: NSPoint?) {
        guard let offset else {
            // Drag ended: remember where the pill actually landed (it may have been clamped or snapped).
            dragOrigin = nil
            if let a = anchor, let f = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(a) })?.frame
                ?? NSScreen.screens.first?.frame {
                let kept = NSPoint(x: min(max(a.x, f.minX + 20), f.maxX - 20), y: min(max(a.y, f.minY + 26), f.maxY))
                anchor = kept
                defaults.set(Double(kept.x), forKey: "anchorX")
                defaults.set(Double(kept.y), forKey: "anchorY")
            }
            layout(animated: false)
            return
        }
        if dragOrigin == nil {
            // Stop any resize animation in flight, or it would pull the pill back mid-drag.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                panel.animator().setFrame(panel.frame, display: false)
            }
            dragOrigin = NSPoint(x: panel.frame.midX, y: panel.frame.maxY - (view.docked ? 0 : view.margin))
        }
        guard let origin = dragOrigin else { return }
        anchor = NSPoint(x: origin.x + offset.x, y: origin.y + offset.y)
        layout(animated: false)
    }

    private func layout(animated: Bool) {
        let screens = NSScreen.screens
        guard let main = screens.first else { return }
        let screen = anchor.flatMap { a in
            screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(a) }
                ?? screens.first { a.x >= $0.frame.minX && a.x <= $0.frame.maxX }
        } ?? main
        let f = screen.frame
        var centre = anchor?.x ?? f.midX
        var top = anchor?.y ?? f.maxY
        // Snap to the top edge (notch look) and to the horizontal centre.
        let docked = f.maxY - top < 14
        if docked { top = f.maxY }
        if abs(centre - f.midX) < 14 { centre = f.midX }

        let bar = f.maxY - screen.visibleFrame.maxY
        view.barHeight = bar > 20 ? bar : NSStatusBar.system.thickness
        view.docked = docked
        view.rows = store.ordered
        let alert = alertFor(view.rows)
        for s in view.rows where !s.id.hasPrefix("_") { history[s.id] = s }
        if history.count > 24, let oldest = history.values.min(by: { $0.updated < $1.updated }) {
            history[oldest.id] = nil
        }

        // Pill while any agent is working, waiting, or finished in the last 10 minutes
        // (the sweep turns "done" into "idle" after that). The menu bar icon is always there.
        let active = view.rows.contains { $0.state != .idle }
        guard active else {
            view.expanded = false
            panel.orderOut(nil)
            return
        }
        let wasHidden = !panel.isVisible
        let size = view.preferredSize
        // The view carries a transparent glow margin, which is allowed to hang off the screen.
        let m = view.margin
        let x = min(max(centre - size.width / 2, f.minX - m), f.maxX - size.width + m)
        let y = docked ? f.maxY - size.height : min(max(top + m - size.height, f.minY - m), f.maxY + m - size.height)
        let frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        if animated, !wasHidden, dragOrigin == nil, panel.frame != frame {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        if wasHidden {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 1
            }
        }
        view.refresh()
        if let alert { play(alert) }
    }

    /// One menu for both the menu bar icon and a right-click on the pill:
    /// recent sessions (kept even after their rows are cleared), then three options.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recent = history.values.sorted { $0.updated > $1.updated }.prefix(8)
        if recent.isEmpty {
            menu.addItem(withTitle: "No recent sessions", action: nil, keyEquivalent: "")
        }
        for s in recent {
            let age = Int(Date().timeIntervalSince(s.updated))
            let when = age < 60 ? "now" : age < 3600 ? "\(age / 60)m ago" : "\(age / 3600)h ago"
            let name = s.label.isEmpty ? "" : s.label + " — "
            let item = menu.addItem(withTitle: "\(name)\(s.text) · \(when)", action: #selector(noop), keyEquivalent: "")
            item.target = self
            let color = s.state == .idle ? NSColor.systemGray : s.state.color
            item.image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
        }
        menu.addItem(.separator())
        for (title, action, key) in [("Chime When an Agent Needs You", #selector(toggleChimeWaiting), "chimeWaiting"),
                                     ("Chime When an Agent Finishes", #selector(toggleChimeDone), "chimeDone")] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = defaults.bool(forKey: key) ? .on : .off
        }
        menu.addItem(.separator())
        for (title, action) in [("Reset Position", #selector(resetPosition)),
                                ("Clear Chats", #selector(clearChats)),
                                ("Quit", #selector(quit))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        return menu
    }

    /// Which alert (if any) this update deserves: a row that just turned amber beats one that just finished.
    private func alertFor(_ rows: [Session]) -> PillState? {
        var alert: PillState?
        for s in rows where !s.id.hasPrefix("_") {
            let was = lastStates[s.id]
            if s.state == .waiting, was != .waiting { alert = .waiting }
            if s.state == .done, was == .working || was == .waiting, alert == nil { alert = .done }
        }
        lastStates = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.state) })
        return alert
    }

    private func play(_ state: PillState) {
        // Back-to-back prompts (a permission request plus its notification, parallel agents) get one alert.
        guard Date().timeIntervalSince(lastAlert) > 3 else { return }
        lastAlert = Date()
        if state == .waiting {
            bounce()
            if defaults.bool(forKey: "chimeWaiting") { chime("Glass", volume: 0.35) }
        } else if defaults.bool(forKey: "chimeDone") {
            chime("Tink", volume: 0.3)
        }
    }

    /// A short drop-and-settle of the whole pill, to catch the eye when an agent starts waiting on you.
    private func bounce() {
        guard dragOrigin == nil, panel.isVisible else { return }
        let home = panel.frame
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        func step(_ dy: CGFloat, _ duration: TimeInterval, then next: (() -> Void)? = nil) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = ease
                panel.animator().setFrame(home.offsetBy(dx: 0, dy: dy), display: true)
            }, completionHandler: { [weak self] in
                // Stop if something else (a resize, a drag) moved the pill meanwhile.
                guard let self, self.dragOrigin == nil,
                      abs(self.panel.frame.minX - home.minX) < 1, self.panel.frame.size == home.size else { return }
                next?()
            })
        }
        step(-7, 0.12) { step(0, 0.16) { step(-3, 0.1) { step(0, 0.14) } } }
    }

    private func chime(_ name: String, volume: Float) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    @objc private func toggleChimeWaiting() { defaults.set(!defaults.bool(forKey: "chimeWaiting"), forKey: "chimeWaiting") }
    @objc private func toggleChimeDone() { defaults.set(!defaults.bool(forKey: "chimeDone"), forKey: "chimeDone") }

    @objc private func noop() {}
    @objc private func resetPosition() {
        anchor = nil
        defaults.removeObject(forKey: "anchorX")
        defaults.removeObject(forKey: "anchorY")
        layout(animated: true)
    }
    /// Clears every row from the pill. Sessions stay listed under recent sessions in the menu.
    @objc private func clearChats() {
        store.clearAll()
        changed()
    }
    @objc private func quit() { unlink(socketPath); NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--uninstall") {
    Installer.uninstall()
    LoginItem.set(false)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
