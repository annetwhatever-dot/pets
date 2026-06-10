import Darwin
import Foundation

final class InAppDaemon {
    fileprivate enum Constants {
        static let version = 1
        static let socketBacklog: Int32 = 16
        static let maxLineBytes = 1024 * 1024
    }

    private let socketPath: String
    private let queue = DispatchQueue(label: "CodexPets.InAppDaemon")
    private let state = InAppDaemonState()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var subscribers = Set<Int32>()

    init(socketPath: String = DaemonClient.defaultSocketPath()) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    func start() {
        queue.sync {
            startOnQueue()
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for fd in subscribers {
                Darwin.shutdown(fd, SHUT_RDWR)
            }
            subscribers.removeAll()
            if listenFD >= 0 {
                Darwin.close(listenFD)
                listenFD = -1
            }
            Darwin.unlink(socketPath)
        }
    }

    private func startOnQueue() {
        guard listenFD < 0 else { return }
        prepareSocketPath()

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        setCloseOnExec(fd)
        setNonBlocking(fd)

        guard bindUnixSocket(fd, path: socketPath), Darwin.listen(fd, Constants.socketBacklog) == 0 else {
            Darwin.close(fd)
            return
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailableClients()
        }
        acceptSource = source
        source.resume()
    }

    private func prepareSocketPath() {
        let socketURL = URL(fileURLWithPath: socketPath)
        let directory = socketURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Darwin.chmod(directory.path, 0o700)
        Darwin.unlink(socketPath)
    }

    private func acceptAvailableClients() {
        while listenFD >= 0 {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR {
                    return
                }
                return
            }
            setCloseOnExec(clientFD)
            setNoSigPipe(clientFD)
            setBlocking(clientFD)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        defer {
            queue.async { [weak self] in
                self?.subscribers.remove(fd)
            }
            Darwin.close(fd)
        }

        while true {
            let count = chunk.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 {
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            buffer.append(contentsOf: chunk.prefix(count))
            if buffer.count > Constants.maxLineBytes {
                writeEnvelope(errorResponse(id: "", method: "", code: "line_too_large", message: "protocol line is too large"), to: fd)
                return
            }
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                handleLine(line, fd: fd)
            }
        }
    }

    private func handleLine(_ line: Data, fd: Int32) {
        guard
            !line.isEmpty,
            let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let method = message["method"] as? String
        else {
            writeEnvelope(errorResponse(id: "", method: "", code: "invalid_json", message: "invalid protocol message"), to: fd)
            return
        }

        let id = message["id"] as? String ?? ""
        guard message["version"] as? Int == Constants.version else {
            writeEnvelope(errorResponse(id: id, method: method, code: "unsupported_version", message: "unsupported protocol version"), to: fd)
            return
        }
        guard message["kind"] as? String == "request", !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            writeEnvelope(errorResponse(id: id, method: method, code: "invalid_request", message: "request id is required"), to: fd)
            return
        }

        if method == "approval.request" {
            handleApprovalRequest(message, fd: fd)
            return
        }

