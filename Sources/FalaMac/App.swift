import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement
import FalaCore

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTabViewDelegate {
    private let recorder = Recorder()
    private let keyboard = Keyboard()
    private var history: HistoryStore!
    private var usage: UsageStore!
    private var spendForecast: SpendForecastStore!
    private var statusItem: NSStatusItem!
    private var cleanupTimer: Timer?
    private var workTask: Task<Void, Never>?
    private var state = "idle"
    private var releasePending = false
    private var recordingDir: URL!
    private var groqKey = ""
    private var routerKey = ""
    private var keysNeedAuthorization = false
    private var latestText = ""
    private var unsavedText: String?
    private var latestDate: Date?
    private var pendingOrganization: Entry?
    private var recordingJob = UUID()
    private var briefStatusTask: Task<Void, Never>?
    private var providerUsageTask: Task<Void, Never>?
    private var reportedRouterMonth: (Date, Double)?
    private var lastUsageRefresh: Date?
    private var lastAccessibilityAllowed = false

    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    private let tabs = NSTabView()
    private let consumption = ConsumptionView(frame: .zero)
    private let table = NSTableView()
    private let detail = NSTextView()
    private let search = NSSearchField()
    private let message = NSTextField(wrappingLabelWithString: "Ready. Use your recording shortcut.")
    private let diskLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let apiFields = NSStackView()
    private let extraSettings = NSStackView()
    private var editingKeys = false
    private lazy var accessButton = button("Allow Accessibility", #selector(accessibility))
    private lazy var unlockKeys = button("Unlock saved keys", #selector(authorizeKeys))
    private let keyLabel = NSTextField(wrappingLabelWithString: "")
    private let groqField = NSSecureTextField()
    private let routerField = NSSecureTextField()
    private let retention = NSPopUpButton()
    private let fnMode = NSPopUpButton()
    private let startup = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let pauseMusic = NSButton(checkboxWithTitle: "Pause music while recording", target: nil, action: nil)
    private let budget = NSTextField(string: "5")
    private var visibleEntries: [Entry] = []
    private var hud: NSPanel!
    private let hudLabel = NSTextField(labelWithString: "Recording…")
    private let hudMeter = NSProgressIndicator()
    private lazy var hudAccess = NSButton(title: "Allow paste", target: self, action: #selector(accessibility))
    private lazy var hudCopy = NSButton(title: "Copy text", target: self, action: #selector(copyLatest))
    private lazy var hudRetry = NSButton(title: "Retry cleanup", target: self, action: #selector(retryOrganization))
    private lazy var hudDismiss = NSButton(title: "Close", target: self, action: #selector(dismissHUD))
    private lazy var hudCancel = NSButton(title: "Cancel · Esc", target: self, action: #selector(cancelRecording))

    private var days: Int { UserDefaults.standard.object(forKey: "retentionDays") as? Int ?? 30 }
    private var budgetLimit: Double {
        let value = UserDefaults.standard.double(forKey: "monthlyBudget")
        return value > 0 ? value : 5
    }
    private var routerSpendForLimit: Double {
        guard let (date, amount) = reportedRouterMonth else { return 0 }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.isDate(date, equalTo: Date(), toGranularity: .month) ? amount : 0
    }
    private var fnSetting: Int { UserDefaults.standard.integer(forKey: "fnMode") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true).appendingPathComponent("FalaMac")
            history = try HistoryStore(directory: support)
            usage = try UsageStore(directory: support)
            spendForecast = try SpendForecastStore(directory: support)
            recordingDir = support.appendingPathComponent("Recordings")
            try FileManager.default.createDirectory(at: recordingDir, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try cleanRecordings()
            try history.clean(days: days)
        } catch {
            let alert = NSAlert(); alert.messageText = "Could not open FalaMac data"
            alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil); return
        }
        if !UserDefaults.standard.bool(forKey: "startupConfigured") {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "startupConfigured")
            } catch { /* Configuration view reports actual registration state. */ }
        }
        buildMenu(); buildWindow(); buildHUD()
        applyKeys(Keychain.loadAtLaunch("groq"), Keychain.loadAtLaunch("openrouter"))
        keyboard.toggle = { [weak self] in self?.toggleRecording() }
        keyboard.cancel = { [weak self] in self?.cancelRecording() }
        keyboard.fnChanged = { [weak self] down in
            guard let self else { return }
            if self.fnSetting == 1 {
                if down { if self.state == "idle" { self.beginRecording() } }
                else if self.state == "starting" { self.releasePending = true }
                else if self.state == "recording" { self.finishRecording() }
            } else if self.fnSetting == 2 && down { self.toggleRecording() }
        }
        keyboard.start(); keyboard.enableFn(fnSetting > 0)
        recorder.onLimit = { [weak self] in self?.finishRecording() }
        recorder.onFailure = { [weak self] in self?.cancelRecording(); self?.setMessage("Recording failed. Temporary audio was deleted.") }
        recorder.level = { [weak self] power in
            self?.hudMeter.doubleValue = Double(max(0, min(1, (power + 55) / 55)))
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                do { try self.history.clean(days: self.days); try self.usage.rollover(); self.expireSessionText(); self.refreshHistory() }
                catch { self.setMessage("Cleanup failed: \(error.localizedDescription)") }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        refreshHistory()
        if groqKey.isEmpty || routerKey.isEmpty { tabs.selectTabViewItem(at: 1); showWindow() }
        if keyboard.registrationFailed { setMessage("⌃⌥Space is already in use. Disable it in the other app, then reopen FalaMac.") }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) { refreshPermissionStatus() }

    func applicationWillTerminate(_ notification: Notification) {
        briefStatusTask?.cancel(); providerUsageTask?.cancel()
        workTask?.cancel(); recorder.cancel(); keyboard.stop(); cleanupTimer?.invalidate()
        try? history?.clean(days: days)
        if recordingDir != nil { try? cleanRecordings() }
    }

    @objc private func willSleep() {
        if state == "recording" || state == "starting" { cancelRecording() }
    }

    private func cleanRecordings() throws {
        for file in try FileManager.default.contentsOfDirectory(at: recordingDir, includingPropertiesForKeys: nil) {
            if file.pathExtension == "m4a" { try FileManager.default.removeItem(at: file) }
        }
    }

    @objc private func toggleRecording() {
        if state == "idle" { beginRecording() }
        else if state == "recording" { finishRecording() }
    }

    private func beginRecording() {
        guard state == "idle" else { return }
        guard !groqKey.isEmpty else {
            setMessage(keysNeedAuthorization ? "Open Settings and click Unlock saved keys."
                : "Add your Groq API key in Settings.")
            tabs.selectTabViewItem(at: 1); showWindow(); return
        }
        if unsavedText != nil {
            setMessage("Copy the unsaved text before recording again."); showWindow(); return
        }
        do { try usage.rollover() } catch { setMessage(error.localizedDescription); return }
        guard routerSpendForLimit + 0.01 <= budgetLimit else {
            setMessage("OpenRouter monthly spending target reached. Check Usage or adjust your limit in Settings.")
            showWindow(); return
        }
        pendingOrganization = nil
        releasePending = false; setState("starting")
        let job = UUID(); recordingJob = job
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.start(directory: recordingDir) {
                    if UserDefaults.standard.object(forKey: "pauseMusic") as? Bool ?? true { SystemMedia.pause() }
                }
                try Task.checkCancellation()
                setState("recording")
                if releasePending { finishRecording() }
            } catch {
                guard recordingJob == job else { return }
                recorder.cancel(); setState("idle")
                if !(error is CancellationError) { setMessage(error.localizedDescription) }
            }
        }
    }

    private func finishRecording() {
        guard state == "recording" else { return }
        let file: URL; let seconds: Double
        do { (file, seconds) = try recorder.stop() }
        catch { setState("idle"); setMessage(error.localizedDescription); return }
        setState("processing")
        workTask = Task { [weak self] in
            guard let self else { return }
            var feedback: String?
            var hasResult = false
            defer {
                do { try FileManager.default.removeItem(at: file) }
                catch { setMessage("Could not delete temporary audio. Open the data folder to check.") }
                setState("idle"); refreshHistory()
                if hasResult { showResultHUD(feedback ?? "Text ready"); refreshProviderUsage(force: true) }
                else if let feedback { showBriefStatus(feedback) }
            }
            do {
                let audio = try Data(contentsOf: file)
                guard audio.count <= 24 * 1024 * 1024 else { throw AppError.audioTooLarge }
                let reserved = try usage.reserve(seconds: seconds)
                let raw = try await AIClient.transcribe(audio: audio, key: groqKey)
                try Task.checkCancellation()
                // Keep the transcript before the second network request, so rewrite failures never lose it.
                latestText = raw; unsavedText = raw; latestDate = Date()
                var result = raw
                var organized = false
                var notice = ""
                var rewriteCost: Double?
                if !routerKey.isEmpty {
                    do {
                        let rewritten = try await AIClient.rewrite(text: raw, key: routerKey)
                        result = rewritten.text; organized = true; rewriteCost = rewritten.cost
                    } catch {
                        notice = "Cleanup failed. Your original transcript is safe. \(error.localizedDescription)"
                    }
                } else {
                    rewriteCost = 0
                    notice = "Transcript not cleaned up. Unlock or add your OpenRouter key in Settings."
                }
                // Local accounting failures must not discard a successful rewrite or prevent delivery.
                if let rewriteCost {
                    do { try usage.settle(reserved: reserved, seconds: seconds, rewriteCost: rewriteCost) }
                    catch { notice += " Could not update the local usage estimate." }
                }
                latestText = result; unsavedText = result; hasResult = true
                let entry = Entry(text: result, seconds: seconds, organized: organized)
                pendingOrganization = organized ? nil : entry
                do {
                    try history.add(entry, days: days)
                    if days > 0 { unsavedText = nil }
                } catch { notice += " Text ready, but history could not be saved: \(error.localizedDescription)" }
                // Never paste an unorganized fallback silently. Focus discovery is independent of rewriting.
                let deliveryResult = organized ? await InsertionTarget.deliver(result) : (false, nil)
                let inserted = deliveryResult.0
                if inserted { unsavedText = nil }
                let delivery = inserted ? "Paste sent. If the text does not appear, use Copy text in the floating bar."
                    : deliveryResult.1?.rawValue ?? "Use Copy text in the floating bar."
                setMessage(notice.isEmpty ? delivery : "\(notice) \(delivery)")
                refreshHistory(); detail.string = result
                if organized, deliveryResult.1 == .permission {
                    feedback = "Auto-paste blocked · allow Accessibility"
                } else {
                    feedback = organized ? (inserted ? "Cleaned up · paste sent" : "Cleaned up · ready to copy")
                        : "Not cleaned up · original transcript"
                }

            } catch {
                setMessage("Failed: \(error.localizedDescription). Temporary audio will be deleted.")
                feedback = "Transcription failed · open FalaMac for details"
            }
        }
    }

    @objc private func cancelRecording() {
        guard state == "starting" || state == "recording" else { return }
        recordingJob = UUID(); workTask?.cancel(); recorder.cancel(); releasePending = false; setState("idle")
        setMessage("Recording canceled. Nothing was sent.")
    }

    private func setState(_ next: String) {
        briefStatusTask?.cancel(); briefStatusTask = nil
        state = next
        keyboard.setCancellationActive(next == "starting" || next == "recording")
        hudCancel.isHidden = next != "starting" && next != "recording"
        hudMeter.isHidden = next != "recording"
        hudCopy.isHidden = true; hudRetry.isHidden = true; hudDismiss.isHidden = true; hudAccess.isHidden = true
        let image = next == "recording" ? "record.circle.fill" : next == "processing" ? "ellipsis.circle" : "waveform"
        statusItem?.button?.image = NSImage(systemSymbolName: image, accessibilityDescription: "FalaMac")
        statusItem?.button?.contentTintColor = next == "recording" ? .systemRed : nil
        if next == "starting" { hudLabel.stringValue = "Preparing microphone…"; hud.orderFrontRegardless() }
        else if next == "recording" { hudLabel.stringValue = "● Recording…"; hud.orderFrontRegardless() }
        else if next == "processing" { hudLabel.stringValue = "Cleaning up your text…"; hud.orderFrontRegardless() }
        else { hud?.orderOut(nil) }
        if next == "recording" { setMessage("Recording. Press your shortcut to finish. Up to 5 minutes.") }
        if next == "processing" { setMessage("Transcribing and cleaning up…") }
    }

    private func setMessage(_ text: String) { message.stringValue = text; message.toolTip = text; statusItem?.button?.toolTip = text }

    private func showBriefStatus(_ text: String) {
        briefStatusTask?.cancel()
        hudCancel.isHidden = true; hudMeter.isHidden = true
        hudCopy.isHidden = true; hudRetry.isHidden = true; hudDismiss.isHidden = true; hudAccess.isHidden = true
        hudLabel.stringValue = text; hud.orderFrontRegardless()
        briefStatusTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_500_000_000) }
            catch { return }
            guard let self, state == "idle" else { return }
            hud.orderOut(nil)
        }
    }

    private func showResultHUD(_ text: String) {
        guard state == "idle" else { return }
        briefStatusTask?.cancel(); briefStatusTask = nil
        hudLabel.stringValue = text
        hudMeter.isHidden = true; hudCancel.isHidden = true
        hudCopy.isHidden = false; hudDismiss.isHidden = false
        hudAccess.isHidden = AXIsProcessTrusted()
        hudRetry.isHidden = pendingOrganization == nil || !hudAccess.isHidden
        hud.orderFrontRegardless()
        // Keep this recovery action available until copied, dismissed, or a new recording starts.
    }

    @objc private func dismissHUD() { hud.orderOut(nil) }

    @objc private func retryOrganization() {
        guard state == "idle", let entry = pendingOrganization else { return }
        guard !routerKey.isEmpty else {
            setMessage("Unlock or add your OpenRouter key in Settings to clean up this transcript.")
            tabs.selectTabViewItem(at: 1); showWindow(); return
        }
        do { try usage.rollover() } catch { setMessage(error.localizedDescription); return }
        guard routerSpendForLimit + 0.01 <= budgetLimit else {
            setMessage("OpenRouter monthly spending target reached. Check Usage or adjust your limit in Settings.")
            showWindow(); return
        }
        setState("processing")
        workTask = Task { [weak self] in
            guard let self else { return }
            var feedback = "Not cleaned up · try again"
            defer { setState("idle"); refreshHistory(); showResultHUD(feedback) }
            do {
                let reservation = try usage.reserveRewrite()
                let rewritten = try await AIClient.rewrite(text: entry.text, key: routerKey)
                latestText = rewritten.text; unsavedText = rewritten.text; pendingOrganization = nil
                let updated = Entry(id: entry.id, date: entry.date, text: rewritten.text, seconds: entry.seconds, organized: true)
                var notice = "Text cleaned up. Use Copy text to paste it where you want."
                do { try usage.settleRewrite(reserved: reservation, cost: rewritten.cost) }
                catch { notice += " Could not update the local usage estimate." }
                do {
                    try history.add(updated, days: days)
                    if days > 0 { unsavedText = nil }
                } catch { notice += " Could not update local history." }
                detail.string = rewritten.text; setMessage(notice)
                feedback = "Cleaned up · ready to copy"
            } catch { setMessage("Cleanup failed. Your transcript is still available. \(error.localizedDescription)") }
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(); let appMenu = NSMenu(title: "FalaMac")
        appMenuItem.submenu = appMenu; mainMenu.addItem(appMenuItem)
        let recordMenu = appMenu.addItem(withTitle: "Start / stop recording", action: #selector(toggleRecording), keyEquivalent: "")
        recordMenu.target = self
        let mainQuit = appMenu.addItem(withTitle: "Quit FalaMac", action: #selector(quitApp), keyEquivalent: "q")
        mainQuit.target = self
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit"); editItem.submenu = edit; mainMenu.addItem(editItem)
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "FalaMac")
        let menu = NSMenu()
        for (title, action) in [("Open FalaMac", #selector(showWindow)), ("Usage", #selector(showConsumption)), ("Copy latest text", #selector(copyLatest)), ("Start / stop recording — ⌃⌥Space", #selector(toggleRecording)),
                                ("Cancel recording", #selector(cancelRecording))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit FalaMac", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        statusItem.menu = menu
    }

    @objc private func quitApp() {
        if state != "idle" || unsavedText != nil {
            let alert = NSAlert(); alert.messageText = "Quit FalaMac?"
            alert.informativeText = "The current recording or unsaved text will be lost."
            alert.addButton(withTitle: "Keep using FalaMac"); alert.addButton(withTitle: "Quit")
            if alert.runModal() != .alertSecondButtonReturn { return }
        }
        NSApp.terminate(nil)
    }

    @objc private func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    private func buildHUD() {
        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 56),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .floating; hud.isOpaque = false; hud.backgroundColor = .clear
        hud.ignoresMouseEvents = false; hud.becomesKeyOnlyIfNeeded = true; hud.hidesOnDeactivate = false
        hud.hasShadow = true; hud.appearance = NSAppearance(named: .vibrantDark)
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let effect = NSVisualEffectView(frame: hud.contentView!.bounds)
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true; effect.layer?.cornerRadius = 16; effect.layer?.masksToBounds = true
        hud.contentView = effect
        hudLabel.textColor = .white; hudLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hudLabel.lineBreakMode = .byTruncatingTail
        hudLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hudMeter.isIndeterminate = false; hudMeter.minValue = 0; hudMeter.maxValue = 1
        hudMeter.style = .bar; hudMeter.setAccessibilityLabel("Microphone level")
        for view in [hudLabel, hudMeter, hudCancel, hudCopy, hudRetry, hudDismiss, hudAccess] {
            view.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(view)
            view.centerYAnchor.constraint(equalTo: effect.centerYAnchor).isActive = true
        }
        for button in [hudCancel, hudCopy, hudRetry, hudDismiss, hudAccess] {
            button.refusesFirstResponder = true; button.bezelStyle = .rounded
        }
        // Fixed anchors keep controls still as the meter changes; hidden views retain their space.
        NSLayoutConstraint.activate([
            hudLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            hudLabel.trailingAnchor.constraint(equalTo: hudRetry.leadingAnchor, constant: -12),
            hudAccess.leadingAnchor.constraint(equalTo: hudRetry.leadingAnchor),
            hudAccess.trailingAnchor.constraint(equalTo: hudRetry.trailingAnchor),
            hudRetry.widthAnchor.constraint(equalToConstant: 150),
            hudRetry.trailingAnchor.constraint(equalTo: hudCopy.leadingAnchor, constant: -10),
            hudCopy.widthAnchor.constraint(equalToConstant: 112),
            hudCopy.trailingAnchor.constraint(equalTo: hudDismiss.leadingAnchor, constant: -10),
            hudDismiss.widthAnchor.constraint(equalToConstant: 65),
            hudDismiss.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            hudCancel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            hudCancel.widthAnchor.constraint(equalToConstant: 130),
            hudMeter.widthAnchor.constraint(equalToConstant: 100),
            hudMeter.trailingAnchor.constraint(equalTo: hudCancel.leadingAnchor, constant: -18)
        ])
        if let screen = NSScreen.main?.visibleFrame { hud.setFrameOrigin(NSPoint(x: screen.midX - 370, y: screen.minY + 40)) }
        hudCopy.isHidden = true; hudRetry.isHidden = true; hudDismiss.isHidden = true; hudAccess.isHidden = true; hudMeter.isHidden = true
    }

    private func buildWindow() {
        window.title = "FalaMac"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 760, height: 580); window.center()
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 12; root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = root
        let heading = NSTextField(labelWithString: "FalaMac"); heading.font = .systemFont(ofSize: 23, weight: .semibold)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let help = button("Help", #selector(showHelp)); help.bezelStyle = .inline
        let header = NSStackView(views: [heading, spacer, help]); header.alignment = .centerY
        root.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 2; message.lineBreakMode = .byTruncatingTail
        root.addArrangedSubview(message)
        tabs.translatesAutoresizingMaskIntoConstraints = false; root.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        let historyTab = NSTabViewItem(identifier: "history"); historyTab.label = "History"; historyTab.view = historyView(); tabs.addTabViewItem(historyTab)
        let settingsTab = NSTabViewItem(identifier: "settings"); settingsTab.label = "Settings"; settingsTab.view = settingsView(); tabs.addTabViewItem(settingsTab)
        let usageTab = NSTabViewItem(identifier: "usage"); usageTab.label = "Usage"; usageTab.view = consumption; tabs.addTabViewItem(usageTab)
        consumption.onRefresh = { [weak self] in self?.refreshProviderUsage(force: true) }
        tabs.delegate = self
    }

    private func historyView() -> NSView {
        let container = stack()
        search.placeholderString = "Search history"; search.delegate = self
        container.addArrangedSubview(search)
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text")); column.title = "Recent dictations"; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 55; table.delegate = self; table.dataSource = self
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        let textScroll = NSScrollView(); textScroll.documentView = detail; textScroll.hasVerticalScroller = true; textScroll.borderType = .bezelBorder
        detail.isEditable = false; detail.isSelectable = true; detail.isRichText = false
        detail.font = .systemFont(ofSize: 15); detail.textContainerInset = NSSize(width: 16, height: 16)
        detail.autoresizingMask = [.width]; detail.isVerticallyResizable = true
        detail.textContainer?.widthTracksTextView = true
        split.addArrangedSubview(list); split.addArrangedSubview(textScroll)
        list.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        textScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        split.setPosition(260, ofDividerAt: 0)
        container.addArrangedSubview(split)
        split.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -32).isActive = true
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let actions = NSStackView(views: [button("Copy text", #selector(copyText)), button("Latest text", #selector(showLatest)), button("Clear history", #selector(clearHistory))])
        actions.spacing = 10; container.addArrangedSubview(actions)
        diskLabel.font = .systemFont(ofSize: 11); diskLabel.textColor = .secondaryLabelColor; container.addArrangedSubview(diskLabel)
        return container
    }

    private func settingsView() -> NSView {
        let container = stack(flipped: true)
        container.spacing = 12
        container.addArrangedSubview(sectionTitle("Preferences"))
        retention.addItems(withTitles: ["Off", "1 day", "7 days", "30 days"])
        retention.selectItem(at: [0, 1, 7, 30].firstIndex(of: days) ?? 3)
        fnMode.addItems(withTitles: ["⌃⌥Space only", "Fn · hold to record", "Fn · press to start / stop"])
        fnMode.selectItem(at: min(fnSetting, 2))
        budget.stringValue = String(format: "%.2f", budgetLimit)
        budget.widthAnchor.constraint(equalToConstant: 90).isActive = true
        budget.toolTip = "OpenRouter target, checked against its latest reported monthly spend. Set a billing limit on your OpenRouter key too."
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Shortcut"), fnMode],
            [NSTextField(labelWithString: "Keep history"), retention],
            [NSTextField(labelWithString: "Monthly limit (USD)"), budget]
        ])
        grid.rowSpacing = 10; grid.columnSpacing = 24; grid.yPlacement = .center
        container.addArrangedSubview(grid)
        startup.state = SMAppService.mainApp.status == .enabled ? .on : .off
        container.addArrangedSubview(startup)
        pauseMusic.state = (UserDefaults.standard.object(forKey: "pauseMusic") as? Bool ?? true) ? .on : .off
        pauseMusic.toolTip = "Resume playback manually in your music app."
        container.addArrangedSubview(pauseMusic)
        let save = button("Save changes", #selector(saveSettings)); save.bezelStyle = .rounded
        container.addArrangedSubview(save)
        container.addArrangedSubview(sectionTitle("Connections"))
        permissionLabel.font = .systemFont(ofSize: 12)
        let access = NSStackView(views: [permissionLabel, accessButton,
                                       button("Test paste", #selector(testInsertion))])
        access.spacing = 10; access.alignment = .centerY; container.addArrangedSubview(access)
        refreshPermissionStatus()
        keyLabel.font = .systemFont(ofSize: 12)
        let keys = NSStackView(views: [keyLabel, unlockKeys]); keys.spacing = 10; keys.alignment = .centerY
        container.addArrangedSubview(keys)
        container.addArrangedSubview(button("Edit API keys…", #selector(toggleAPIFields)))
        apiFields.orientation = .vertical; apiFields.alignment = .leading; apiFields.spacing = 10
        groqField.placeholderString = "Groq API key"; routerField.placeholderString = "OpenRouter API key"
        groqField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        routerField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let apiGrid = NSGridView(views: [[NSTextField(labelWithString: "Groq"), groqField],
                                       [NSTextField(labelWithString: "OpenRouter"), routerField]])
        apiGrid.rowSpacing = 10; apiGrid.columnSpacing = 24; apiGrid.yPlacement = .center
        apiFields.addArrangedSubview(apiGrid)
        let apiActions = NSStackView(views: [button("Save keys", #selector(saveSettings)),
                                           button("Get Groq key", #selector(openGroq)), button("Get OpenRouter key", #selector(openRouter))])
        apiActions.spacing = 10; apiFields.addArrangedSubview(apiActions)
        apiFields.isHidden = true; container.addArrangedSubview(apiFields)
        container.addArrangedSubview(button("More options…", #selector(toggleExtraSettings)))
        extraSettings.orientation = .vertical; extraSettings.alignment = .leading; extraSettings.spacing = 10
        let tools = NSStackView(views: [button("Keyboard settings", #selector(openKeyboard)), button("Open data folder", #selector(openData))])
        tools.spacing = 10; extraSettings.addArrangedSubview(tools)
        extraSettings.isHidden = true; container.addArrangedSubview(extraSettings)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        container.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = container
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            container.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    @objc private func toggleAPIFields() {
        editingKeys.toggle(); apiFields.isHidden = !editingKeys
    }

    @objc private func toggleExtraSettings() { extraSettings.isHidden.toggle() }

    @objc private func showHelp() {
        let alert = NSAlert(); alert.messageText = "Using FalaMac"
        alert.informativeText = "Press your shortcut to start and stop recording. You can move to another field while speaking. If auto-paste fails, use Copy text in the floating bar, then ⌘V.\n\nTo use Fn, set “Press 🌐 key to” to “Do Nothing” in macOS Keyboard settings. Use Control + Space to switch input languages. Escape cancels an active recording.\n\nAudio is deleted after processing. History is kept for up to 30 days or 10 MB. API keys stay in macOS Keychain. Recordings are limited to 5 minutes.\n\nGroq transcribes audio; OpenRouter cleans up the text with Gemini 2.5 Flash Lite. Text stays in the language you speak. The monthly limit is a local estimate; set billing limits with both providers too."
        alert.addButton(withTitle: "Done"); alert.runModal()
    }

    private func stack(flipped: Bool = false) -> NSStackView {
        let view = flipped ? TopAlignedStackView() : NSStackView(); view.orientation = .vertical; view.alignment = .leading; view.spacing = 14
        view.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return view
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }

    @objc private func saveSettings() {
        guard state == "idle" else { setMessage("Finish recording before changing settings."); return }
        let normalized = budget.stringValue.replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(normalized), amount.isFinite, amount >= 0.05, amount <= 100 else {
            setMessage("Enter a monthly limit between $0.05 and $100."); return
        }
        do {
            if !groqField.stringValue.isEmpty { try Keychain.save(groqField.stringValue, account: "groq") }
            if !routerField.stringValue.isEmpty { try Keychain.save(routerField.stringValue, account: "openrouter") }
            groqField.stringValue = ""; routerField.stringValue = ""
            applyKeys(Keychain.load("groq"), Keychain.load("openrouter"))
            if !keysNeedAuthorization { Keychain.rememberAuthorization() }
            let previousDays = days
            let newDays = [0, 1, 7, 30][max(0, retention.indexOfSelectedItem)]
            if newDays < previousDays && !history.entries.isEmpty {
                let alert = NSAlert(); alert.messageText = "Keep less history?"
                alert.informativeText = "Text older than the new retention period will be deleted from this Mac."
                alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { retention.selectItem(at: [0, 1, 7, 30].firstIndex(of: previousDays) ?? 3); return }
            }
            try history.clean(days: newDays)
            UserDefaults.standard.set(newDays, forKey: "retentionDays")
            expireSessionText()
            UserDefaults.standard.set(amount, forKey: "monthlyBudget")
            UserDefaults.standard.set(pauseMusic.state == .on, forKey: "pauseMusic")
            UserDefaults.standard.set(fnMode.indexOfSelectedItem, forKey: "fnMode")
            keyboard.enableFn(fnSetting > 0)
            if startup.state == .on && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            else if startup.state == .off && SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(true, forKey: "startupConfigured")
            let requiresApproval = SMAppService.mainApp.status == .requiresApproval
            setMessage(requiresApproval ? "Settings saved. Allow FalaMac in System Settings → General → Login Items." : "Settings saved.")
            refreshHistory()
        } catch { setMessage("Check your settings: \(error.localizedDescription)") }
    }

    private func refreshKeyPlaceholders() {
        let unavailable = keysNeedAuthorization ? "Unlock saved keys first" : "Paste API key"
        groqField.placeholderString = groqKey.isEmpty ? unavailable : "Saved · enter a key to replace it"
        routerField.placeholderString = routerKey.isEmpty ? unavailable : "Saved · enter a key to replace it"
        keyLabel.stringValue = keysNeedAuthorization ? "Saved keys are locked."
            : (groqKey.isEmpty || routerKey.isEmpty ? "Add your API keys to get started." : "API keys connected.")
        keyLabel.textColor = keysNeedAuthorization ? .systemOrange : .secondaryLabelColor
        unlockKeys.isHidden = !keysNeedAuthorization
        if !keysNeedAuthorization && (groqKey.isEmpty || routerKey.isEmpty) { editingKeys = true }
        apiFields.isHidden = !editingKeys
    }

    private func applyKeys(_ groq: Keychain.Loaded, _ router: Keychain.Loaded) {
        let oldRouterKey = routerKey
        groqKey = groq.value ?? ""; routerKey = router.value ?? ""
        if oldRouterKey != routerKey {
            providerUsageTask?.cancel(); providerUsageTask = nil; lastUsageRefresh = nil
            consumption.reset(authorized: !routerKey.isEmpty)
        }
        if oldRouterKey != routerKey { reportedRouterMonth = nil }
        keysNeedAuthorization = groq.needsAuthorization || router.needsAuthorization
        refreshKeyPlaceholders()
        if !routerKey.isEmpty { refreshProviderUsage(force: false) }
    }

    @objc private func authorizeKeys() {
        guard state == "idle" else { return }
        setMessage("Approve the macOS Keychain prompts using your Mac login password.")
        setState("authorizing")
        workTask = Task { [weak self] in
            let values = await Task.detached {
                let groq = Keychain.load("groq", allowPrompt: true)
                // If access was denied, don't immediately ask a second time.
                let router = Keychain.load("openrouter", allowPrompt: !groq.needsAuthorization)
                return (groq, router)
            }.value
            guard let self else { return }
            applyKeys(values.0, values.1); setState("idle")
            if !keysNeedAuthorization { Keychain.rememberAuthorization() }
            setMessage(keysNeedAuthorization ? "Keys are locked. You can unlock them later in Settings."
                : "Keys unlocked. Ready to record.")
        }
    }

    private func refreshPermissionStatus() {
        let allowed = AXIsProcessTrusted()
        if allowed && !lastAccessibilityAllowed {
            keyboard.enableFn(fnSetting > 0)
            keyboard.setCancellationActive(state == "starting" || state == "recording")
        }
        lastAccessibilityAllowed = allowed
        permissionLabel.stringValue = allowed ? "Auto-paste is enabled."
            : "Allow Accessibility to paste into other apps."
        permissionLabel.textColor = allowed ? .systemGreen : .systemOrange
        accessButton.isHidden = allowed
    }

    @objc private func testInsertion() {
        guard state == "idle" else { return }
        guard AXIsProcessTrusted() else {
            setMessage(InsertionTarget.CaptureFailure.permission.rawValue)
            refreshPermissionStatus(); return
        }
        setMessage("Click a text field in another app within 5 seconds. No audio or API calls.")
        setState("testing")
        workTask = Task { [weak self] in
            guard let self else { return }
            var completed = false
            defer {
                setState("idle")
                if completed { showResultHUD("Test ready · check the paste or copy") }
            }
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                let sample = "FalaMac paste test."
                latestText = sample; latestDate = Date(); pendingOrganization = nil; completed = true
                let (inserted, failure) = await InsertionTarget.deliver(sample)
                if inserted {
                    setMessage("Test paste sent. Check the other app.")
                } else {
                    setMessage(failure?.rawValue ?? "Could not paste into this field. Try another field or use Copy text.")
                }
            } catch { setMessage("Test canceled.") }
        }
    }

    private func refreshHistory() {
        let query = search.stringValue
        visibleEntries = Array(history.entries.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }.prefix(200))
        table.reloadData()
        let bytes = (try? FileManager.default.attributesOfItem(atPath: history.directory.appendingPathComponent("history.json").path)[.size] as? Int) ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        diskLabel.stringValue = "\(history.entries.count) items · \(size) / 10 MB · \(days == 0 ? "history off" : "kept for \(days) days")"
        consumption.showLocal(usage.current, budget: budgetLimit)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if tabViewItem?.identifier as? String == "usage" { refreshProviderUsage(force: false) }
    }

    @objc private func showConsumption() { tabs.selectTabViewItem(at: 2); showWindow() }

    @objc private func copyLatest() {
        guard state == "idle" else { return }
        guard !latestText.isEmpty else { setMessage("No text in this session yet."); showBriefStatus("No text ready yet"); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(latestText, forType: .string)
        unsavedText = nil; setMessage("Text copied. Press ⌘V to paste.")
        showResultHUD("Copied · press ⌘V to paste")
    }

    private func refreshProviderUsage(force: Bool) {
        do { try usage.rollover() }
        catch { consumption.failed("Could not update local usage."); return }
        consumption.showLocal(usage.current, budget: budgetLimit)
        guard !routerKey.isEmpty else { consumption.reset(); return }
        guard providerUsageTask == nil else { return }
        if !force, let lastUsageRefresh, Date().timeIntervalSince(lastUsageRefresh) < 60 { return }
        let key = routerKey
        consumption.loading()
        providerUsageTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await ProviderUsageClient.fetch(key: key)
                guard !Task.isCancelled, routerKey == key else { return }
                let date = Date(); lastUsageRefresh = date
                if let spend = value.usageMonthly { reportedRouterMonth = (date, spend) }
                let forecast = try? spendForecast.observe(value, key: key, now: date)
                consumption.show(value, date: date, forecast: forecast)
            } catch {
                guard !Task.isCancelled, routerKey == key else { return }
                consumption.failed(error.localizedDescription)
            }
            providerUsageTask = nil
        }
    }

    private func expireSessionText() {
        if let latestDate, latestDate < Date().addingTimeInterval(-Double(max(1, days)) * 86400) {
            latestText = ""; unsavedText = nil; pendingOrganization = nil; self.latestDate = nil
            if state == "idle" { hud.orderOut(nil) }
        }
        if let selected = visibleEntries.indices.contains(table.selectedRow) ? visibleEntries[table.selectedRow] : nil,
           !history.entries.contains(where: { $0.id == selected.id }) { detail.string = "" }
        if latestText.isEmpty && table.selectedRow < 0 { detail.string = "" }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleEntries.indices.contains(row) else { return nil }
        let entry = visibleEntries[row]
        let date = entry.date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(Locale(identifier: "en_US")))
        let quality = entry.organized == false ? " · not cleaned up" : ""
        let label = NSTextField(wrappingLabelWithString: "\(date)\(quality)\n\(entry.text.prefix(80))")
        label.font = .systemFont(ofSize: 11); label.maximumNumberOfLines = 3
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = table.selectedRow
        if visibleEntries.indices.contains(index) { detail.string = visibleEntries[index].text }
    }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSSearchField === search { refreshHistory() } }

    @objc private func showLatest() {
        tabs.selectTabViewItem(at: 0); detail.string = latestText
        if latestText.isEmpty { setMessage("No result in this session yet.") }
    }
    @objc private func copyText() {
        guard !detail.string.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(detail.string, forType: .string)
        if detail.string == unsavedText { unsavedText = nil }
        setMessage("Text copied.")
    }
    @objc private func clearHistory() {
        guard state == "idle" else { setMessage("Wait for processing to finish before clearing history."); return }
        let alert = NSAlert(); alert.messageText = "Clear all history?"
        alert.informativeText = "This also clears the latest text in this session. Monthly usage totals are kept."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Clear")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try history.removeAll(); detail.string = ""; latestText = ""; unsavedText = nil; pendingOrganization = nil; hud.orderOut(nil); refreshHistory(); setMessage("History cleared.") }
        catch { setMessage(error.localizedDescription) }
    }

    @objc private func accessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openKeyboard() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        setMessage("In Keyboard settings, set “Press 🌐 key to” to “Do Nothing” to use Fn for recording.")
    }
    @objc private func openGroq() { NSWorkspace.shared.open(URL(string: "https://console.groq.com/keys")!) }
    @objc private func openRouter() { NSWorkspace.shared.open(URL(string: "https://openrouter.ai/settings/keys")!) }
    @objc private func openData() { NSWorkspace.shared.open(history.directory) }

    enum AppError: LocalizedError {
        case audioTooLarge
        var errorDescription: String? { "Audio exceeds the size limit and will be deleted." }
    }
}

/// A scroll document should stay at the top when optional rows are collapsed.
@MainActor
private final class TopAlignedStackView: NSStackView {
    override var isFlipped: Bool { true }
}
