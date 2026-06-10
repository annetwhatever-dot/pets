import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum DefaultsKey {
        static let attentionMode = "CodexPets.attentionMode"
        static let bubbleMode = "CodexPets.bubbleMode"
        static let followsSystemReduceMotion = "CodexPets.followsSystemReduceMotion"
        static let alwaysReduceMotion = "CodexPets.alwaysReduceMotion"
        static let showsInFullScreen = "CodexPets.showsInFullScreen"
    }

    private let store = PetStore()
    private let overlay = PetOverlayController()
    private var server: StateServer?
    private var inAppDaemon: InAppDaemon?
    private var daemonClient: DaemonClient?
    private var statusItem: NSStatusItem?
    private var petdexBrowser: PetdexBrowserWindowController?
    private var guiSmokeRecorder: GUISmokeRecorder?
    private var pets: [PetPackage] = []
    private var selectedPetID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guiSmokeRecorder = GUISmokeRecorder.fromEnvironment()
        guiSmokeRecorder?.recordLaunch()

        pets = store.scan()
        overlay.petBrowserRequestedHandler = { [weak self] in
            self?.openPetdexBrowser()
        }

        setupStatusItem()
        loadOverlaySettings()
        if StateServer.isDebugEnabled {
            server = StateServer(
                runtimeRoot: store.runtimeRoot,
                onState: { [weak self] state, duration in
                    self?.overlay.setState(state, duration: duration)
                },
                onBubble: { [weak self] text in
                self?.overlay.setBubble(text)
            },
            onEvent: { [weak self] type, label, importance in
                    self?.overlay.setEvent(type: type, label: label, importance: importance)
                }
            )
            server?.start()
        }

        let daemonSocketPath = DaemonClient.defaultSocketPath()
        inAppDaemon = InAppDaemon(socketPath: daemonSocketPath)
        inAppDaemon?.start()

        daemonClient = DaemonClient(socketPath: daemonSocketPath)
        daemonClient?.startSnapshotSubscription { [weak self] snapshot in
            self?.applyDaemonSnapshot(snapshot)
        }

        if let first = pets.first {
            selectPet(first)
        }
        publishInstalledPetsToDaemon()
        rebuildMenu()

        if ProcessInfo.processInfo.environment["CODEX_PETS_GUI_SMOKE_OPEN_BROWSER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.openPetdexBrowser()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        daemonClient?.stop()
        inAppDaemon?.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "CP"
        item.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        statusItem = item
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let title = NSMenuItem(title: "Codex Pets", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: overlay.isVisible ? "Tuck Away Pet" : "Wake Pet",
            action: #selector(togglePet),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.isEnabled = selectedPetID != nil
        menu.addItem(toggle)

        let browsePetdex = NSMenuItem(title: "Browse Petdex...", action: #selector(openPetdexBrowser), keyEquivalent: "b")
        browsePetdex.target = self
        menu.addItem(browsePetdex)

        let importItem = NSMenuItem(title: "Import Pet Folder...", action: #selector(importPetFolder), keyEquivalent: "i")
        importItem.target = self
        menu.addItem(importItem)

        let refreshItem = NSMenuItem(title: "Refresh Installed Pets", action: #selector(refreshPets), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(petsSubmenu())
        menu.addItem(statesSubmenu())
        menu.addItem(sizeSubmenu())
        menu.addItem(settingsSubmenu())

        menu.addItem(.separator())

        let hello = NSMenuItem(title: "Show Test Bubble", action: #selector(showTestBubble), keyEquivalent: "")
        hello.target = self
        hello.isEnabled = selectedPetID != nil
        menu.addItem(hello)

        if server != nil {
            let curl = NSMenuItem(title: "Copy Debug State API Curl", action: #selector(copyStateCurl), keyEquivalent: "")
            curl.target = self
            menu.addItem(curl)
        }

        let storage = NSMenuItem(title: "Open Storage Folder", action: #selector(openStorageFolder), keyEquivalent: "")
        storage.target = self
        menu.addItem(storage)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func petsSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Pets", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if pets.isEmpty {
            let empty = NSMenuItem(title: "No pets found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for pet in pets {
                let menuItem = NSMenuItem(
                    title: "\(pet.displayName) (\(pet.source.label))",
                    action: #selector(selectPetFromMenu(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.representedObject = pet.id
                menuItem.state = pet.id == selectedPetID ? .on : .off
                submenu.addItem(menuItem)
            }
        }
        item.submenu = submenu
        return item
    }

    private func statesSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "State", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for state in PetAnimationState.defaults {
            let stateItem = NSMenuItem(title: state.label, action: #selector(selectState(_:)), keyEquivalent: "")
            stateItem.target = self
            stateItem.representedObject = state.id
            stateItem.state = state.id == overlay.currentStateID ? .on : .off
            stateItem.isEnabled = selectedPetID != nil
            submenu.addItem(stateItem)
        }
        item.submenu = submenu
        return item
    }

    private func sizeSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let sizes: [(String, CGFloat)] = [
            ("Small", 0.58),
            ("Normal", 0.76),
            ("Large", 1.0),
            ("Huge", 1.24),
        ]
        for (label, value) in sizes {
            let sizeItem = NSMenuItem(title: label, action: #selector(selectSize(_:)), keyEquivalent: "")
            sizeItem.target = self
            sizeItem.representedObject = value
            sizeItem.state = abs(overlay.scale - value) < 0.01 ? .on : .off
            submenu.addItem(sizeItem)
        }
        item.submenu = submenu
        return item
    }

    private func settingsSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let animation = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        let animationSubmenu = NSMenu()
        for mode in PetAttentionMode.allCases {
            let modeItem = NSMenuItem(title: mode.label, action: #selector(selectAttentionMode(_:)), keyEquivalent: "")
            modeItem.target = self
            modeItem.representedObject = mode.rawValue
            modeItem.state = overlay.attentionMode == mode ? .on : .off
            animationSubmenu.addItem(modeItem)
        }
        animation.submenu = animationSubmenu
        submenu.addItem(animation)

        let bubbles = NSMenuItem(title: "Bubbles", action: nil, keyEquivalent: "")
        let bubblesSubmenu = NSMenu()
        for mode in PetBubbleMode.allCases {
            let bubbleItem = NSMenuItem(title: mode.label, action: #selector(selectBubbleMode(_:)), keyEquivalent: "")
            bubbleItem.target = self
            bubbleItem.representedObject = mode.rawValue
            bubbleItem.state = overlay.bubbleMode == mode ? .on : .off
            bubblesSubmenu.addItem(bubbleItem)
        }
        bubbles.submenu = bubblesSubmenu
        submenu.addItem(bubbles)

        let muteToday = NSMenuItem(title: "Mute Murmurs Today", action: #selector(muteMurmursToday), keyEquivalent: "")
        muteToday.target = self
        submenu.addItem(muteToday)

        submenu.addItem(.separator())

        let followReduce = NSMenuItem(
            title: "Reduced Motion: Follow System",
            action: #selector(toggleFollowSystemReduceMotion),
            keyEquivalent: ""
        )
        followReduce.target = self
        followReduce.state = overlay.followsSystemReduceMotion ? .on : .off
        submenu.addItem(followReduce)

        let alwaysReduce = NSMenuItem(
            title: "Reduced Motion: Always Reduce",
            action: #selector(toggleAlwaysReduceMotion),
            keyEquivalent: ""
        )
        alwaysReduce.target = self
        alwaysReduce.state = overlay.alwaysReduceMotion ? .on : .off
        submenu.addItem(alwaysReduce)

        submenu.addItem(.separator())

        let fullScreen = NSMenuItem(
            title: "Show in Full-Screen Apps",
            action: #selector(toggleShowInFullScreen),
            keyEquivalent: ""
        )
        fullScreen.target = self
        fullScreen.state = overlay.showsInFullScreen ? .on : .off
        submenu.addItem(fullScreen)

        let mouseMode = NSMenuItem(title: "Mouse Reactions: Near Pet Only", action: nil, keyEquivalent: "")
        mouseMode.isEnabled = false
        submenu.addItem(mouseMode)

        let permissionMode = NSMenuItem(title: "Anywhere Reactions Require Input Monitoring", action: nil, keyEquivalent: "")
        permissionMode.isEnabled = false
        submenu.addItem(permissionMode)

        item.submenu = submenu
        return item
    }

    private func selectPet(_ pet: PetPackage, publish: Bool = true) {
        selectedPetID = pet.id
        overlay.setPet(pet)
        overlay.setBubble("")
        if publish {
            daemonClient?.selectPet(pet.id)
        }
        rebuildMenu()
    }

    @objc private func togglePet() {
        overlay.toggle()
        rebuildMenu()
    }

    @objc private func openPetdexBrowser() {
        if petdexBrowser == nil {
            petdexBrowser = makePetdexBrowser()
        }
        petdexBrowser?.prepareForDisplay()
        NSApp.activate(ignoringOtherApps: true)
        petdexBrowser?.showWindow(nil)
        petdexBrowser?.window?.makeKeyAndOrderFront(nil)
    }

    private func makePetdexBrowser() -> PetdexBrowserWindowController {
        let controller = PetdexBrowserWindowController(
            store: store,
            installedPetsProvider: { [weak self] in
                self?.pets ?? []
            },
            onImport: { [weak self] pet in
                guard let self else { return }
                self.pets = self.store.scan()
                self.selectPet(self.pets.first { $0.directory.path == pet.directory.path } ?? pet)
                self.publishInstalledPetsToDaemon()
                self.overlay.setBubble("Imported \(pet.displayName)")
            },
            onSelectInstalled: { [weak self] pet in
                guard let self else { return }
                self.selectPet(pet)
                self.publishInstalledPetsToDaemon()
            },
            onBrowserLoaded: { [weak self] payload in
                self?.guiSmokeRecorder?.recordPetdexBrowser(payload)
            }
        )
        controller.window?.isReleasedWhenClosed = false
        return controller
    }

    @objc private func importPetFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Import Codex Pet Folder"
        panel.message = "Choose a folder containing pet.json and spritesheet.webp or spritesheet.png."
        panel.prompt = "Import"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            rebuildMenu()
            return
        }

        do {
            let pet = try store.importPetFolder(url)
            pets = store.scan()
            selectPet(pets.first { $0.directory.path == pet.directory.path } ?? pet)
            publishInstalledPetsToDaemon()
            overlay.setBubble("Imported \(pet.displayName)")
        } catch {
            showError(error)
        }
        rebuildMenu()
    }

    @objc private func refreshPets() {
        pets = store.scan()
        if let selectedPetID, let selected = pets.first(where: { $0.id == selectedPetID }) {
            overlay.setPet(selected)
        } else if let first = pets.first {
            selectPet(first)
        } else {
            selectedPetID = nil
            overlay.setPet(nil)
            overlay.hide()
        }
        publishInstalledPetsToDaemon()
        rebuildMenu()
    }

    @objc private func selectPetFromMenu(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? String,
            let pet = pets.first(where: { $0.id == id })
        else {
            return
        }
        selectPet(pet)
    }

    @objc private func selectState(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        overlay.setState(id)
        rebuildMenu()
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? CGFloat else { return }
        overlay.setScale(size)
        rebuildMenu()
    }

    @objc private func selectAttentionMode(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let mode = PetAttentionMode(rawValue: raw)
        else { return }
        overlay.setAttentionMode(mode)
        UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.attentionMode)
        rebuildMenu()
    }

    @objc private func selectBubbleMode(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let mode = PetBubbleMode(rawValue: raw)
        else { return }
        overlay.setBubbleMode(mode)
        UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.bubbleMode)
        rebuildMenu()
    }

    @objc private func muteMurmursToday() {
        overlay.muteMurmursForToday()
        rebuildMenu()
    }

    @objc private func toggleFollowSystemReduceMotion() {
        let next = !overlay.followsSystemReduceMotion
        overlay.setFollowsSystemReduceMotion(next)
        UserDefaults.standard.set(next, forKey: DefaultsKey.followsSystemReduceMotion)
        rebuildMenu()
    }

    @objc private func toggleAlwaysReduceMotion() {
        let next = !overlay.alwaysReduceMotion
        overlay.setAlwaysReduceMotion(next)
        UserDefaults.standard.set(next, forKey: DefaultsKey.alwaysReduceMotion)
        rebuildMenu()
    }

    @objc private func toggleShowInFullScreen() {
        let next = !overlay.showsInFullScreen
        overlay.setShowsInFullScreen(next)
        UserDefaults.standard.set(next, forKey: DefaultsKey.showsInFullScreen)
        rebuildMenu()
    }

    @objc private func showTestBubble() {
        overlay.setBubble("Codex Pets is awake")
    }

    @objc private func copyStateCurl() {
        guard let snippet = server?.copyCurlSnippet() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
    }

    @objc private func openStorageFolder() {
        NSWorkspace.shared.open(store.appSupport)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not import pet"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func applyDaemonSnapshot(_ snapshot: DaemonSnapshot) {
        if let selectedPetID = snapshot.selectedPetId,
           selectedPetID != self.selectedPetID,
           let selected = pets.first(where: { $0.id == selectedPetID })
        {
            selectPet(selected, publish: false)
        }
        let presentation = DaemonSnapshotPresenter.presentation(for: snapshot)
        overlay.applyDaemonSnapshot(snapshot)
        guiSmokeRecorder?.recordSnapshot(snapshot, presentation: presentation, overlayState: overlay.currentStateID)
    }

    private func publishInstalledPetsToDaemon() {
        daemonClient?.publishInstalledPets(pets)
        if let selectedPetID {
            daemonClient?.selectPet(selectedPetID)
        }
    }

    private func loadOverlaySettings() {
        let defaults = UserDefaults.standard
        let attentionMode = PetAttentionMode(rawValue: defaults.string(forKey: DefaultsKey.attentionMode) ?? "") ?? .default
        let bubbleMode = PetBubbleMode(rawValue: defaults.string(forKey: DefaultsKey.bubbleMode) ?? "") ?? .all
        let followsSystemReduceMotion = defaults.object(forKey: DefaultsKey.followsSystemReduceMotion) as? Bool ?? true
        let alwaysReduceMotion = defaults.bool(forKey: DefaultsKey.alwaysReduceMotion)
        let showsInFullScreen = defaults.bool(forKey: DefaultsKey.showsInFullScreen)

        overlay.applySettings(
            attentionMode: attentionMode,
            bubbleMode: bubbleMode,
            followsSystemReduceMotion: followsSystemReduceMotion,
            alwaysReduceMotion: alwaysReduceMotion,
            showsInFullScreen: showsInFullScreen
        )
    }
}

final class GUISmokeRecorder {
    private let url: URL
    private let queue = DispatchQueue(label: "CodexPets.GUISmokeRecorder")
    private let dateFormatter = ISO8601DateFormatter()

    private init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    static func fromEnvironment() -> GUISmokeRecorder? {
        guard
            let path = ProcessInfo.processInfo.environment["CODEX_PETS_GUI_SMOKE_FILE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            return nil
        }
        return GUISmokeRecorder(url: URL(fileURLWithPath: path))
    }

    func recordLaunch() {
        write([
            "event": "launch",
            "pid": ProcessInfo.processInfo.processIdentifier,
        ])
    }

    func recordSnapshot(_ snapshot: DaemonSnapshot, presentation: DaemonOverlayPresentation, overlayState: String) {
        write([
            "event": "snapshot",
            "attention": snapshot.attention,
            "stateID": presentation.stateID,
            "overlayState": overlayState,
            "bubble": presentation.bubble ?? "",
            "sessions": snapshot.sessions.count,
            "pendingApprovals": snapshot.pendingApprovals.count,
            "installedPets": snapshot.installedPets.count,
            "selectedPetId": snapshot.selectedPetId ?? "",
        ])
    }

    func recordPetdexBrowser(_ payload: [String: Any]) {
        write(payload)
    }

    private func write(_ fields: [String: Any]) {
        queue.async { [url, dateFormatter] in
            var object = fields
            object["timestamp"] = dateFormatter.string(from: Date())
            guard
                JSONSerialization.isValidJSONObject(object),
                var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            else {
                return
            }
            data.append(0x0a)
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        }
    }
}