        let response = queue.sync {
            handleRequestOnQueue(message, subscriberFD: fd)
        }
        writeEnvelope(response, to: fd)
    }

    private func handleApprovalRequest(_ message: [String: Any], fd: Int32) {
        let id = message["id"] as? String ?? ""
        let method = message["method"] as? String ?? "approval.request"
        let payload = message["payload"] as? [String: Any] ?? [:]
        let registration = queue.sync {
            state.addApproval(payload)
        }
        queue.async { [weak self] in
            self?.broadcastSnapshotOnQueue()
        }

        let timeoutMillis = positiveInt(payload["timeoutMillis"]) ?? 10 * 60 * 1000
        let waitResult = registration.waiter.semaphore.wait(timeout: .now() + .milliseconds(timeoutMillis))
        let decision: [String: Any]
        if waitResult == .timedOut {
            decision = queue.sync {
                let expired = state.expireApproval(id: registration.approvalID)
                if expired.changed {
                    broadcastSnapshotOnQueue()
                }
                return expired.decision
            }
        } else {
            decision = registration.waiter.decision ?? [
                "approvalId": registration.approvalID,
                "decision": "expired",
                "reason": "approval timed out",
            ]
        }
        writeEnvelope(response(id: id, method: method, payload: decision), to: fd)
    }

    private func handleRequestOnQueue(_ message: [String: Any], subscriberFD fd: Int32) -> [String: Any] {
        let id = message["id"] as? String ?? ""
        let method = message["method"] as? String ?? ""
        let payload = message["payload"] as? [String: Any] ?? [:]

        switch method {
        case "hello":
            return response(id: id, method: method, payload: [
                "ok": true,
                "server": "codex-pets-in-app-daemon",
                "version": Constants.version,
            ])
        case "snapshot.get":
            return response(id: id, method: method, payload: state.snapshot())
        case "state.subscribe":
            subscribers.insert(fd)
            return response(id: id, method: method, payload: state.snapshot())
        case "session.upsert":
            state.upsertSession(payload)
            broadcastSnapshotOnQueue()
            return response(id: id, method: method, payload: state.snapshot())
        case "session.remove":
            state.removeSession(payload)
            broadcastSnapshotOnQueue()
            return response(id: id, method: method, payload: state.snapshot())
        case "tool.start":
            state.toolStart(payload)
            broadcastSnapshotOnQueue()
            return response(id: id, method: method, payload: state.snapshot())
        case "tool.update":
            state.toolUpdate(payload)
            broadcastSnapshotOnQueue()
            return response(id: id, method: method, payload: state.snapshot())
        case "tool.end":
            state.toolEnd(payload)
            broadcastSnapshotOnQueue()
            return response(id: id, method: method, payload: state.snapshot())
        case "approval.respond":
            let result = state.resolveApproval(payload)
            guard result.ok else {
                return errorResponse(id: id, method: method, code: "approval_not_found", message: "approval is not pending")
            }
            broadcastSnapshotOnQueue()
            return response(id: id, method: method, payload: result.decision)
        case "pet.select":
            state.selectPet(payload)
            broadcastSnapshotOnQueue()
            return response(id: id, method: method, payload: state.snapshot())
        case "pets.installed.set":
            state.setInstalledPets(payload)
            broadcastSnapshotOnQueue()
            return response(id: id, method: method, payload: state.snapshot())
        case "catalog.cache.set":
            state.setCatalog(payload)
            broadcastSnapshotOnQueue()
            return response(id: id, method: method, payload: state.snapshot())
        default:
            return errorResponse(id: id, method: method, code: "unknown_method", message: "method is not supported")
        }
    }

    private func broadcastSnapshotOnQueue() {
        let event = envelope(kind: "event", id: nil, method: "state.snapshot", payload: state.snapshot())
        var deadSubscribers: [Int32] = []
        for fd in subscribers {
            if !writeEnvelope(event, to: fd) {
                deadSubscribers.append(fd)
            }
        }
        for fd in deadSubscribers {
            subscribers.remove(fd)
            Darwin.shutdown(fd, SHUT_RDWR)
        }
    }
}

private final class InAppDaemonState {
    private let dateFormatter = ISO8601DateFormatter()
    private var sessions: [String: InAppSession] = [:]
    private var pendingApprovals: [String: InAppApproval] = [:]
    private var waiters: [String: ApprovalWaiter] = [:]
    private var removedSessions = Set<String>()
    private var selectedPetID: String?
    private var installedPets: [[String: Any]] = []
    private var catalogs: [String: [String: Any]] = [:]

    func snapshot() -> [String: Any] {
        var payload: [String: Any] = [
            "attention": deriveAttention(),
            "sessions": sessions.values
                .sorted { lhs, rhs in
                    if lhs.updatedAt == rhs.updatedAt { return lhs.id < rhs.id }
                    return lhs.updatedAt > rhs.updatedAt
                }
                .map { $0.dictionary(formatter: dateFormatter) },
            "pendingApprovals": pendingApprovals.values
                .sorted { $0.createdAt < $1.createdAt }
                .map { $0.dictionary(formatter: dateFormatter) },
            "installedPets": installedPets,
            "catalogs": catalogs,
            "updatedAt": dateFormatter.string(from: Date()),
        ]
        if let selectedPetID, !selectedPetID.isEmpty {
            payload["selectedPetId"] = selectedPetID
        }
        return payload
    }

