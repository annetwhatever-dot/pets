import Cocoa
import Foundation

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

final class PetdexBrowserWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: PetStore
    private let client: PetdexCatalogClient
    private let onImport: (PetPackage) -> Void

    private var entries: [PetdexCatalogEntry] = []
    private var filteredEntries: [PetdexCatalogEntry] = []
    private var selectedEntry: PetdexCatalogEntry?
    private var previewTask: URLSessionDataTask?

    private let searchField = NSSearchField(frame: .zero)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let importButton = NSButton(title: "Import & Use", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Petdex", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Loading Petdex…")
    private let tableView = NSTableView(frame: .zero)
    private let imageView = NSImageView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "Select a pet")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    init(
        store: PetStore,
        client: PetdexCatalogClient = PetdexCatalogClient(),
        onImport: @escaping (PetPackage) -> Void
    ) {
        self.store = store
        self.client = client
        self.onImport = onImport
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Browse Petdex"
        window.minSize = NSSize(width: 700, height: 460)
        super.init(window: window)
        setupUI()
        loadCatalog()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        previewTask?.cancel()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredEntries.indices.contains(row) else { return nil }
        let entry = filteredEntries[row]
        let identifier = NSUserInterfaceItemIdentifier("PetdexCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.font = NSFont.systemFont(ofSize: 13, weight: tableColumn?.identifier.rawValue == "name" ? .semibold : .regular)
        textField.stringValue = value(for: tableColumn?.identifier.rawValue ?? "name", entry: entry)
        if cell.textField == nil {
            cell.textField = textField
            cell.addSubview(textField)
            textField.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedEntry = filteredEntries.indices.contains(row) ? filteredEntries[row] : nil
        renderSelectedEntry()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        searchField.placeholderString = "Search Petdex pets"
        searchField.delegate = self
        refreshButton.target = self
        refreshButton.action = #selector(refreshCatalog)
        importButton.target = self
        importButton.action = #selector(importSelectedPet)
        importButton.isEnabled = false
        openButton.target = self
        openButton.action = #selector(openSelectedPetdexPage)
        openButton.isEnabled = false

        statusLabel.textColor = .secondaryLabelColor
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4
        metaLabel.textColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        imageView.layer?.cornerRadius = 12

        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 30
        tableView.headerView = nil
        tableView.addTableColumn(column("name", title: "Name", width: 220))
        tableView.addTableColumn(column("kind", title: "Kind", width: 90))
        tableView.addTableColumn(column("by", title: "By", width: 120))
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let toolbar = NSStackView(views: [searchField, refreshButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.alignment = .centerY
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        let details = NSStackView(views: [imageView, nameLabel, metaLabel, detailLabel, importButton, openButton])
        details.orientation = .vertical
        details.spacing = 10
        details.alignment = .leading
        imageView.widthAnchor.constraint(equalToConstant: 240).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 240).isActive = true
        nameLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        importButton.bezelStyle = .rounded
        openButton.bezelStyle = .rounded

        let body = NSStackView(views: [scrollView, details])
        body.orientation = .horizontal
        body.spacing = 16
        body.alignment = .top
        scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true

        let root = NSStackView(views: [toolbar, body, statusLabel])
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func column(_ id: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.resizingMask = .autoresizingMask
        return column
    }

    private func value(for column: String, entry: PetdexCatalogEntry) -> String {
        switch column {
        case "kind": return entry.kind
        case "by": return entry.submittedBy.isEmpty ? "Petdex" : entry.submittedBy
        default: return entry.displayName
        }
    }

    private func loadCatalog() {
        setStatus("Loading Petdex…")
        refreshButton.isEnabled = false
        client.loadCatalog { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshButton.isEnabled = true
                switch result {
                case let .success(entries):
                    self.entries = entries
                    self.applyFilter(selectFirst: true)
                    self.setStatus("Loaded \(entries.count) Petdex pets")
                case let .failure(error):
                    self.entries = []
                    self.applyFilter(selectFirst: false)
                    self.setStatus(error.localizedDescription)
                }
            }
        }
    }

    private func applyFilter(selectFirst: Bool = false) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filteredEntries = entries
        } else {
            filteredEntries = entries.filter { entry in
                [entry.displayName, entry.slug, entry.kind, entry.submittedBy, entry.detail]
                    .joined(separator: " ")
                    .lowercased()
                    .contains(query)
                    || entry.tags.joined(separator: " ").lowercased().contains(query)
            }
        }
        tableView.reloadData()
        if selectFirst, !filteredEntries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else if let selectedEntry,
                  let index = filteredEntries.firstIndex(of: selectedEntry)
        {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
            self.selectedEntry = nil
            renderSelectedEntry()
        }
        setStatus("\(filteredEntries.count) of \(entries.count) Petdex pets")
    }

    private func renderSelectedEntry() {
        guard let entry = selectedEntry else {
            nameLabel.stringValue = "Select a pet"
            metaLabel.stringValue = ""
            detailLabel.stringValue = ""
            imageView.image = nil
            importButton.isEnabled = false
            openButton.isEnabled = false
            return
        }

        nameLabel.stringValue = entry.displayName
        metaLabel.stringValue = [entry.kind, entry.submittedBy].filter { !$0.isEmpty }.joined(separator: " • ")
        detailLabel.stringValue = entry.detail
        importButton.isEnabled = true
        openButton.isEnabled = entry.petdexURL != nil
        loadPreview(for: entry)
    }

    private func loadPreview(for entry: PetdexCatalogEntry) {
        previewTask?.cancel()
        imageView.image = nil
        var request = URLRequest(url: entry.spritesheetURL)
        request.setValue("CodexPets/1.0", forHTTPHeaderField: "User-Agent")
        previewTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  let image = NSImage(data: data)
            else { return }
            let preview = Self.firstFrameImage(from: image, frameWidth: entry.frameWidth, frameHeight: entry.frameHeight)
            DispatchQueue.main.async {
                if self.selectedEntry == entry {
                    self.imageView.image = preview
                }
            }
        }
        previewTask?.resume()
    }

    private static func firstFrameImage(from image: NSImage, frameWidth: Int, frameHeight: Int) -> NSImage {
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

    @objc private func refreshCatalog() {
        loadCatalog()
    }

    @objc private func openSelectedPetdexPage() {
        guard let url = selectedEntry?.petdexURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func importSelectedPet() {
        guard let entry = selectedEntry else { return }
        setStatus("Importing \(entry.displayName)…")
        importButton.isEnabled = false
        client.downloadPackage(for: entry) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.importButton.isEnabled = self.selectedEntry != nil
                switch result {
                case let .failure(error):
                    self.setStatus(error.localizedDescription)
                case let .success(package):
                    do {
                        let pet = try self.store.importDownloadedPetdexPet(
                            entry,
                            petJSON: package.petJSON,
                            spritesheet: package.spritesheet,
                            spritesheetExtension: package.spritesheetExtension
                        )
                        self.setStatus("Imported \(pet.displayName)")
                        self.onImport(pet)
                    } catch {
                        self.setStatus(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func setStatus(_ message: String) {
        statusLabel.stringValue = message
    }
}
