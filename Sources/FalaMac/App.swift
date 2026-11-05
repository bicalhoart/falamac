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
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let recorder = Recorder()
    private let keyboard = Keyboard()
    private var history: HistoryStore!
    private var usage: UsageStore!
    private var statusItem: NSStatusItem!
    private var cleanupTimer: Timer?
    private var workTask: Task<Void, Never>?
    private var target: InsertionTarget?
    private var state = "idle"
    private var releasePending = false
    private var recordingDir: URL!
    private var groqKey = ""
    private var routerKey = ""
    private var latestText = ""
    private var unsavedText: String?
    private var latestDate: Date?
    private var recordingJob = UUID()

    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    private let tabs = NSTabView()
    private let table = NSTableView()
    private let detail = NSTextView()
    private let search = NSSearchField()
    private let message = NSTextField(wrappingLabelWithString: "Pronto. Use ⌃⌥Espaço para começar e terminar.")
    private let usageLabel = NSTextField(wrappingLabelWithString: "")
    private let diskLabel = NSTextField(wrappingLabelWithString: "")
    private let groqField = NSSecureTextField()
    private let routerField = NSSecureTextField()
    private let retention = NSPopUpButton()
    private let fnMode = NSPopUpButton()
    private let startup = NSButton(checkboxWithTitle: "Abrir ao entrar no Mac", target: nil, action: nil)
    private let budget = NSTextField(string: "5")
    private var visibleEntries: [Entry] = []
    private var hud: NSPanel!
    private let hudLabel = NSTextField(labelWithString: "Gravando…")

    private var days: Int { UserDefaults.standard.object(forKey: "retentionDays") as? Int ?? 30 }
    private var budgetLimit: Double {
        let value = UserDefaults.standard.double(forKey: "monthlyBudget")
        return value > 0 ? value : 5
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
            recordingDir = support.appendingPathComponent("Recordings")
            try FileManager.default.createDirectory(at: recordingDir, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try cleanRecordings()
            try history.clean(days: days)
        } catch {
            let alert = NSAlert(); alert.messageText = "Não foi possível abrir os dados do FalaMac"
            alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil); return
        }
        if !UserDefaults.standard.bool(forKey: "startupConfigured") {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "startupConfigured")
            } catch { /* Configuration view reports actual registration state. */ }
        }
        buildMenu(); buildWindow(); buildHUD()
        groqKey = Keychain.read("groq") ?? ""; routerKey = Keychain.read("openrouter") ?? ""
        refreshKeyPlaceholders()
        keyboard.toggle = { [weak self] in self?.toggleRecording() }
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
        recorder.onFailure = { [weak self] in self?.cancelRecording(); self?.setMessage("Falha na gravação. O áudio temporário foi descartado.") }
        recorder.level = { [weak self] power in
            let bars = String(repeating: "▰", count: max(1, min(12, Int((power + 55) / 5))))
            self?.hudLabel.stringValue = "● Gravando  \(bars)    ⌃⌥Espaço para terminar"
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                do { try self.history.clean(days: self.days); try self.usage.rollover(); self.expireSessionText(); self.refreshHistory() }
                catch { self.setMessage("Falha na limpeza: \(error.localizedDescription)") }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        refreshHistory()
        if groqKey.isEmpty || routerKey.isEmpty { tabs.selectTabViewItem(at: 1); showWindow() }
        if keyboard.registrationFailed { setMessage("O atalho ⌃⌥Espaço já está em uso. Libere-o em outro aplicativo e reabra o FalaMac.") }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        guard !groqKey.isEmpty else { setMessage("Cadastre a chave Groq em Configuração."); tabs.selectTabViewItem(at: 1); showWindow(); return }
        if unsavedText != nil {
            setMessage("Copie ou descarte o último texto na janela antes de gravar novamente."); showWindow(); return
        }
        do { try usage.rollover() } catch { setMessage(error.localizedDescription); return }
        guard usage.current.dollars + 0.014 <= budgetLimit else {
            setMessage("Limite mensal estimado atingido. Confira os gastos nos fornecedores ou ajuste o teto em Configuração.")
            showWindow(); return
        }
        target = InsertionTarget.capture(); releasePending = false; setState("starting")
        let job = UUID(); recordingJob = job
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.start(directory: recordingDir)
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
            defer {
                do { try FileManager.default.removeItem(at: file) }
                catch { setMessage("Não foi possível apagar o áudio temporário. Abra a pasta de dados para revisar.") }
                setState("idle"); refreshHistory()
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
                var notice = ""
                if !routerKey.isEmpty {
                    do {
                        let rewritten = try await AIClient.rewrite(text: raw, key: routerKey)
                        result = rewritten.text
                        try usage.settle(reserved: reserved, seconds: seconds, rewriteCost: rewritten.cost)
                    } catch {
                        notice = "A organização falhou; a transcrição original está disponível. \(error.localizedDescription)"
                    }
                } else {
                    try usage.settle(reserved: reserved, seconds: seconds, rewriteCost: 0)
                    notice = "Transcrição pronta. Cadastre a chave OpenRouter para organizar a fala."
                }
                latestText = result; unsavedText = result
                do {
                    try history.add(Entry(text: result, seconds: seconds), days: days)
                    if days > 0 { unsavedText = nil }
                } catch { notice = "Texto pronto, mas não foi possível salvar o histórico: \(error.localizedDescription)" }
                // A failed rewrite is reviewable in the window, never pasted without review.
                let inserted = notice.isEmpty && (target?.insert(result) ?? false)
                if inserted { unsavedText = nil }
                let delivery = inserted ? "Texto enviado ao campo ativo. Confira o resultado no aplicativo." : "Texto pronto na janela para copiar."
                setMessage(notice.isEmpty ? delivery : "\(notice) \(delivery)")
                if !inserted { refreshHistory(); showLatest(); showWindow() }
            } catch {
                setMessage("Falha: \(error.localizedDescription). O áudio temporário será apagado.")
            }
        }
    }

    @objc private func cancelRecording() {
        guard state == "starting" || state == "recording" else { return }
        recordingJob = UUID(); workTask?.cancel(); recorder.cancel(); releasePending = false; setState("idle")
        setMessage("Gravação descartada sem envio.")
    }

    private func setState(_ next: String) {
        state = next
        let image = next == "recording" ? "record.circle.fill" : next == "processing" ? "ellipsis.circle" : "waveform"
        statusItem?.button?.image = NSImage(systemSymbolName: image, accessibilityDescription: "FalaMac")
        statusItem?.button?.contentTintColor = next == "recording" ? .systemRed : nil
        if next == "recording" { hudLabel.stringValue = "● Gravando…"; hud.orderFrontRegardless() }
        else if next == "processing" { hudLabel.stringValue = "Organizando sua fala…"; hud.orderFrontRegardless() }
        else { hud?.orderOut(nil) }
        if next == "recording" { setMessage("Gravando. Use ⌃⌥Espaço para terminar. Limite: 5 minutos.") }
        if next == "processing" { setMessage("Transcrevendo e organizando…") }
    }

    private func setMessage(_ text: String) { message.stringValue = text }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(); let appMenu = NSMenu(title: "FalaMac")
        appMenuItem.submenu = appMenu; mainMenu.addItem(appMenuItem)
        let mainQuit = appMenu.addItem(withTitle: "Encerrar FalaMac", action: #selector(quitApp), keyEquivalent: "q")
        mainQuit.target = self
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Editar"); editItem.submenu = edit; mainMenu.addItem(editItem)
        edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "FalaMac")
        let menu = NSMenu()
        for (title, action) in [("Abrir FalaMac", #selector(showWindow)), ("Gravar / terminar — ⌃⌥Espaço", #selector(toggleRecording)),
                                ("Descartar gravação", #selector(cancelRecording))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Encerrar FalaMac", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        statusItem.menu = menu
    }

    @objc private func quitApp() {
        if state != "idle" || unsavedText != nil {
            let alert = NSAlert(); alert.messageText = "Encerrar o FalaMac?"
            alert.informativeText = "A gravação em andamento ou o texto ainda não salvo será descartado."
            alert.addButton(withTitle: "Continuar usando"); alert.addButton(withTitle: "Encerrar")
            if alert.runModal() != .alertSecondButtonReturn { return }
        }
        NSApp.terminate(nil)
    }

    @objc private func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    private func buildHUD() {
        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 52),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .floating; hud.isOpaque = false; hud.backgroundColor = .clear
        hud.ignoresMouseEvents = true; hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let effect = NSVisualEffectView(frame: hud.contentView!.bounds)
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 16
        hud.contentView = effect
        hudLabel.alignment = .center; hudLabel.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(hudLabel)
        NSLayoutConstraint.activate([hudLabel.centerXAnchor.constraint(equalTo: effect.centerXAnchor), hudLabel.centerYAnchor.constraint(equalTo: effect.centerYAnchor)])
        if let screen = NSScreen.main?.visibleFrame { hud.setFrameOrigin(NSPoint(x: screen.midX - 220, y: screen.minY + 40)) }
    }

    private func buildWindow() {
        window.title = "FalaMac"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 800, height: 600); window.center()
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 12; root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = root
        let heading = NSTextField(labelWithString: "FalaMac"); heading.font = .systemFont(ofSize: 25, weight: .semibold)
        root.addArrangedSubview(heading)
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor; root.addArrangedSubview(message)
        tabs.translatesAutoresizingMaskIntoConstraints = false; root.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        let historyTab = NSTabViewItem(identifier: "history"); historyTab.label = "Histórico"; historyTab.view = historyView(); tabs.addTabViewItem(historyTab)
        let settingsTab = NSTabViewItem(identifier: "settings"); settingsTab.label = "Configuração"; settingsTab.view = settingsView(); tabs.addTabViewItem(settingsTab)
    }

    private func historyView() -> NSView {
        let container = stack()
        search.placeholderString = "Buscar no histórico"; search.delegate = self
        container.addArrangedSubview(search)
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text")); column.title = "Falas recentes"; table.addTableColumn(column)
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
        container.addArrangedSubview(split); split.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let actions = NSStackView(views: [button("Copiar texto", #selector(copyText)), button("Último resultado", #selector(showLatest)), button("Apagar histórico", #selector(clearHistory))])
        actions.spacing = 10; container.addArrangedSubview(actions)
        diskLabel.font = .systemFont(ofSize: 11); diskLabel.textColor = .secondaryLabelColor; container.addArrangedSubview(diskLabel)
        usageLabel.font = .systemFont(ofSize: 11); usageLabel.textColor = .secondaryLabelColor; container.addArrangedSubview(usageLabel)
        return container
    }

    private func settingsView() -> NSView {
        let container = stack()
        let intro = NSTextField(wrappingLabelWithString: "Cadastre suas chaves para começar. Elas ficam no Chaves do macOS. O áudio vai à Groq; a transcrição vai ao OpenRouter para ser organizada.")
        container.addArrangedSubview(intro)
        groqField.placeholderString = "Chave Groq"; routerField.placeholderString = "Chave OpenRouter"
        groqField.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        routerField.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        retention.addItems(withTitles: ["Não guardar", "1 dia", "7 dias", "30 dias"])
        retention.selectItem(at: [0, 1, 7, 30].firstIndex(of: days) ?? 3)
        fnMode.addItems(withTitles: ["Somente ⌃⌥Espaço", "Fn: segurar para falar", "Fn: apertar para começar / terminar"])
        fnMode.selectItem(at: min(fnSetting, 2))
        budget.stringValue = String(format: "%.2f", budgetLimit); budget.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Groq"), groqField],
            [NSTextField(labelWithString: "OpenRouter"), routerField],
            [NSTextField(labelWithString: "Guardar histórico por"), retention],
            [NSTextField(labelWithString: "Atalho"), fnMode],
            [NSTextField(labelWithString: "Teto estimado mensal (US$)"), budget]
        ])
        grid.rowSpacing = 12; grid.columnSpacing = 18; grid.yPlacement = .center
        for row in 0..<5 { grid.row(at: row).height = 28 }
        grid.setContentHuggingPriority(.required, for: .vertical)
        grid.heightAnchor.constraint(equalToConstant: 188).isActive = true
        container.addArrangedSubview(grid)
        startup.state = SMAppService.mainApp.status == .enabled ? .on : .off
        container.addArrangedSubview(startup)
        container.addArrangedSubview(button("Salvar configuração", #selector(saveSettings)))
        let note = NSTextField(wrappingLabelWithString: "⌃⌥Espaço significa Control + Option + Espaço e funciona como liga/desliga. Para usar Fn, desative esse atalho no Typeless e selecione “Não fazer nada” para a tecla Globo nos ajustes do teclado. Autorize Acessibilidade para inserir texto e monitorar Fn.\n\nO teto acima é uma estimativa local. Configure também os limites de cobrança nas contas Groq e OpenRouter. Modelo: Gemini 2.5 Flash Lite. Áudios: até 5 minutos, apagados após o processamento. Histórico: até 30 dias ou 10 MB; limpeza ao abrir e a cada hora.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; container.addArrangedSubview(note)
        let links = NSStackView(views: [button("Abrir Groq", #selector(openGroq)), button("Abrir OpenRouter", #selector(openRouter)), button("Autorizar Acessibilidade", #selector(accessibility)), button("Pasta de dados", #selector(openData))])
        links.spacing = 10; container.addArrangedSubview(links)
        return container
    }

    private func stack() -> NSStackView {
        let view = NSStackView(); view.orientation = .vertical; view.alignment = .leading; view.spacing = 14
        view.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return view
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }

    @objc private func saveSettings() {
        guard state == "idle" else { setMessage("Termine a gravação antes de mudar a configuração."); return }
        let normalized = budget.stringValue.replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(normalized), amount.isFinite, amount >= 0.05, amount <= 100 else {
            setMessage("Informe um teto entre US$ 0,05 e US$ 100."); return
        }
        do {
            if !groqField.stringValue.isEmpty { try Keychain.save(groqField.stringValue, account: "groq") }
            if !routerField.stringValue.isEmpty { try Keychain.save(routerField.stringValue, account: "openrouter") }
            groqKey = Keychain.read("groq") ?? ""; routerKey = Keychain.read("openrouter") ?? ""
            groqField.stringValue = ""; routerField.stringValue = ""; refreshKeyPlaceholders()
            let previousDays = days
            let newDays = [0, 1, 7, 30][max(0, retention.indexOfSelectedItem)]
            if newDays < previousDays && !history.entries.isEmpty {
                let alert = NSAlert(); alert.messageText = "Reduzir o tempo do histórico?"
                alert.informativeText = "Os textos fora do novo prazo serão apagados deste Mac."
                alert.addButton(withTitle: "Aplicar"); alert.addButton(withTitle: "Cancelar")
                guard alert.runModal() == .alertFirstButtonReturn else { retention.selectItem(at: [0, 1, 7, 30].firstIndex(of: previousDays) ?? 3); return }
            }
            try history.clean(days: newDays)
            UserDefaults.standard.set(newDays, forKey: "retentionDays")
            expireSessionText()
            UserDefaults.standard.set(amount, forKey: "monthlyBudget")
            UserDefaults.standard.set(fnMode.indexOfSelectedItem, forKey: "fnMode")
            keyboard.enableFn(fnSetting > 0)
            if startup.state == .on && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            else if startup.state == .off && SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(true, forKey: "startupConfigured")
            let requiresApproval = SMAppService.mainApp.status == .requiresApproval
            setMessage(requiresApproval ? "Configuração salva. Autorize o FalaMac em Ajustes do Sistema → Geral → Itens de Início." : "Configuração salva. Use ⌃⌥Espaço para testar.")
            refreshHistory()
        } catch { setMessage("Confira a configuração: \(error.localizedDescription)") }
    }

    private func refreshKeyPlaceholders() {
        groqField.placeholderString = groqKey.isEmpty ? "Cole a chave Groq aqui" : "Chave salva — preencha apenas para trocar"
        routerField.placeholderString = routerKey.isEmpty ? "Cole a chave OpenRouter aqui" : "Chave salva — preencha apenas para trocar"
    }

    private func refreshHistory() {
        let query = search.stringValue
        visibleEntries = Array(history.entries.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }.prefix(200))
        table.reloadData()
        let bytes = (try? FileManager.default.attributesOfItem(atPath: history.directory.appendingPathComponent("history.json").path)[.size] as? Int) ?? 0
        diskLabel.stringValue = "\(history.entries.count) textos · histórico \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) / 10 MB · retenção \(days) dias. Busca em todo o histórico; lista de até 200 resultados."
        usageLabel.stringValue = String(format: "Mês: %d gravações · %.1f min · US$ %.4f estimados / US$ %.2f. Confira a cobrança nos fornecedores.", usage.current.recordings, usage.current.seconds / 60, usage.current.dollars, budgetLimit)
    }

    private func expireSessionText() {
        if let latestDate, latestDate < Date().addingTimeInterval(-Double(max(1, days)) * 86400) {
            latestText = ""; unsavedText = nil; self.latestDate = nil
        }
        if let selected = visibleEntries.indices.contains(table.selectedRow) ? visibleEntries[table.selectedRow] : nil,
           !history.entries.contains(where: { $0.id == selected.id }) { detail.string = "" }
        if latestText.isEmpty && table.selectedRow < 0 { detail.string = "" }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleEntries.indices.contains(row) else { return nil }
        let entry = visibleEntries[row]
        let date = entry.date.formatted(date: .abbreviated, time: .shortened)
        let label = NSTextField(wrappingLabelWithString: "\(date)\n\(entry.text.prefix(80))")
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
        if latestText.isEmpty { setMessage("Ainda não há resultado nesta sessão.") }
    }
    @objc private func copyText() {
        guard !detail.string.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(detail.string, forType: .string)
        if detail.string == unsavedText { unsavedText = nil }
        setMessage("Texto copiado.")
    }
    @objc private func clearHistory() {
        guard state == "idle" else { setMessage("Aguarde o processamento antes de apagar o histórico."); return }
        let alert = NSAlert(); alert.messageText = "Apagar todo o histórico local?"
        alert.informativeText = "Esta ação também apaga o último texto mantido na memória do FalaMac. O resumo mensal de consumo será preservado."
        alert.addButton(withTitle: "Cancelar"); alert.addButton(withTitle: "Apagar")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try history.removeAll(); detail.string = ""; latestText = ""; unsavedText = nil; refreshHistory(); setMessage("Histórico apagado.") }
        catch { setMessage(error.localizedDescription) }
    }

    @objc private func accessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openGroq() { NSWorkspace.shared.open(URL(string: "https://console.groq.com/keys")!) }
    @objc private func openRouter() { NSWorkspace.shared.open(URL(string: "https://openrouter.ai/settings/keys")!) }
    @objc private func openData() { NSWorkspace.shared.open(history.directory) }

    enum AppError: LocalizedError {
        case audioTooLarge
        var errorDescription: String? { "O áudio excede o limite de tamanho e será descartado." }
    }
}