    func upsertSession(_ payload: [String: Any]) {
        let now = Date()
        let id = cleanString(payload["sessionId"]) ?? "default"
        removedSessions.remove(id)
        let status = normalizeStatus(cleanString(payload["status"]))
        if var session = sessions[id] {
            session.cwd = clamp(cleanString(payload["cwd"]), max: 240)
            session.title = clamp(cleanString(payload["title"]), max: 120)
            session.status = status
            session.safeSummary = safeSummary(cleanString(payload["safeSummary"]))
            session.updatedAt = now
            sessions[id] = session
        } else {
            sessions[id] = InAppSession(
                id: id,
                cwd: clamp(cleanString(payload["cwd"]), max: 240),
                title: clamp(cleanString(payload["title"]), max: 120),
                status: status,
                safeSummary: safeSummary(cleanString(payload["safeSummary"])),
                tools: [:],
                startedAt: now,
                updatedAt: now
            )
        }
    }

    func removeSession(_ payload: [String: Any]) {
        guard let id = cleanString(payload["sessionId"]) else { return }
        sessions.removeValue(forKey: id)
        removedSessions.insert(id)
        let approvalIDs = pendingApprovals.values
            .filter { $0.sessionID == id }
            .map(\.id)
        for approvalID in approvalIDs {
            pendingApprovals.removeValue(forKey: approvalID)
            if let waiter = waiters.removeValue(forKey: approvalID) {
                waiter.decision = [
                    "approvalId": approvalID,
                    "decision": "expired",
                    "reason": "session terminated",
                ]
                waiter.semaphore.signal()
            }
        }
    }

    func toolStart(_ payload: [String: Any]) {
        let now = Date()
        let sessionID = cleanString(payload["sessionId"]) ?? "default"
        guard !removedSessions.contains(sessionID) else { return }
        var session = ensureSession(id: sessionID, now: now)
        let toolID = cleanString(payload["toolCallId"]) ?? "\(cleanString(payload["toolName"]) ?? "tool")-\(Int(now.timeIntervalSince1970 * 1000))"
        session.tools[toolID] = InAppTool(
            id: toolID,
            sessionID: session.id,
            name: clamp(cleanString(payload["toolName"]), max: 80) ?? "tool",
            state: "running",
            safeSummary: safeSummary(cleanString(payload["safeSummary"])),
            startedAt: now,
            endedAt: nil
        )
        session.status = "running"
        session.updatedAt = now
        sessions[session.id] = session
    }

    func toolUpdate(_ payload: [String: Any]) {
        let now = Date()
        let sessionID = cleanString(payload["sessionId"]) ?? "default"
        guard !removedSessions.contains(sessionID) else { return }
        var session = ensureSession(id: sessionID, now: now)
        let toolID = cleanString(payload["toolCallId"]) ?? "\(cleanString(payload["toolName"]) ?? "tool")-\(Int(now.timeIntervalSince1970 * 1000))"
        let name = clamp(cleanString(payload["toolName"]), max: 80) ?? "tool"
        let summary = safeSummary(cleanString(payload["safeSummary"]))
        if var tool = session.tools[toolID] {
            tool.name = name
            if tool.state == "running" || tool.state.isEmpty {
                tool.state = "running"
            }
            if let summary, !summary.isEmpty {
                tool.safeSummary = summary
            }
            session.tools[toolID] = tool
        } else {
            session.tools[toolID] = InAppTool(
                id: toolID,
                sessionID: session.id,
                name: name,
                state: "running",
                safeSummary: summary,
                startedAt: now,
                endedAt: nil
            )
            session.status = "running"
        }
        session.updatedAt = now
        sessions[session.id] = session
    }

