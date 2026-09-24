// WordBar — a macOS menu bar vocabulary flashcard app.
// Vocabulary file: ~/.config/wordbar/words.txt
// Format: word|meaning|example|exampleTranslation (last two columns optional)

import AVFoundation
import Cocoa
import ServiceManagement

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

    private let configDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/wordbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var wordsURL: URL { configDir.appendingPathComponent("words.txt") }
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
            wordLabel.onLeftClick = { [weak self] in self?.showMenu() }
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
            if let c = self.current, !self.entries.contains(where: { $0.word == c.word }) {
                self.pickNext()
            } else {
                self.updateTitle()
            }
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
    private let maxBarVisibleWidth: CGFloat = 420

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

    // MARK: - Menu

    private func showMenu() {
        reloadWords()
        let menu = NSMenu()

        if let entry = current {
            menu.addItem(infoItem(entry.meaning.isEmpty ? entry.word : "\(entry.word): \(entry.meaning)"))
            if !entry.example.isEmpty { menu.addItem(infoItem(entry.example)) }
            if !entry.exampleTranslation.isEmpty { menu.addItem(infoItem(entry.exampleTranslation)) }
            menu.addItem(.separator())
            menu.addItem(actionItem("Memorized", #selector(menuMemorize)))
            menu.addItem(actionItem("Previous", #selector(menuBack)))
            menu.addItem(actionItem("Next", #selector(menuSkip)))
            menu.addItem(actionItem(memorized.contains(entry.word) ? "Unmark Memorized" : "Mark as Memorized",
                                    #selector(toggleMark)))
            menu.addItem(actionItem("Speak Word", #selector(speak)))
            if !entry.example.isEmpty {
                menu.addItem(actionItem("Speak Example", #selector(speakExample)))
            }
            let toggle = actionItem("Show Meaning in Menu Bar", #selector(toggleMeaning))
            toggle.state = showMeaning ? .on : .off
            menu.addItem(toggle)
            let exToggle = actionItem("Show Example in Menu Bar", #selector(toggleExample))
            exToggle.state = showExample ? .on : .off
            menu.addItem(exToggle)
            menu.addItem(.separator())
        }

        let remaining = entries.filter { !memorized.contains($0.word) }.count
        var stats = "\(remaining) remaining / \(entries.count) total"
        if let pos = entries.firstIndex(where: { $0 == current }) {
            stats = "No. \(pos + 1) · " + stats
        }
        menu.addItem(infoItem(stats))

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
        DispatchQueue.main.async { self.item?.menu = nil }
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Menu actions

    @objc private func menuMemorize() { memorizeCurrent() }

    @objc private func menuBack() { goBack() }

    @objc private func menuSkip() {
        if let entry = current { pushHistory(entry) }
        pickNext()
    }

    @objc private func toggleMark() {
        guard let entry = current else { return }
        if memorized.contains(entry.word) {
            memorized.remove(entry.word)
        } else {
            memorized.insert(entry.word)
        }
        saveMemorized()
    }

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

    @objc private func reload() {
        reloadWords(force: true)
        pickNext()
    }

    @objc private func resetProgress() {
        memorized.removeAll()
        try? FileManager.default.removeItem(at: memorizedURL)
        pickNext()
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
        guard !FileManager.default.fileExists(atPath: wordsURL.path) else { return }
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
