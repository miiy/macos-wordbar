// WordBar — a macOS menu bar vocabulary flashcard app.
// Vocabulary: any .txt under ~/.config/wordbar (default words.txt), switchable
// in the menu or via Choose File…. Format: word|meaning|example|exampleTranslation

import AVFoundation
import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

struct WordEntry: Equatable {
    let word: String
    let meaning: String
    let example: String
    let exampleTranslation: String
}

enum WordParser {
    static func parse(_ text: String) -> [WordEntry] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if let sep = ["|", "\t"].first(where: { line.contains($0) }) {
                let parts = line.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
                guard let w = parts.first, !w.isEmpty else { return nil }
                return WordEntry(word: w,
                                 meaning: parts.count > 1 ? parts[1] : "",
                                 example: parts.count > 2 ? parts[2] : "",
                                 exampleTranslation: parts.count > 3 ? parts[3...].joined(separator: sep) : "")
            }
            for sep in [" - ", ","] {
                if let range = line.range(of: sep) {
                    let w = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let m = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !w.isEmpty { return WordEntry(word: w, meaning: m, example: "", exampleTranslation: "") }
                }
            }
            return WordEntry(word: line, meaning: "", example: "", exampleTranslation: "")
        }
    }
}

final class ClickableLabel: NSTextField {
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onLeftClick?() }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Horizontal scroll container that also maps vertical wheel deltas to horizontal scrolling.
final class HScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if abs(dy) > abs(dx) {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            let maxX = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
            var o = contentView.bounds.origin
            o.x = min(max(0, o.x - dy * scale), maxX)
            contentView.scroll(to: o)
            return
        }
        super.scrollWheel(with: event)
    }
}