    func toolEnd(_ payload: [String: Any]) {
        let now = Date()
        let sessionID = cleanString(payload["sessionId"]) ?? "default"
        guard !removedSessions.contains(sessionID) else { return }
        var session = ensureSession(id: sessionID, now: now)
        let toolID = cleanString(payload["toolCallId"]) ?? ""
        let state = normalizeToolState(cleanString(payload["state"]))
        if var tool = session.tools[toolID] {
            tool.state = state == "running" ? "done" : state
            tool.safeSummary = safeSummary(cleanString(payload["safeSummary"]))
            tool.endedAt = now
            session.tools[toolID] = tool
        }
        if state == "failed" {
            session.status = "failed"
        }
        session.updatedAt = now
        sessions[session.id] = session
    }

    func addApproval(_ payload: [String: Any]) -> (approvalID: String, waiter: ApprovalWaiter) {
        let now = Date()
        let sessionID = cleanString(payload["sessionId"]) ?? "default"
        let toolCallID = cleanString(payload["toolCallId"])
        let id = cleanString(payload["approvalId"]) ?? "\(sessionID):\(toolCallID ?? "")"
        let approvalID = id == ":" ? "approval-\(Int(now.timeIntervalSince1970 * 1000))" : id
        if removedSessions.contains(sessionID) {
            let waiter = ApprovalWaiter()
            waiter.decision = [
                "approvalId": approvalID,
                "decision": "expired",
                "reason": "session terminated",
            ]
            waiter.semaphore.signal()
            return (approvalID, waiter)
        }
        let approval = InAppApproval(
            id: approvalID,
            sessionID: sessionID,
            toolCallID: toolCallID,
            toolName: clamp(cleanString(payload["toolName"]), max: 80) ?? "tool",
            commandSummary: safeSummary(cleanString(payload["commandSummary"])),
            risk: clamp(cleanString(payload["risk"]), max: 80),
            state: "pending",
            createdAt: now,
            updatedAt: now
        )
        let waiter = ApprovalWaiter()
        pendingApprovals[approval.id] = approval
        waiters[approval.id] = waiter
        return (approval.id, waiter)
    }

    func resolveApproval(_ payload: [String: Any]) -> (ok: Bool, decision: [String: Any]) {
        guard
            let id = cleanString(payload["approvalId"]),
            let rawDecision = cleanString(payload["decision"]),
            rawDecision == "approved" || rawDecision == "denied",
            pendingApprovals[id] != nil
        else {
            return (false, [:])
        }
        pendingApprovals.removeValue(forKey: id)
        let decision: [String: Any] = [
            "approvalId": id,
            "decision": rawDecision,
            "reason": safeSummary(cleanString(payload["reason"])) ?? "",
        ]
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.decision = decision
            waiter.semaphore.signal()
        }
        return (true, decision)
    }

    func expireApproval(id: String) -> (changed: Bool, decision: [String: Any]) {
        let decision: [String: Any] = [
            "approvalId": id,
            "decision": "expired",
            "reason": "approval timed out",
        ]
        guard pendingApprovals.removeValue(forKey: id) != nil else {
            return (false, decision)
        }
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.decision = decision
            waiter.semaphore.signal()
        }
        return (true, decision)
    }

    func selectPet(_ payload: [String: Any]) {
        selectedPetID = clamp(cleanString(payload["petId"]), max: 160)
    }

    func setInstalledPets(_ payload: [String: Any]) {
        let pets = payload["pets"] as? [[String: Any]] ?? []
        installedPets = pets.compactMap(sanitizePet)
            .sorted {
                ($0["displayName"] as? String ?? "").localizedCaseInsensitiveCompare($1["displayName"] as? String ?? "") == .orderedAscending
            }
    }

    func setCatalog(_ payload: [String: Any]) {
        let provider = clamp(cleanString(payload["provider"]), max: 80) ?? "unknown"
        let pets = (payload["pets"] as? [[String: Any]] ?? []).compactMap(sanitizePet)
        catalogs[provider] = [
            "provider": provider,
            "updatedAt": cleanString(payload["updatedAt"]) ?? dateFormatter.string(from: Date()),
            "pets": pets,
            "error": safeSummary(cleanString(payload["error"])) ?? "",
        ]
    }

    private func ensureSession(id: String, now: Date) -> InAppSession {
        if let session = sessions[id] {
            return session
        }
        return InAppSession(
            id: id,
            cwd: nil,
            title: nil,
            status: "idle",
            safeSummary: nil,
            tools: [:],
            startedAt: now,
            updatedAt: now
        )
    }

    private func deriveAttention() -> String {
        if pendingApprovals.values.contains(where: { $0.state == "pending" }) {
            return "approval_required"
        }
        var best = "idle"
        var bestRank = attentionRank(best)
        for session in sessions.values {
            let attention = attention(for: session.status)
            let rank = attentionRank(attention)
            if rank > bestRank {
                best = attention
                bestRank = rank
            }
        }
        return best
    }
}

