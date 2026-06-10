import Cocoa
import Foundation
import WebKit

struct PetdexCatalogEntry: Equatable {
    let slug: String
    let displayName: String
    let detail: String
    let kind: String
    let submittedBy: String
    let tags: [String]
    let spritesheetURL: URL
    let petJSONURL: URL?
    let zipURL: URL?
    let frameWidth: Int
    let frameHeight: Int

    var petdexURL: URL? {
        URL(string: "https://petdex.dev/pets/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)")
    }

    func generatedPetJSON() -> Data {
        let object: [String: Any] = [
            "slug": slug,
            "displayName": displayName,
            "description": detail,
            "kind": kind,
            "tags": tags,
            "frameWidth": frameWidth,
            "frameHeight": frameHeight,
            "spritesheetPath": "spritesheet.\(spritesheetURL.pathExtension.isEmpty ? "webp" : spritesheetURL.pathExtension.lowercased())",
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }
}

enum PetdexManifestError: Error, LocalizedError {
    case invalidJSON
    case unsupportedShape
    case emptyCatalog

    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "Petdex manifest could not be decoded."
        case .unsupportedShape: return "Petdex manifest shape is not supported."
        case .emptyCatalog: return "Petdex manifest did not contain any compatible pets."
        }
    }
}

enum PetdexManifestParser {
    static let defaultAssetBase = "https://assets.petdex.dev"

    static func parse(_ data: Data, defaultAssetBase: String = defaultAssetBase) throws -> [PetdexCatalogEntry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PetdexManifestError.invalidJSON
        }

        let entries: [PetdexCatalogEntry]
        if int(root["v"]) == 2, let pets = root["pets"] as? [Any] {
            let assetBase = string(root["assetBase"]) ?? defaultAssetBase
            entries = pets.compactMap { item in
                guard let values = item as? [Any] else { return nil }
                return parseCompactPet(values, assetBase: assetBase)
            }
        } else if let pets = root["pets"] as? [[String: Any]] {
            let assetBase = string(root["assetBase"]) ?? defaultAssetBase
            entries = pets.compactMap { parsePetObject($0, assetBase: assetBase) }
        } else {
            throw PetdexManifestError.unsupportedShape
        }

