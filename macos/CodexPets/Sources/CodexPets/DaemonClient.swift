import Foundation
import Network

struct DaemonPetRef: Codable, Equatable {
    let id: String
    let displayName: String
    let source: String
    let path: String?
    let license: String?
    let attribution: String?
}

struct DaemonToolRun: Codable, Equatable {
    let id: String
    let sessionId: String
    let name: String
    let state: String
    let safeSummary: String?
}

struct DaemonSession: Codable, Equatable {
    let id: String
    let cwd: String?
    let title: String?
    let status: String
    let safeSummary: String?
    let tools: [DaemonToolRun]?
}

struct DaemonPendingApproval: Codable, Equatable {
    let id: String
    let sessionId: String
    let toolCallId: String?
    let toolName: String
    let commandSummary: String?
    let risk: String?
    let state: String
}

struct DaemonSnapshot: Codable, Equatable {
    let attention: String
    let sessions: [DaemonSession]
    let pendingApprovals: [DaemonPendingApproval]
    let selectedPetId: String?
    let installedPets: [DaemonPetRef]
}

struct DaemonOverlayPresentation: Equatable {
    let stateID: String
    let bubble: String?
    let autoClearAfter: TimeInterval?
}

enum DaemonSnapshotPresenter {
    static func presentation(for snapshot: DaemonSnapshot) -> DaemonOverlayPresentation {
        switch snapshot.attention {
        case "approval_required":
            return DaemonOverlayPresentation(
                stateID: "waiting",
                bubble: approvalBubble(snapshot.pendingApprovals),
                autoClearAfter: nil
            )
        case "failed":
            return DaemonOverlayPresentation(
                stateID: "failed",
                bubble: sessionBubble(prefix: "Pi failed", sessions: matching(snapshot.sessions, statuses: ["failed", "disconnected"])),
                autoClearAfter: 8
            )
        case "done":
            return DaemonOverlayPresentation(
                stateID: "waving",
                bubble: sessionBubble(prefix: "Pi done", sessions: matching(snapshot.sessions, statuses: ["done"])),
                autoClearAfter: 6
            )
        case "running":
            return DaemonOverlayPresentation(
                stateID: "running",
                bubble: sessionBubble(prefix: "Pi running", sessions: matching(snapshot.sessions, statuses: ["running"])),
                autoClearAfter: nil
            )
        case "thinking":
            return DaemonOverlayPresentation(
                stateID: "review",
                bubble: sessionBubble(prefix: "Pi thinking", sessions: matching(snapshot.sessions, statuses: ["thinking"])),
                autoClearAfter: nil
            )
        default:
            return DaemonOverlayPresentation(stateID: "idle", bubble: nil, autoClearAfter: 4)
        }
    }

    private static func approvalBubble(_ approvals: [DaemonPendingApproval]) -> String {
        guard let approval = approvals.first(where: { $0.state == "pending" }) ?? approvals.first else {
            return "Approval needed"
        }
        let summary = safeText(approval.commandSummary ?? approval.toolName, max: 70)
        return summary.isEmpty ? "Approval needed" : "Approval needed: \(summary)"
    }

    private static func sessionBubble(prefix: String, sessions: [DaemonSession]) -> String? {
        guard !sessions.isEmpty else { return nil }
        if sessions.count == 1, let session = sessions.first {
            let summary = safeText(session.safeSummary ?? session.title ?? session.cwd ?? session.id, max: 70)
            return summary.isEmpty ? prefix : "\(prefix): \(summary)"
        }
        return "\(prefix): \(sessions.count) sessions"
    }

    private static func matching(_ sessions: [DaemonSession], statuses: Set<String>) -> [DaemonSession] {
        sessions.filter { statuses.contains($0.status) }
    }

    private static func safeText(_ value: String, max: Int) -> String {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > max else { return collapsed }
        return String(collapsed.prefix(max))
    }
}

final class DaemonClient {
    private enum Constants {
        static let version = 1
        static let subscribeMethod = "state.subscribe"
        static let snapshotMethod = "state.snapshot"
        static let snapshotGetMethod = "snapshot.get"
        static let installedPetsMethod = "pets.installed.set"
        static let selectPetMethod = "pet.select"
        static let approvalRespondMethod = "approval.respond"
    }

    private let socketPath: String
    private let queue = DispatchQueue(label: "CodexPets.DaemonClient")
    private var subscription: NWConnection?
    private var subscriptionBuffer = Data()
    private var requestCounter = 0

    init(socketPath: String = DaemonClient.defaultSocketPath()) {
        self.socketPath = socketPath
    }