private final class ApprovalWaiter {
    let semaphore = DispatchSemaphore(value: 0)
    var decision: [String: Any]?
}

private struct InAppSession {
    let id: String
    var cwd: String?
    var title: String?
    var status: String
    var safeSummary: String?
    var tools: [String: InAppTool]
    let startedAt: Date
    var updatedAt: Date

    func dictionary(formatter: ISO8601DateFormatter) -> [String: Any] {
        var output: [String: Any] = [
            "id": id,
            "status": status,
            "tools": tools.values
                .sorted { $0.startedAt < $1.startedAt }
                .map { $0.dictionary(formatter: formatter) },
            "startedAt": formatter.string(from: startedAt),
            "updatedAt": formatter.string(from: updatedAt),
        ]
        if let cwd, !cwd.isEmpty { output["cwd"] = cwd }
        if let title, !title.isEmpty { output["title"] = title }
        if let safeSummary, !safeSummary.isEmpty { output["safeSummary"] = safeSummary }
        return output
    }
}

private struct InAppTool {
    let id: String
    let sessionID: String
    var name: String
    var state: String
    var safeSummary: String?
    let startedAt: Date
    var endedAt: Date?

    func dictionary(formatter: ISO8601DateFormatter) -> [String: Any] {
        var output: [String: Any] = [
            "id": id,
            "sessionId": sessionID,
            "name": name,
            "state": state,
            "startedAt": formatter.string(from: startedAt),
        ]
        if let safeSummary, !safeSummary.isEmpty { output["safeSummary"] = safeSummary }
        if let endedAt { output["endedAt"] = formatter.string(from: endedAt) }
        return output
    }
}

private struct InAppApproval {
    let id: String
    let sessionID: String
    let toolCallID: String?
    let toolName: String
    let commandSummary: String?
    let risk: String?
    let state: String
    let createdAt: Date
    let updatedAt: Date

    func dictionary(formatter: ISO8601DateFormatter) -> [String: Any] {
        var output: [String: Any] = [
            "id": id,
            "sessionId": sessionID,
            "toolName": toolName,
            "state": state,
            "createdAt": formatter.string(from: createdAt),
            "updatedAt": formatter.string(from: updatedAt),
        ]
        if let toolCallID, !toolCallID.isEmpty { output["toolCallId"] = toolCallID }
        if let commandSummary, !commandSummary.isEmpty { output["commandSummary"] = commandSummary }
        if let risk, !risk.isEmpty { output["risk"] = risk }
        return output
    }
}

private func envelope(kind: String, id: String?, method: String, payload: Any) -> [String: Any] {
    var output: [String: Any] = [
        "version": InAppDaemon.Constants.version,
        "kind": kind,
        "method": method,
        "payload": payload,
    ]
    if let id, !id.isEmpty { output["id"] = id }
    return output
}

private func response(id: String, method: String, payload: Any) -> [String: Any] {
    envelope(kind: "response", id: id, method: method, payload: payload)
}