        let sorted = entries.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        guard !sorted.isEmpty else { throw PetdexManifestError.emptyCatalog }
        return sorted
    }

    private static func parseCompactPet(_ values: [Any], assetBase: String) -> PetdexCatalogEntry? {
        guard values.count >= 5 else { return nil }
        let slug = string(values[safe: 0]) ?? ""
        let displayName = string(values[safe: 1]) ?? slug
        let kind = string(values[safe: 2]) ?? "pet"
        let submittedBy = string(values[safe: 3]) ?? ""
        let spritesheet = string(values[safe: 4]) ?? ""
        let petJSON = string(values[safe: 5])
        let zip = string(values[safe: 6])
        return makeEntry(
            slug: slug,
            displayName: displayName,
            detail: "Animated Codex pet from Petdex.",
            kind: kind,
            submittedBy: submittedBy,
            tags: [],
            spritesheetURL: spritesheet,
            petJSONURL: petJSON,
            zipURL: zip,
            frameWidth: 192,
            frameHeight: 208,
            assetBase: assetBase
        )
    }

    private static func parsePetObject(_ object: [String: Any], assetBase: String) -> PetdexCatalogEntry? {
        let slug = string(object["slug"]) ?? string(object["id"]) ?? ""
        let displayName = string(object["displayName"]) ?? string(object["name"]) ?? slug
        let spritesheet = string(object["spritesheetUrl"])
            ?? string(object["spritesheetURL"])
            ?? string(object["spritesheetPath"])
            ?? string(object["spritesheet"])
            ?? string(object["spriteUrl"])
            ?? string(object["spriteURL"])
            ?? ""
        let petJSON = string(object["petJsonUrl"])
            ?? string(object["petJSONUrl"])
            ?? string(object["petJsonURL"])
            ?? string(object["petJSONURL"])
        return makeEntry(
            slug: slug,
            displayName: displayName,
            detail: string(object["description"]) ?? "Animated Codex pet from Petdex.",
            kind: string(object["kind"]) ?? "pet",
            submittedBy: string(object["submittedBy"]) ?? string(object["author"]) ?? "",
            tags: stringList(object["tags"]) + stringList(object["vibes"]),
            spritesheetURL: spritesheet,
            petJSONURL: petJSON,
            zipURL: string(object["zipUrl"]) ?? string(object["zipURL"]),
            frameWidth: int(object["frameWidth"]) ?? 192,
            frameHeight: int(object["frameHeight"]) ?? 208,
            assetBase: assetBase
        )
    }

    private static func makeEntry(
        slug rawSlug: String,
        displayName rawDisplayName: String,
        detail: String,
        kind: String,
        submittedBy: String,
        tags: [String],
        spritesheetURL rawSpritesheetURL: String,
        petJSONURL rawPetJSONURL: String?,
        zipURL rawZipURL: String?,
        frameWidth: Int,
        frameHeight: Int,
        assetBase: String
    ) -> PetdexCatalogEntry? {
        let slug = slugify(rawSlug)
        let displayName = string(rawDisplayName) ?? slug
        guard !slug.isEmpty,
              let spritesheetURL = absoluteURL(rawSpritesheetURL, assetBase: assetBase)
        else {
            return nil
        }
        return PetdexCatalogEntry(
            slug: slug,
            displayName: displayName,
            detail: detail.isEmpty ? "Animated Codex pet from Petdex." : detail,
            kind: kind.isEmpty ? "pet" : kind,
            submittedBy: submittedBy,
            tags: uniqueTags(tags),
            spritesheetURL: spritesheetURL,
            petJSONURL: rawPetJSONURL.flatMap { absoluteURL($0, assetBase: assetBase) },
            zipURL: rawZipURL.flatMap { absoluteURL($0, assetBase: assetBase) },
            frameWidth: max(1, frameWidth),
            frameHeight: max(1, frameHeight)
        )
    }

    private static func absoluteURL(_ rawValue: String, assetBase: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let url = URL(string: value), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        let base = assetBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/\(path)")
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int, value > 0 { return value }
        if let value = value as? Double, value > 0 { return Int(value) }
        if let text = value as? String, let parsed = Int(text), parsed > 0 { return parsed }
        return nil
    }

    private static func stringList(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap(string).filter { !$0.isEmpty }
    }

    private static func uniqueTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for tag in tags {
            let key = tag.lowercased()
            if seen.insert(key).inserted {
                output.append(tag)
            }
        }
        return output
    }
}

enum PetdexCatalogSearch {
    static func filter(_ entries: [PetdexCatalogEntry], query rawQuery: String) -> [PetdexCatalogEntry] {
        let tokens = searchTokens(rawQuery)
        guard !tokens.isEmpty else { return entries }

        return entries.compactMap { entry -> (entry: PetdexCatalogEntry, score: Int)? in
            guard let score = score(entry, tokens: tokens) else { return nil }
            return (entry, score)
        }
        .sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.entry.displayName.localizedCaseInsensitiveCompare(right.entry.displayName) == .orderedAscending
        }
        .map(\.entry)
    }

    private static func score(_ entry: PetdexCatalogEntry, tokens: [String]) -> Int? {
        let weightedFields: [(text: String, weight: Int)] = [
            (entry.displayName, 100),
            (entry.slug, 80),
            (entry.tags.joined(separator: " "), 65),
            (entry.kind, 45),
            (entry.submittedBy, 35),
            (entry.detail, 20),
        ]
        let normalizedFields = weightedFields.map { (normalize($0.text), $0.weight) }
        var total = 0

        for token in tokens {
            let best = normalizedFields
                .filter { field, _ in field.contains(token) }
                .map(\.1)
                .max()
            guard let best else { return nil }
            total += best
        }

        return total
    }

    private static func searchTokens(_ value: String) -> [String] {
        normalize(value)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

final class PetdexCatalogClient {
    static let manifestV1 = URL(string: "https://assets.petdex.dev/manifests/petdex-v1.json")!
    static let manifestV2 = URL(string: "https://assets.petdex.dev/manifests/petdex-v2.json")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func loadCatalog(completion: @escaping (Result<[PetdexCatalogEntry], Error>) -> Void) {
        loadManifest(from: Self.manifestV1) { [weak self] result in
            switch result {
            case .success:
                completion(result)
            case .failure:
                self?.loadManifest(from: Self.manifestV2, completion: completion)
            }
        }
    }

    func downloadPackage(
        for entry: PetdexCatalogEntry,
        completion: @escaping (Result<(petJSON: Data, spritesheet: Data, spritesheetExtension: String), Error>) -> Void
    ) {
        let petJSONTask: (@escaping (Result<Data, Error>) -> Void) -> Void = { [session] done in
            guard let url = entry.petJSONURL else {
                done(.success(entry.generatedPetJSON()))
                return
            }
            session.codexPetsDataTask(with: url, completion: done)
        }

        petJSONTask { [session] jsonResult in
            switch jsonResult {
            case let .failure(error):
                completion(.failure(error))
            case let .success(petJSON):
                session.codexPetsDataTask(with: entry.spritesheetURL) { spriteResult in
                    switch spriteResult {
                    case let .failure(error):
                        completion(.failure(error))
                    case let .success(sprite):
                        completion(.success((
                            petJSON: petJSON,
                            spritesheet: sprite,
                            spritesheetExtension: Self.safeSpriteExtension(from: entry.spritesheetURL)
                        )))
                    }
                }
            }
        }
    }

    private func loadManifest(from url: URL, completion: @escaping (Result<[PetdexCatalogEntry], Error>) -> Void) {
        session.codexPetsDataTask(with: url) { result in
            completion(result.flatMap { data in Result { try PetdexManifestParser.parse(data) } })
        }
    }

    private static func safeSpriteExtension(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["webp", "png"].contains(ext) ? ext : "webp"
    }
}

private extension URLSession {
    func codexPetsDataTask(with url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("CodexPets/1.0", forHTTPHeaderField: "User-Agent")
        dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(PetdexNetworkError.httpStatus(http.statusCode)))
                return
            }
            completion(.success(data ?? Data()))
        }.resume()
    }
}