    static func defaultSocketPath() -> String {
        if let runtimeDir = ProcessInfo.processInfo.environment["PI_PET_SOCKET_DIR"], !runtimeDir.isEmpty {
            return URL(fileURLWithPath: runtimeDir).appendingPathComponent("pi-pet.sock").path
        }
        if let runtimeDir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !runtimeDir.isEmpty {
            return URL(fileURLWithPath: runtimeDir).appendingPathComponent("pi-pet.sock").path
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-pets-\(getuid())", isDirectory: true)
            .appendingPathComponent("pi-pet.sock")
            .path
    }

    func startSnapshotSubscription(onSnapshot: @escaping (DaemonSnapshot) -> Void) {
        queue.async { [weak self] in
            self?.startSnapshotSubscriptionOnQueue(onSnapshot: onSnapshot)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.subscription?.cancel()
            self?.subscription = nil
            self?.subscriptionBuffer.removeAll()
        }
    }

    func publishInstalledPets(_ pets: [PetPackage]) {
        let payload: [String: Any] = [
            "pets": pets.map(Self.petRefDictionary),
        ]
        sendRequest(method: Constants.installedPetsMethod, payload: payload)
    }

    func selectPet(_ petID: String) {
        sendRequest(method: Constants.selectPetMethod, payload: ["petId": petID])
    }

    func getSnapshot(completion: @escaping (DaemonSnapshot?) -> Void) {
        sendRequest(method: Constants.snapshotGetMethod, payload: [:]) { payload in
            DispatchQueue.main.async {
                completion(Self.decodeSnapshotPayload(payload))
            }
        }
    }

    func respondToApproval(approvalID: String, decision: String, reason: String? = nil) {
        var payload: [String: Any] = [
            "approvalId": approvalID,
            "decision": decision,
        ]
        if let reason, !reason.isEmpty {
            payload["reason"] = reason
        }
        sendRequest(method: Constants.approvalRespondMethod, payload: payload)
    }

    private func startSnapshotSubscriptionOnQueue(onSnapshot: @escaping (DaemonSnapshot) -> Void) {
        subscription?.cancel()
        subscriptionBuffer.removeAll()

        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        subscription = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .ready = state {
                self.send(message: self.request(method: Constants.subscribeMethod, payload: [:]), on: connection)
                self.receive(on: connection, onSnapshot: onSnapshot)
            }
        }
        connection.start(queue: queue)
    }

    private func sendRequest(method: String, payload: [String: Any], onPayload: ((Any) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let connection = NWConnection(to: .unix(path: self.socketPath), using: .tcp)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                if case .ready = state {
                    self.send(message: self.request(method: method, payload: payload), on: connection)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, _, _ in
                        if let onPayload,
                           let data,
                           let payload = Self.decodeResponsePayload(data)
                        {
                            onPayload(payload)
                        }
                        connection.cancel()
                    }
                }
            }
            connection.start(queue: self.queue)
        }
    }

    private func receive(on connection: NWConnection, onSnapshot: @escaping (DaemonSnapshot) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak connection] data, _, isComplete, _ in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                self.subscriptionBuffer.append(data)
                self.consumeSnapshotLines(onSnapshot: onSnapshot)
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, onSnapshot: onSnapshot)
        }
    }

    private func consumeSnapshotLines(onSnapshot: @escaping (DaemonSnapshot) -> Void) {
        while let newline = subscriptionBuffer.firstIndex(of: 0x0a) {
            let line = subscriptionBuffer[..<newline]
            subscriptionBuffer.removeSubrange(...newline)
            guard let snapshot = Self.decodeSnapshotEnvelope(Data(line)) else { continue }
            DispatchQueue.main.async {
                onSnapshot(snapshot)
            }
        }
    }

    private func request(method: String, payload: [String: Any]) -> [String: Any] {
        requestCounter += 1
        return [
            "version": Constants.version,
            "kind": "request",
            "id": "mac-\(requestCounter)",
            "method": method,
            "payload": payload,
        ]
    }

    private func send(message: [String: Any], on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: []) else { return }
        var line = data
        line.append(0x0a)
        connection.send(content: line, completion: .contentProcessed { _ in })
    }

    private static func decodeSnapshotEnvelope(_ data: Data) -> DaemonSnapshot? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String,
            method == Constants.snapshotMethod || method == Constants.subscribeMethod,
            let payload = object["payload"],
            JSONSerialization.isValidJSONObject(payload),
            let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [])
        else {
            return nil
        }

        let decoder = JSONDecoder()
        return try? decoder.decode(DaemonSnapshot.self, from: payloadData)
    }

    private static func decodeResponsePayload(_ data: Data) -> Any? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["error"] == nil
        else {
            return nil
        }
        return object["payload"]
    }

    private static func decodeSnapshotPayload(_ payload: Any?) -> DaemonSnapshot? {
        guard
            let payload,
            JSONSerialization.isValidJSONObject(payload),
            let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [])
        else {
            return nil
        }
        return try? JSONDecoder().decode(DaemonSnapshot.self, from: payloadData)
    }

    private static func petRefDictionary(_ pet: PetPackage) -> [String: Any] {
        [
            "id": pet.id,
            "displayName": pet.displayName,
            "source": pet.source.rawValue,
            "path": pet.directory.path,
            "license": "unknown",
            "attribution": "",
        ]
    }
}