final class WordPanel: NSPanel {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onMemorize: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76: onMemorize?()
        case 53: orderOut(nil)
        case 123: onPrevious?()
        case 124: onNext?()
        default: super.keyDown(with: event)
        }
    }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let scrollView = HScrollView()
    private let docView = NSView()
    private let wordLabel = ClickableLabel(labelWithString: "")
    private let checkLabel = ClickableLabel(labelWithString: "✓")
    private var entries: [WordEntry] = []
    private var memorized: Set<String> = []
    private var current: WordEntry?
    private var history: [WordEntry] = []
    private var lastWordsMod: Date?
    private var showMeaning = UserDefaults.standard.bool(forKey: "showMeaning")
    private var showExample = UserDefaults.standard.bool(forKey: "showExample")
    private let speech = AVSpeechSynthesizer()
    private var browsePanel: NSPanel?
    private var browseTable: NSTableView?
    private var detailPanel: WordPanel?
    private var detailStack: NSStackView?
    private let detailWord = NSTextField(wrappingLabelWithString: "")
    private let detailMeaning = NSTextField(wrappingLabelWithString: "")
    private let detailExample = NSTextField(wrappingLabelWithString: "")
    private let detailTranslation = NSTextField(wrappingLabelWithString: "")
    private let detailProgress = NSTextField(wrappingLabelWithString: "")
    private var detailPreviousButton: NSButton?
    private var detailMemorizeButton: NSButton?
    private var detailExampleRow: NSStackView?
    private let detailPanelWidth: CGFloat = 460

    private let configDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/wordbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var defaultWordsURL: URL { configDir.appendingPathComponent("words.txt") }
    private var wordsURL: URL {
        if let p = UserDefaults.standard.string(forKey: "wordsPath"), !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return defaultWordsURL
    }
    private var memorizedURL: URL { configDir.appendingPathComponent("memorized.txt") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        seedWordFileIfNeeded()
        loadMemorized()
        reloadWords(force: true)

        item = NSStatusBar.system.statusItem(withLength: 60)
        item.autosaveName = "wordbar"
        item.behavior = .terminationOnRemoval
        if let button = item.button {
            button.title = ""
            button.setAccessibilityLabel("WordBar")
            let font = NSFont.menuBarFont(ofSize: 0)
            wordLabel.font = font
            wordLabel.textColor = .labelColor
            checkLabel.font = font
            checkLabel.textColor = .labelColor
            checkLabel.isHidden = true
            wordLabel.onLeftClick = { [weak self] in self?.showDetailPanel() }
            wordLabel.onRightClick = { [weak self] in self?.showMenu() }
            checkLabel.onLeftClick = { [weak self] in self?.memorizeCurrent() }
            checkLabel.onRightClick = { [weak self] in self?.showMenu() }
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
            docView.addSubview(wordLabel)
            scrollView.documentView = docView
            button.addSubview(scrollView)
            button.addSubview(checkLabel)
        }

        // Auto-refresh when words.txt is edited externally: refresh the display if the
        // current word still exists, otherwise advance to the next word.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, self.reloadWords() else { return }
            if let current = self.current,
               let updated = self.entries.first(where: { $0.word == current.word }) {
                self.current = updated
                self.updateTitle()
            } else {
                self.pickNext()
            }
            self.refreshBrowseTable()
            if self.detailPanel?.isVisible == true { self.refreshDetailPanel() }
        }

        pickNext()
    }

    // MARK: - Word flow

    private func memorizeCurrent() {
        guard let entry = current else { pickNext(); return }
        memorized.insert(entry.word)
        saveMemorized()
        pushHistory(entry)
        pickNext()
        refreshBrowseTable(scrollToCurrent: true)
    }

    private func pushHistory(_ entry: WordEntry) {
        history.append(entry)
        if history.count > 50 { history.removeFirst() }
    }

    private func goBack() {
        reloadWords()
        guard let prev = history.popLast() else { return }
        current = entries.first(where: { $0.word == prev.word }) ?? prev
        updateTitle()
        refreshBrowseTable(scrollToCurrent: true)
    }

    private func saveMemorized() {
        let text = memorized.sorted().joined(separator: "\n")
        try? (text.isEmpty ? text : text + "\n").write(to: memorizedURL, atomically: true, encoding: .utf8)
    }

    private func pickNext() {
        reloadWords()
        guard !entries.isEmpty else {
            current = nil
            updateTitle()
            return
        }
        // Sequential order: pick the first unmemorized entry after the current one,
        // wrapping around (skipped words come back after a full cycle).
        let start = entries.firstIndex(where: { $0 == current }).map { $0 + 1 } ?? 0
        for i in 0..<entries.count {
            let e = entries[(start + i) % entries.count]
            if !memorized.contains(e.word) {
                current = e
                updateTitle()
                return
            }
        }
        current = nil
        updateTitle()
    }

    private func updateTitle() {
        guard let button = item?.button else { return }
        if let entry = current {
            var parts = [entry.word]
            if showMeaning, !entry.meaning.isEmpty { parts.append(entry.meaning) }
            if showExample, !entry.example.isEmpty { parts.append(entry.example) }
            wordLabel.stringValue = parts.joined(separator: " · ")
            var tip = entry.meaning.isEmpty ? entry.word : "\(entry.word): \(entry.meaning)"
            if !entry.example.isEmpty { tip += "\n" + entry.example }
            if !entry.exampleTranslation.isEmpty { tip += "\n" + entry.exampleTranslation }
            button.toolTip = tip
            checkLabel.isHidden = false
        } else {
            wordLabel.stringValue = entries.isEmpty ? "No Words" : "All Done"
            button.toolTip = entries.isEmpty ? "Click to open the menu and edit the vocabulary file" : "All words memorized. Click to open the menu and reset progress"
            checkLabel.isHidden = true
        }
        layoutLabels()
    }

    // Max visible width of the menu bar text; overflow scrolls horizontally
    // (items that are too wide get hidden by the system).
    private let maxBarVisibleWidth: CGFloat = 520

    private func layoutLabels() {
        guard let item = item, let button = item.button else { return }
        let height = button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness
        let gap: CGFloat = 6
        let pad: CGFloat = 5
        var x = pad
        let w = ceil(wordLabel.intrinsicContentSize.width)
        let h = ceil(wordLabel.intrinsicContentSize.height)
        let visible = min(w, maxBarVisibleWidth)
        scrollView.frame = NSRect(x: x, y: 0, width: visible, height: height)
        docView.frame = NSRect(x: 0, y: 0, width: w, height: height)
        wordLabel.frame = NSRect(x: 0, y: (height - h) / 2, width: w, height: h)
        scrollView.contentView.scroll(to: .zero)
        x += visible
        if !checkLabel.isHidden {
            let c = ceil(checkLabel.intrinsicContentSize.width)
            let ch = ceil(checkLabel.intrinsicContentSize.height)
            checkLabel.frame = NSRect(x: x + gap, y: (height - ch) / 2, width: c, height: ch)
            x += gap + c
        }
        item.length = x + pad
    }

    private func showDetailPanel() {
        reloadWords()
        guard current != nil, let button = item.button else {
            showMenu()
            return
        }
        if detailPanel == nil { createDetailPanel() }
        refreshDetailPanel()
        guard let panel = detailPanel, let window = button.window else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(buttonRect) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? buttonRect
        let x = min(max(buttonRect.midX - panel.frame.width / 2, visibleFrame.minX + 8),
                    visibleFrame.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: buttonRect.minY - panel.frame.height - 6))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel)
    }

    private func detailSpeechButton(_ action: Selector, _ label: String) -> NSButton {
        let button = NSButton(frame: .zero)
        button.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        return button
    }

    private func createDetailPanel() {
        let panel = WordPanel(contentRect: NSRect(x: 0, y: 0, width: detailPanelWidth, height: 240),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.onPrevious = { [weak self] in self?.detailPrevious() }
        panel.onNext = { [weak self] in self?.detailNext() }
        panel.onMemorize = { [weak self] in self?.detailMemorize() }

        let background = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        panel.contentView = background

        detailWord.font = .boldSystemFont(ofSize: 17)
        detailMeaning.font = .systemFont(ofSize: 14)
        detailExample.font = .systemFont(ofSize: 13)
        detailTranslation.font = .systemFont(ofSize: 13)
        detailProgress.font = .systemFont(ofSize: 12)
        [detailWord, detailMeaning, detailExample, detailTranslation, detailProgress].forEach {
            $0.textColor = .labelColor
        }

        let wordRow = NSStackView(views: [detailWord,
                                          detailSpeechButton(#selector(detailSpeakWord), "Speak Word")])
        wordRow.orientation = .horizontal
        wordRow.alignment = .centerY
        wordRow.spacing = 6
        detailWord.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let exampleRow = NSStackView(views: [detailExample,
                                             detailSpeechButton(#selector(detailSpeakExample), "Speak Example")])
        exampleRow.orientation = .horizontal
        exampleRow.alignment = .centerY
        exampleRow.spacing = 6
        detailExample.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let previous = NSButton(title: "Previous", target: self, action: #selector(detailPrevious))
        let next = NSButton(title: "Next", target: self, action: #selector(detailNext))
        let memorize = NSButton(title: "Remember & Next", target: self, action: #selector(detailMemorize))
        let navigation = NSStackView(views: [previous, next, memorize])
        navigation.orientation = .horizontal
        navigation.distribution = .fillEqually
        navigation.spacing = 8

        let stack = NSStackView(views: [wordRow, detailMeaning, exampleRow, detailTranslation,
                                        detailProgress, navigation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16),
            wordRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailMeaning.widthAnchor.constraint(equalTo: stack.widthAnchor),
            exampleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailTranslation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailProgress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            navigation.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        detailPanel = panel
        detailStack = stack
        detailPreviousButton = previous
        detailMemorizeButton = memorize
        detailExampleRow = exampleRow
    }

    private func refreshDetailPanel() {
        guard let panel = detailPanel, let stack = detailStack, let entry = current else {
            detailPanel?.orderOut(nil)
            return
        }
        detailWord.stringValue = entry.word
        detailMeaning.stringValue = entry.meaning
        detailExample.stringValue = entry.example
        detailTranslation.stringValue = entry.exampleTranslation
        let remaining = entries.filter { !memorized.contains($0.word) }.count
        let position = entries.firstIndex(where: { $0 == entry }).map { "No. \($0 + 1) · " } ?? ""
        detailProgress.stringValue = "\(position)\(remaining) remaining / \(entries.count) total"
        detailMeaning.isHidden = entry.meaning.isEmpty
        detailExampleRow?.isHidden = entry.example.isEmpty
        detailTranslation.isHidden = entry.exampleTranslation.isEmpty
        detailPreviousButton?.isEnabled = !history.isEmpty
        detailMemorizeButton?.title = memorized.contains(entry.word) ? "Unmark Memorized" : "Remember & Next"
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: detailPanelWidth, height: max(100, stack.fittingSize.height + 32)))
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.makeFirstResponder(panel)
    }

    @objc private func detailPrevious() {
        goBack()
        refreshDetailPanel()
    }

    @objc private func detailNext() {
        if let entry = current { pushHistory(entry) }
        pickNext()
        refreshBrowseTable(scrollToCurrent: true)
        refreshDetailPanel()
    }

    @objc private func detailMemorize() {
        if let entry = current, memorized.contains(entry.word) {
            memorized.remove(entry.word)
            saveMemorized()
            refreshBrowseTable()
        } else {
            memorizeCurrent()
        }
        refreshDetailPanel()
    }

    @objc private func detailSpeakWord() {
        speak()
        detailPanel?.makeFirstResponder(detailPanel)
    }

    @objc private func detailSpeakExample() {
        speakExample()
        detailPanel?.makeFirstResponder(detailPanel)
    }

    // MARK: - Menu

    private func showMenu() {
        reloadWords()
        let menu = NSMenu()

        menu.addItem(actionItem("Browse Words…", #selector(browseWords)))
        let toggle = actionItem("Show Meaning in Menu Bar", #selector(toggleMeaning))
        toggle.state = showMeaning ? .on : .off
        menu.addItem(toggle)
        let exToggle = actionItem("Show Example in Menu Bar", #selector(toggleExample))
        exToggle.state = showExample ? .on : .off
        menu.addItem(exToggle)
        menu.addItem(.separator())

        let vocabItem = NSMenuItem(title: "Vocabulary", action: nil, keyEquivalent: "")
        vocabItem.submenu = vocabSubmenu()
        menu.addItem(vocabItem)
        menu.addItem(actionItem("Open Vocabulary File", #selector(openWordsFile)))
        menu.addItem(actionItem("Reload Vocabulary", #selector(reload)))
        menu.addItem(actionItem("Reset Progress", #selector(resetProgress)))
        menu.addItem(.separator())

        let login = actionItem("Launch at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(actionItem("Quit WordBar", #selector(quit)))

        item.menu = menu
        item.button?.performClick(nil)
        DispatchQueue.main.async { [weak self, weak menu] in
            guard let self, self.item?.menu === menu else { return }
            self.item?.menu = nil
        }
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Menu actions

    @objc private func speak() { speakText(current?.word ?? "") }
    @objc private func speakExample() { speakText(current?.example ?? "") }

    private func speakText(_ text: String) {
        guard !text.isEmpty, !speech.isSpeaking else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speech.speak(utterance)
    }

    @objc private func toggleMeaning() {
        showMeaning.toggle()
        UserDefaults.standard.set(showMeaning, forKey: "showMeaning")
        updateTitle()
    }

    @objc private func toggleExample() {
        showExample.toggle()
        UserDefaults.standard.set(showExample, forKey: "showExample")
        updateTitle()
    }

    @objc private func openWordsFile() {
        NSWorkspace.shared.open(wordsURL)
    }

    // MARK: - Vocabulary selection

    private func vocabSubmenu() -> NSMenu {
        let submenu = NSMenu()
        for url in wordListFiles() {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(selectVocab(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url.path
            item.state = url.path == wordsURL.path ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let choose = NSMenuItem(title: "Choose File…", action: #selector(chooseVocabFile),
                                keyEquivalent: "")
        choose.target = self
        submenu.addItem(choose)
        return submenu
    }

    private func existingWordLists() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: configDir, includingPropertiesForKeys: nil)) ?? [])
            .filter {
                $0.pathExtension.lowercased() == "txt" && $0.lastPathComponent != "memorized.txt"
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    private func wordListFiles() -> [URL] {
        var list = existingWordLists()
        let active = wordsURL
        if !list.contains(where: { $0.path == active.path }) {
            list.insert(active, at: 0)
        }
        return list
    }

    @objc private func selectVocab(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        UserDefaults.standard.set(path, forKey: "wordsPath")
        switchVocabulary()
    }

    @objc private func chooseVocabFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = configDir
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "wordsPath")
        switchVocabulary()
    }

    private func switchVocabulary() {
        lastWordsMod = nil
        history.removeAll()
        current = nil
        reloadWords(force: true)
        pickNext()
        refreshBrowseTable(scrollToCurrent: true)
    }

    // MARK: - Word browser

    private func refreshBrowseTable(scrollToCurrent: Bool = false) {
        guard let table = browseTable else { return }
        table.reloadData()
        guard let index = entries.firstIndex(where: { $0 == current }) else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        if scrollToCurrent { table.scrollRowToVisible(index) }
    }

    @objc private func browseWords() {
        if browsePanel == nil {
            let size = NSSize(width: 950, height: 440)
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "WordBar — Browse"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.center()

            let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
            scroll.hasVerticalScroller = true
            scroll.autoresizingMask = [.width, .height]
            let table = NSTableView(frame: scroll.bounds)
            for (id, title, width) in [
                ("done", "✓", 30), ("word", "Word", 150), ("meaning", "Meaning", 250),
                ("example", "Example", 280), ("translation", "Translation", 220)] as [(String, String, CGFloat)] {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                col.title = title
                col.width = width
                col.resizingMask = id == "translation" ? .autoresizingMask : .userResizingMask
                table.addTableColumn(col)
            }
            table.dataSource = self
            table.delegate = self
            table.doubleAction = #selector(browseJump)
            table.target = self
            scroll.documentView = table
            panel.contentView = scroll
            browsePanel = panel
            browseTable = table
        }
        refreshBrowseTable(scrollToCurrent: true)
        browsePanel?.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func browseJump() {
        let row = browseTable?.clickedRow ?? -1
        guard row >= 0, row < entries.count, entries[row] != current else { return }
        if let c = current { pushHistory(c) }
        current = entries[row]
        updateTitle()
        refreshBrowseTable(scrollToCurrent: true)
    }

    @objc private func browseToggleMemorized(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        if sender.state == .on {
            memorized.insert(entry.word)
            if entry == current {
                pushHistory(entry)
                pickNext()
            }
        } else {
            memorized.remove(entry.word)
            if current == nil {
                current = entry
                updateTitle()
            }
        }
        saveMemorized()
        refreshBrowseTable()
    }

    @objc private func reload() {
        let currentWord = current?.word
        reloadWords(force: true)
        if let currentWord, let updated = entries.first(where: { $0.word == currentWord }) {
            current = updated
            updateTitle()
        } else {
            pickNext()
        }
        refreshBrowseTable(scrollToCurrent: true)
    }

    @objc private func resetProgress() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset all progress?"
        alert.informativeText = "All memorized marks will be removed. This cannot be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset Progress")
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        memorized.removeAll()
        try? FileManager.default.removeItem(at: memorizedURL)
        pickNext()
        refreshBrowseTable(scrollToCurrent: true)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to configure launch at login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Storage

    private func seedWordFileIfNeeded() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: wordsURL.path) {
            // Selected list is gone — fall back to another existing list if any.
            UserDefaults.standard.removeObject(forKey: "wordsPath")
            if let first = existingWordLists().first {
                UserDefaults.standard.set(first.path, forKey: "wordsPath")
            }
        }
        // No usable word list at all (fresh install or emptied dir) — seed defaults.
        guard !fm.fileExists(atPath: wordsURL.path) else { return }
        try? AppDelegate.defaultWords.write(to: wordsURL, atomically: true, encoding: .utf8)
    }

    private func loadMemorized() {
        guard let text = try? String(contentsOf: memorizedURL, encoding: .utf8) else { return }
        memorized = Set(text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
    }

    @discardableResult
    private func reloadWords(force: Bool = false) -> Bool {
        let mod = try? FileManager.default.attributesOfItem(atPath: wordsURL.path)[.modificationDate] as? Date
        guard force || mod != lastWordsMod else { return false }
        lastWordsMod = mod
        guard let text = try? String(contentsOf: wordsURL, encoding: .utf8) else { return false }
        let newEntries = WordParser.parse(text)
        guard newEntries != entries else { return false }
        entries = newEntries
        return true
    }

    private static let defaultWords = """
    # One word per line: word|meaning|example|exampleTranslation (last two optional)
    # Also accepts tab-separated columns, " - ", or comma-separated pairs.
    abandon|[əˈbændən] v. 放弃；抛弃 n. 放纵|Those who abandon themselves to despair can not succeed.|那些自暴自弃的人无法成功。
    abnormal|[æbˈnɔːml] adj. 反常的；不正常的 n. 不正常的人|We were very surprised at his abnormal behavior.|我们对他的反常行为感到非常吃惊。
    aboard|[əˈbɔːd] adv. 在船上；在火车上 prep. 上船；上飞机|Little Tom and the sailors spent two months aboard.|小汤姆和水手们在船上过了两个月。
    above|[əˈbʌv] prep. 超过；在 ... 上面 adj. 上面的；以上的 adv. 在上面；超过 n. 上面的东西|The glider was soaring above the valley.|那架滑翔机在山谷上空滑翔。
    abroad|[əˈbrɔːd] adv. 到国外；广为流传 adj. 在国外；海外(一般作表语)|He is travelling abroad.|他要到国外旅行。
    absence|[ˈæbsəns] n. 缺席；缺乏|His long absence raised fears about his safety.|他长期不在引起了大家对他的安全的担心。
    absent|[ˈæbsənt] adj. 缺席的；不在的 vt. 使缺席|Professor Li is absent, I will take the lesson in the place of him.|李教授不在，我替他上课。
    absolute|[ˈæbsəluːt] adj. 绝对的；确实的 n. 绝对的事物|There is no absolute standard for beauty.|美是没有绝对的标准的。
    """
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension AppDelegate: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count, let column else { return nil }
        let entry = entries[row]
        let id = column.identifier.rawValue
        let cellId = NSUserInterfaceItemIdentifier("cell.\(id)")
        if id == "done" {
            let container = tableView.makeView(withIdentifier: cellId, owner: self) ?? NSView()
            container.identifier = cellId
            let checkbox: NSButton
            if let existing = container.subviews.first as? NSButton {
                checkbox = existing
            } else {
                checkbox = NSButton(checkboxWithTitle: "", target: self,
                                    action: #selector(browseToggleMemorized(_:)))
                checkbox.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(checkbox)
                NSLayoutConstraint.activate([
                    checkbox.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                    checkbox.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
            }
            checkbox.target = self
            checkbox.action = #selector(browseToggleMemorized(_:))
            checkbox.tag = row
            checkbox.state = memorized.contains(entry.word) ? .on : .off
            checkbox.toolTip = checkbox.state == .on ? "Mark as not memorized" : "Mark as memorized"
            checkbox.setAccessibilityLabel("Memorized: \(entry.word)")
            return container
        }
        let label = (tableView.makeView(withIdentifier: cellId, owner: self) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        label.identifier = cellId
        let text: String
        switch id {
        case "word": text = entry == current ? "▶ \(entry.word)" : entry.word
        case "example": text = entry.example
        case "translation": text = entry.exampleTranslation
        default: text = entry.meaning
        }
        label.stringValue = text
        label.toolTip = id == "word" ? entry.word : text
        label.lineBreakMode = .byTruncatingTail
        label.textColor = memorized.contains(entry.word) ? .secondaryLabelColor : .labelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        return label
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