enum PetdexNetworkError: Error, LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case let .httpStatus(status): return "Petdex returned HTTP \(status)."
        }
    }
}

enum PetdexPreviewError: Error, LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Petdex preview image could not be decoded."
        }
    }
}

protocol PetdexPreviewCancellable {
    func cancel()
}

extension URLSessionDataTask: PetdexPreviewCancellable {}

final class PetdexPreviewCache {
    private let cache = NSCache<NSString, NSImage>()

    init(countLimit: Int = 96) {
        cache.countLimit = countLimit
    }

    func image(for entry: PetdexCatalogEntry) -> NSImage? {
        cache.object(forKey: key(for: entry))
    }

    func store(_ image: NSImage, for entry: PetdexCatalogEntry) {
        cache.setObject(image, forKey: key(for: entry))
    }

    private func key(for entry: PetdexCatalogEntry) -> NSString {
        "\(entry.spritesheetURL.absoluteString)#\(entry.frameWidth)x\(entry.frameHeight)" as NSString
    }
}

final class PetdexPreviewLoader {
    private let session: URLSession
    private let cache: PetdexPreviewCache
    private let decodeQueue = DispatchQueue(label: "dev.petdex.codex-pets.preview", qos: .userInitiated)

    init(session: URLSession = .shared, cache: PetdexPreviewCache = PetdexPreviewCache()) {
        self.session = session
        self.cache = cache
    }

    @discardableResult
    func loadPreview(
        for entry: PetdexCatalogEntry,
        completion: @escaping (Result<NSImage, Error>) -> Void
    ) -> PetdexPreviewCancellable? {
        if let image = cache.image(for: entry) {
            DispatchQueue.main.async {
                completion(.success(image))
            }
            return nil
        }

        var request = URLRequest(url: entry.spritesheetURL)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 15
        request.setValue("CodexPets/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error as? URLError, error.code == .cancelled {
                return
            }
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                DispatchQueue.main.async { completion(.failure(PetdexNetworkError.httpStatus(http.statusCode))) }
                return
            }
            guard let self, let data else {
                DispatchQueue.main.async { completion(.failure(PetdexPreviewError.invalidImage)) }
                return
            }

            self.decodeQueue.async {
                guard let preview = Self.firstFrameImage(
                    from: data,
                    frameWidth: entry.frameWidth,
                    frameHeight: entry.frameHeight
                ) else {
                    DispatchQueue.main.async { completion(.failure(PetdexPreviewError.invalidImage)) }
                    return
                }
                self.cache.store(preview, for: entry)
                DispatchQueue.main.async { completion(.success(preview)) }
            }
        }
        task.resume()
        return task
    }

    static func firstFrameImage(from data: Data, frameWidth: Int, frameHeight: Int) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        return firstFrameImage(from: image, frameWidth: frameWidth, frameHeight: frameHeight)
    }

    static func firstFrameImage(from image: NSImage, frameWidth: Int, frameHeight: Int) -> NSImage {
        let outputSize = NSSize(width: frameWidth, height: frameHeight)
        let output = NSImage(size: outputSize)
        output.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: outputSize).fill()
        let imageHeight = image.size.height > 1 ? image.size.height : CGFloat(frameHeight * 9)
        let source = NSRect(
            x: 0,
            y: max(0, imageHeight - CGFloat(frameHeight)),
            width: CGFloat(frameWidth),
            height: CGFloat(frameHeight)
        )
        image.draw(
            in: NSRect(origin: .zero, size: outputSize),
            from: source,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.none]
        )
        output.unlockFocus()
        return output
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