private func errorResponse(id: String, method: String, code: String, message: String) -> [String: Any] {
    [
        "version": InAppDaemon.Constants.version,
        "kind": "response",
        "id": id,
        "method": method,
        "error": [
            "code": code,
            "message": message,
        ],
    ]
}

@discardableResult
private func writeEnvelope(_ object: [String: Any], to fd: Int32) -> Bool {
    guard JSONSerialization.isValidJSONObject(object),
          var data = try? JSONSerialization.data(withJSONObject: object, options: [])
    else {
        return false
    }
    data.append(0x0a)
    return data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return false }
        var sent = 0
        while sent < data.count {
            let result = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
            if result < 0 {
                if errno == EINTR { continue }
                return false
            }
            sent += result
        }
        return true
    }
}

private func bindUnixSocket(_ fd: Int32, path: String) -> Bool {
    var address = sockaddr_un()
    #if os(macOS)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= maxPathLength else { return false }

    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
            for index in 0..<maxPathLength {
                destination[index] = 0
            }
            for index in 0..<bytes.count {
                destination[index] = bytes[index]
            }
        }
    }

    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
}

private func setCloseOnExec(_ fd: Int32) {
    let flags = Darwin.fcntl(fd, F_GETFD)
    if flags >= 0 {
        _ = Darwin.fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }
}

private func setNonBlocking(_ fd: Int32) {
    let flags = Darwin.fcntl(fd, F_GETFL)
    if flags >= 0 {
        _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}

private func setBlocking(_ fd: Int32) {
    let flags = Darwin.fcntl(fd, F_GETFL)
    if flags >= 0 {
        _ = Darwin.fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }
}

private func setNoSigPipe(_ fd: Int32) {
    #if os(macOS)
    var value: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    #endif
}

private func sanitizePet(_ raw: [String: Any]) -> [String: Any]? {
    guard let id = clamp(cleanString(raw["id"]), max: 160), !id.isEmpty else { return nil }
    var pet: [String: Any] = [
        "id": id,
        "displayName": clamp(cleanString(raw["displayName"]), max: 160) ?? id,
        "source": clamp(cleanString(raw["source"]), max: 80) ?? "app",
    ]
    if let path = clamp(cleanString(raw["path"]), max: 500), !path.isEmpty { pet["path"] = path }
    if let license = clamp(cleanString(raw["license"]), max: 120), !license.isEmpty { pet["license"] = license }
    if let attribution = clamp(cleanString(raw["attribution"]), max: 240), !attribution.isEmpty {
        pet["attribution"] = attribution
    }
    return pet
}

private func attention(for status: String) -> String {
    switch normalizeStatus(status) {
    case "failed", "disconnected":
        return "failed"
    case "done":
        return "done"
    case "running":
        return "running"
    case "thinking":
        return "thinking"
    default:
        return "idle"
    }
}

private func attentionRank(_ attention: String) -> Int {
    switch attention {
    case "approval_required": return 60
    case "failed": return 50
    case "done": return 40
    case "running": return 30
    case "thinking": return 20
    default: return 10
    }
}

private func normalizeStatus(_ status: String?) -> String {
    switch status {
    case "idle", "thinking", "running", "done", "failed", "disconnected":
        return status!
    default:
        return "idle"
    }
}

private func normalizeToolState(_ state: String?) -> String {
    switch state {
    case "running", "done", "failed":
        return state!
    default:
        return "running"
    }
}

private func positiveInt(_ value: Any?) -> Int? {
    if let value = value as? Int, value > 0 { return value }
    if let value = value as? Double, value > 0 { return Int(value) }
    if let value = cleanString(value), let parsed = Int(value), parsed > 0 { return parsed }
    return nil
}

private func safeSummary(_ value: String?) -> String? {
    guard let value else { return nil }
    let collapsed = value
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return clamp(collapsed, max: 180)
}

private func clamp(_ value: String?, max: Int) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > max else { return trimmed }
    return String(trimmed.prefix(max))
}

private func cleanString(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let value = value as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? CustomStringConvertible {
        let trimmed = value.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    return nil
}
