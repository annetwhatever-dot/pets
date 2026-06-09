import Foundation

enum PetSource: String, Codable {
    case app
    case petdex
    case codex

    var label: String {
        switch self {
        case .app: return "Imported"
        case .petdex: return "Petdex"
        case .codex: return "Codex"
        }
    }
}

struct PetAnimationState: Codable, Equatable {
    let id: String
    let label: String
    let row: Int
    let frames: Int
    let duration: TimeInterval

    static let defaults: [PetAnimationState] = [
        .init(id: "idle", label: "Idle", row: 0, frames: 6, duration: 0.16),
        .init(id: "running-right", label: "Run Right", row: 1, frames: 8, duration: 0.12),
        .init(id: "running-left", label: "Run Left", row: 2, frames: 8, duration: 0.12),
        .init(id: "waving", label: "Wave", row: 3, frames: 4, duration: 0.14),
        .init(id: "jumping", label: "Jump", row: 4, frames: 5, duration: 0.14),
        .init(id: "failed", label: "Failed", row: 5, frames: 8, duration: 0.14),
        .init(id: "waiting", label: "Waiting", row: 6, frames: 6, duration: 0.15),
        .init(id: "running", label: "Running", row: 7, frames: 6, duration: 0.12),
        .init(id: "review", label: "Review", row: 8, frames: 6, duration: 0.15),
    ]

    static func named(_ id: String, from states: [PetAnimationState]) -> PetAnimationState {
        states.first { $0.id == id } ?? states.first ?? defaults[0]
    }
}

struct PetPackage: Codable, Equatable {
    let slug: String
    let displayName: String
    let detail: String
    let kind: String
    let source: PetSource
    let directory: URL
    let spritesheet: URL
    let frameWidth: Int
    let frameHeight: Int
    let states: [PetAnimationState]

    var id: String {
        "\(source.rawValue):\(slug):\(directory.path)"
    }
}

enum PetLoadError: Error, LocalizedError {
    case missingManifest
    case missingSpritesheet
    case invalidManifest

    var errorDescription: String? {
        switch self {
        case .missingManifest: return "pet.json was not found."
        case .missingSpritesheet: return "spritesheet.webp or spritesheet.png was not found."
        case .invalidManifest: return "pet.json could not be parsed."
        }
    }
}

final class PetStore {
    private let fileManager = FileManager.default
    let appSupport: URL
    let importedPetsRoot: URL
    let runtimeRoot: URL

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPets", isDirectory: true)
        self.appSupport = base
        self.importedPetsRoot = base.appendingPathComponent("Pets", isDirectory: true)
        self.runtimeRoot = base.appendingPathComponent("Runtime", isDirectory: true)
        try? fileManager.createDirectory(at: importedPetsRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
    }

    func scan() -> [PetPackage] {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots: [(URL, PetSource)] = [
            (importedPetsRoot, .app),
            (home.appendingPathComponent(".petdex/pets", isDirectory: true), .petdex),
            (home.appendingPathComponent(".codex/pets", isDirectory: true), .codex),
        ]

        var pets: [PetPackage] = []
        var seenDirectories = Set<String>()
        for (root, source) in roots {
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard isDirectory(child), !seenDirectories.contains(child.path) else { continue }
                seenDirectories.insert(child.path)
                if let pet = try? loadPet(at: child, source: source) {
                    pets.append(pet)
                }
            }
        }

        return pets.sorted {
            if $0.source != $1.source { return sourceRank($0.source) < sourceRank($1.source) }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func importPetFolder(_ folder: URL) throws -> PetPackage {
        let loaded = try loadPet(at: folder, source: .app)
        let destinationName = uniqueFolderName(slugify(loaded.slug))
        let destination = importedPetsRoot.appendingPathComponent(destinationName, isDirectory: true)
        try fileManager.copyItem(at: folder, to: destination)
        return try loadPet(at: destination, source: .app)
    }

    func loadPet(at directory: URL, source: PetSource) throws -> PetPackage {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { throw PetLoadError.missingManifest }

        let data = try Data(contentsOf: manifestURL)
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PetLoadError.invalidManifest
        }

        let slugSeed = string(json["slug"]) ?? string(json["id"]) ?? directory.lastPathComponent
        let slug = slugify(slugSeed)
        let displayName = string(json["displayName"]) ?? string(json["name"]) ?? slugSeed
        let detail = string(json["description"]) ?? "Animated Codex-compatible pet."
        let kind = string(json["kind"]) ?? "pet"
        let spritesheetURL = try resolveSpritesheet(in: directory, manifest: json)
        let frameWidth = int(json["frameWidth"]) ?? 192
        let frameHeight = int(json["frameHeight"]) ?? 208

        return PetPackage(
            slug: slug,
            displayName: displayName,
            detail: detail,
            kind: kind,
            source: source,
            directory: directory,
            spritesheet: spritesheetURL,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            states: PetAnimationState.defaults
        )
    }

    private func resolveSpritesheet(in directory: URL, manifest: [String: Any]) throws -> URL {
        var names: [String] = []
        if let raw = string(manifest["spritesheetPath"]) ?? string(manifest["spritesheet"]) {
            names.append(raw)
        }
        names.append(contentsOf: [
            "spritesheet.webp",
            "spritesheet.png",
            "sprite.webp",
            "sprite.png",
        ])

        for name in names {
            let candidate = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw PetLoadError.missingSpritesheet
    }

    private func uniqueFolderName(_ base: String) -> String {
        let cleanBase = base.isEmpty ? "custom-pet" : base
        var candidate = cleanBase
        var index = 2
        while fileManager.fileExists(atPath: importedPetsRoot.appendingPathComponent(candidate).path) {
            candidate = "\(cleanBase)-\(index)"
            index += 1
        }
        return candidate
    }

    private func sourceRank(_ source: PetSource) -> Int {
        switch source {
        case .app: return 0
        case .petdex: return 1
        case .codex: return 2
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

func slugify(_ value: String) -> String {
    let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let allowed = folded.map { character -> Character in
        if character.isLetter || character.isNumber { return Character(character.lowercased()) }
        return "-"
    }
    var slug = String(allowed)
    while slug.contains("--") {
        slug = slug.replacingOccurrences(of: "--", with: "-")
    }
    slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return slug.isEmpty ? "custom-pet" : String(slug.prefix(64))
}

private func string(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func int(_ value: Any?) -> Int? {
    if let value = value as? Int { return value > 0 ? value : nil }
    if let value = value as? Double { return value > 0 ? Int(value) : nil }
    if let text = value as? String, let parsed = Int(text), parsed > 0 { return parsed }
    return nil
}