enum PetdexBrowserBridgeAction: String, CaseIterable {
    case importPet
    case listInstalledPets
    case selectInstalledPet
    case uninstallInstalledPet
    case getDaemonSnapshot
    case approvalDecision
}

typealias DaemonSnapshotProvider = (@escaping (DaemonSnapshot?) -> Void) -> Void

final class PetdexBrowserWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private enum Constants {
        static let bridgeName = "codexPets"
        static let browserResourceDirectory = "PetdexBrowser"
        static let initialSize = NSRect(x: 0, y: 0, width: 1180, height: 760)
        static let minimumSize = NSSize(width: 920, height: 620)
        static let backgroundColor = NSColor(
            srgbRed: 245.0 / 255.0,
            green: 247.0 / 255.0,
            blue: 248.0 / 255.0,
            alpha: 1
        )
    }

    private let store: PetStore
    private let client: PetdexCatalogClient
    private let onImport: (PetPackage) -> Void
    private let installedPetsProvider: () -> [PetPackage]
    private let onSelectInstalled: (PetPackage) -> Void
    private let onUninstallInstalled: (PetPackage) -> Void
    private let daemonSnapshotProvider: DaemonSnapshotProvider
    private let onApprovalDecision: (_ approvalID: String, _ decision: String) -> Void
    private let webView: WKWebView
    private let loadingView = NSView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "Loading Petdex...")

    private var didStartLoading = false
    private var didFinishInitialLoad = false
    private var importInFlight = false
    private var scriptMessageHandler: WeakScriptMessageHandler?

    init(
        store: PetStore,
        client: PetdexCatalogClient = PetdexCatalogClient(),
        installedPetsProvider: (() -> [PetPackage])? = nil,
        onImport: @escaping (PetPackage) -> Void,
        onSelectInstalled: ((PetPackage) -> Void)? = nil,
        onUninstallInstalled: ((PetPackage) -> Void)? = nil,
        daemonSnapshotProvider: DaemonSnapshotProvider? = nil,
        onApprovalDecision: ((_ approvalID: String, _ decision: String) -> Void)? = nil
    ) {
        self.store = store
        self.client = client
        self.onImport = onImport
        self.installedPetsProvider = installedPetsProvider ?? { store.scan() }
        self.onSelectInstalled = onSelectInstalled ?? onImport
        self.onUninstallInstalled = onUninstallInstalled ?? { _ in }
        self.daemonSnapshotProvider = daemonSnapshotProvider ?? { completion in completion(nil) }
        self.onApprovalDecision = onApprovalDecision ?? { _, _ in }
        self.webView = WKWebView(frame: .zero, configuration: Self.makeWebViewConfiguration())
        let window = NSWindow(
            contentRect: Constants.initialSize,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Browse Petdex"
        window.minSize = Constants.minimumSize
        window.backgroundColor = Constants.backgroundColor
        super.init(window: window)

        let handler = WeakScriptMessageHandler(delegate: self)
        scriptMessageHandler = handler
        webView.configuration.userContentController.add(handler, name: Constants.bridgeName)
        setupUI()
        prepareForDisplay()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Constants.bridgeName)
    }

    func prepareForDisplay() {
        loadBrowserIfNeeded()
    }

    override func showWindow(_ sender: Any?) {
        prepareForDisplay()
        super.showWindow(sender)
        if didFinishInitialLoad {
            revealWebView()
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Constants.bridgeName,
              let body = message.body as? [String: Any],
              let actionName = body["action"] as? String,
              let action = PetdexBrowserBridgeAction(rawValue: actionName)
        else {
            return
        }

        switch action {
        case .importPet:
            importPet(from: body["pet"])
        case .listInstalledPets:
            sendInstalledPets()
        case .selectInstalledPet:
            selectInstalledPet(from: body["petId"])
        case .uninstallInstalledPet:
            uninstallInstalledPet(from: body["petId"])
        case .getDaemonSnapshot:
            sendDaemonSnapshot()
        case .approvalDecision:
            handleApprovalDecision(body)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishInitialLoad = true
        revealWebView()
        notifyNativeReady()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadingStatus(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadingStatus(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        didStartLoading = false
        didFinishInitialLoad = false
        webView.alphaValue = 0
        loadingView.isHidden = false
        showLoadingStatus("Reloading Petdex...")
        loadBrowserIfNeeded()
    }

    func publishDaemonSnapshot(_ snapshot: DaemonSnapshot) {
        sendDaemonSnapshot(snapshot)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           Self.shouldOpenExternally(url)
        {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           Self.shouldOpenExternally(url)
        {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    private static func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        let bootstrap = """
        (() => {
          const postMessage = (payload) => {
            window.webkit?.messageHandlers?.\(Constants.bridgeName)?.postMessage(payload);
          };
          Object.defineProperty(window, "CodexPetsNative", {
            configurable: true,
            value: { isNativeShell: true, postMessage }
          });
          document.documentElement.classList.add("native-shell");
          const notifyReady = () => {
            window.dispatchEvent(new CustomEvent("codex-pets-native-ready"));
          };
          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", notifyReady, { once: true });
          } else {
            notifyReady();
          }
        })();
        """
        userContentController.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController = userContentController
        configuration.websiteDataStore = .default()
        configuration.suppressesIncrementalRendering = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = Constants.backgroundColor.cgColor

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.alphaValue = 0
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.wantsLayer = true
        webView.layer?.backgroundColor = Constants.backgroundColor.cgColor
        contentView.addSubview(webView)

        loadingView.wantsLayer = true
        loadingView.layer?.backgroundColor = Constants.backgroundColor.cgColor
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(loadingView)

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            loadingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            loadingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: loadingView.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: loadingView.trailingAnchor, constant: -24),
        ])
    }

    private func showLoadingStatus(_ message: String) {
        statusLabel.stringValue = message
    }

    private func loadBrowserIfNeeded() {
        guard !didStartLoading else { return }
        didStartLoading = true
        showLoadingStatus("Loading Petdex...")

        if let indexURL = Self.browserIndexURL() {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        } else {
            let html = """
            <!doctype html>
            <html><body style="margin:0;background:#f5f7f8;color:#182427;font:14px -apple-system, BlinkMacSystemFont, sans-serif;display:grid;min-height:100vh;place-items:center">
            <p>Petdex browser assets were not found in the app bundle.</p>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func revealWebView() {
        loadingView.isHidden = true
        webView.alphaValue = 1
    }

    private func notifyNativeReady() {
        evaluateJavaScriptEvent(
            name: "codex-pets-native-ready",
            detail: [:]
        )
        sendInstalledPets()
        sendDaemonSnapshot()
    }

    private func importPet(from payload: Any?) {
        guard !importInFlight else {
            evaluateImportResult(ok: false, message: "Another import is already running")
            return
        }
        guard let entry = Self.entry(from: payload) else {
            evaluateImportResult(ok: false, message: "Selected pet metadata is incomplete")
            return
        }

        importInFlight = true
        client.downloadPackage(for: entry) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.importInFlight = false
                switch result {
                case let .failure(error):
                    self.evaluateImportResult(ok: false, message: error.localizedDescription)
                case let .success(package):
                    do {
                        let pet = try self.store.importDownloadedPetdexPet(
                            entry,
                            petJSON: package.petJSON,
                            spritesheet: package.spritesheet,
                            spritesheetExtension: package.spritesheetExtension
                        )
                        self.evaluateImportResult(ok: true, message: "Imported \(pet.displayName)")
                        self.onImport(pet)
                        self.sendInstalledPets()
                    } catch {
                        self.evaluateImportResult(ok: false, message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func evaluateImportResult(ok: Bool, message: String) {
        evaluateJavaScriptEvent(
            name: "codex-pets-native-import-result",
            detail: [
                "ok": ok,
                "message": message,
            ]
        )
    }

    private func sendInstalledPets() {
        let pets = installedPetsProvider().map(Self.installedPetPayload)
        evaluateJavaScriptEvent(
            name: "codex-pets-native-installed-pets",
            detail: ["pets": pets]
        )
    }

    private func selectInstalledPet(from payload: Any?) {
        guard let pet = installedPet(for: payload) else {
            evaluateImportResult(ok: false, message: "Installed pet was not found")
            return
        }
        onSelectInstalled(pet)
        evaluateImportResult(ok: true, message: "Selected \(pet.displayName)")
        sendInstalledPets()
    }

    private func uninstallInstalledPet(from payload: Any?) {
        guard let pet = installedPet(for: payload) else {
            evaluateImportResult(ok: false, message: "Installed pet was not found")
            return
        }
        onUninstallInstalled(pet)
        evaluateImportResult(ok: true, message: "Removed \(pet.displayName)")
        sendInstalledPets()
    }

    private func installedPet(for payload: Any?) -> PetPackage? {
        guard let petID = Self.string(payload) else { return nil }
        return installedPetsProvider().first { $0.id == petID }
    }

    private func handleApprovalDecision(_ body: [String: Any]) {
        guard
            let approvalID = Self.string(body["approvalId"]),
            let decision = Self.string(body["decision"]),
            decision == "approved" || decision == "denied"
        else {
            evaluateImportResult(ok: false, message: "Approval response is incomplete")
            return
        }
        onApprovalDecision(approvalID, decision)
        evaluateImportResult(ok: true, message: decision == "approved" ? "Approved command" : "Denied command")
        sendDaemonSnapshot()
    }

    private func sendDaemonSnapshot() {
        daemonSnapshotProvider { [weak self] snapshot in
            guard let self, let snapshot else { return }
            self.sendDaemonSnapshot(snapshot)
        }
    }

    private func sendDaemonSnapshot(_ snapshot: DaemonSnapshot) {
        guard
            let data = try? JSONEncoder().encode(snapshot),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }
        evaluateJavaScriptEvent(
            name: "codex-pets-native-daemon-snapshot",
            detail: object
        )
    }

    private func evaluateJavaScriptEvent(name: String, detail: [String: Any]) {
        let payload = (try? JSONSerialization.data(withJSONObject: detail, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let script = """
        window.dispatchEvent(new CustomEvent("\(name)", { detail: \(payload) }));
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private static func browserIndexURL() -> URL? {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(
                resourceURL
                    .appendingPathComponent(Constants.browserResourceDirectory, isDirectory: true)
                    .appendingPathComponent("index.html")
            )
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("index.html")
        )
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func installedPetPayload(_ pet: PetPackage) -> [String: Any] {
        [
            "source": "installed",
            "nativePetId": pet.id,
            "slug": pet.slug,
            "displayName": pet.displayName,
            "description": pet.detail,
            "kind": pet.kind,
            "submittedBy": pet.source.label,
            "tags": [],
            "spritesheetUrl": pet.spritesheet.absoluteString,
            "frameWidth": pet.frameWidth,
            "frameHeight": pet.frameHeight,
            "canUninstall": pet.source == .app,
        ]
    }

    private static func shouldOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func entry(from payload: Any?) -> PetdexCatalogEntry? {
        guard let object = payload as? [String: Any] else { return nil }
        let slug = slugify(string(object["slug"]) ?? "")
        let displayName = string(object["displayName"]) ?? slug
        guard !slug.isEmpty, let spritesheetURL = webURL(object["spritesheetUrl"]) else {
            return nil
        }

        return PetdexCatalogEntry(
            slug: slug,
            displayName: displayName,
            detail: string(object["description"]) ?? "Animated Codex pet from Petdex.",
            kind: string(object["kind"]) ?? "pet",
            submittedBy: string(object["submittedBy"]) ?? "",
            tags: stringList(object["tags"]),
            spritesheetURL: spritesheetURL,
            petJSONURL: webURL(object["petJsonUrl"]),
            zipURL: webURL(object["zipUrl"]),
            frameWidth: positiveInt(object["frameWidth"]) ?? 192,
            frameHeight: positiveInt(object["frameHeight"]) ?? 208
        )
    }

    private static func webURL(_ value: Any?) -> URL? {
        guard let text = string(value),
              let url = URL(string: text),
              shouldOpenExternally(url)
        else {
            return nil
        }
        return url
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringList(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap(string).filter { !$0.isEmpty }
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        if let value = value as? Int, value > 0 { return value }
        if let value = value as? Double, value > 0 { return Int(value) }
        if let text = value as? String, let parsed = Int(text), parsed > 0 { return parsed }
        return nil
    }
}
