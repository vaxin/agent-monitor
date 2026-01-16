import Cocoa
import UserNotifications

// MARK: - Data Structures

struct IPInfo {
    var ip: String = "-"
    var country: String = "-"
    var region: String = "-"
    var city: String = "-"
    var org: String = "-"
    var url: String = "-"
    var statusCode: Int = 0
    var error: String? = nil
    var timestamp: Date = Date()
}

enum SessionStatus {
    case working       // Claude is processing
    case freshWaiting  // Just entered waiting (< 1 min) - needs attention!
    case waiting       // Waiting for user input (> 1 min)
    case ended         // Session ended (don't show)
}

struct SessionInfo {
    var sessionId: String
    var projectPath: String      // Display name (last component)
    var fullProjectPath: String  // Full path for iTerm matching
    var lastPrompt: String
    var status: SessionStatus
    var lastUpdate: Date
    var claudePid: Int?          // Claude process PID for precise matching
    var tabTitle: String?        // iTerm2 tab title (from session name)
    var waitingStartTime: Date?  // When session entered waiting state
}

// MARK: - SessionItemView

class SessionItemView: NSView {
    var sessionId: String = ""
    weak var delegate: AppDelegate?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Double click: activate iTerm tab
            delegate?.activateITermTab(sessionId: sessionId)
        } else {
            // Single click: select
            delegate?.sessionItemClicked(sessionId: sessionId)
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow!
    var lastIPInfo = IPInfo()
    var statusMenu: NSMenu!

    // IP Monitor UI
    var statusDot: NSView!
    var statusLabel: NSTextField!
    var timeValue: NSTextField!
    var urlValue: NSTextField!
    var ipValue: NSTextField!
    var countryValue: NSTextField!
    var regionValue: NSTextField!
    var cityValue: NSTextField!
    var orgValue: NSTextField!
    var errorBox: NSBox!
    var errorLabel: NSTextField!

    // Session Monitor
    var sessionWindow: NSWindow!
    var sessionStackView: NSStackView!
    var sessions: [String: SessionInfo] = [:]
    var selectedSessionId: String? = nil
    var loadingSessionId: String? = nil  // Session being activated (loading state)
    var fsEventStream: FSEventStreamRef?
    let logDir = NSString(string: "~/.claude/logs/lifecycle").expandingTildeInPath
    var tabTitleRefreshTimer: Timer? = nil
    var hasLoadedTabTitles: Bool = false  // Track if we've loaded tab titles at least once
    var statsWindow: NSWindow? = nil  // Keep reference to stats window to prevent crash on close

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Agent Monitor launching...")

        // Request notification permission (only if running as proper .app bundle)
        let isAppBundle = Bundle.main.bundleURL.pathExtension == "app"
        if isAppBundle {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                print("Notification permission: \(granted)")
            }
        }

        // Setup status item with click handling
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem(country: "...", color: .gray)

        // Setup menu (for right-click)
        statusMenu = NSMenu()
        statusMenu.addItem(NSMenuItem(title: "Show IP Info", action: #selector(showWindow), keyEquivalent: "s"))
        statusMenu.addItem(NSMenuItem(title: "Refresh IP", action: #selector(fetchIP), keyEquivalent: "r"))
        statusMenu.addItem(.separator())
        statusMenu.addItem(NSMenuItem(title: "AI Productivity Stats", action: #selector(showProductivityStats), keyEquivalent: "p"))
        statusMenu.addItem(.separator())
        statusMenu.addItem(NSMenuItem(title: "Clean Ended Sessions", action: #selector(cleanEndedSessions), keyEquivalent: ""))
        statusMenu.addItem(NSMenuItem(title: "Delete All Logs", action: #selector(deleteAllLogs), keyEquivalent: ""))
        statusMenu.addItem(.separator())
        statusMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Configure click handling
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Setup IP Monitor window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Monitor - IP Info"
        window.center()
        window.delegate = self

        setupUI()
        print("UI setup done")

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("Window shown")

        // Setup Session Monitor window
        setupSessionWindow()

        // Start file monitoring
        startFileMonitoring()
        reloadSessions()

        // Fetch IP
        fetchIPInternal(showLoading: false)
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchIPInternal(showLoading: false)
        }

        // Check and update freshWaiting sessions every 5 seconds
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkAndUpdateWaitingStates()
        }
    }

    func checkAndUpdateWaitingStates() {
        var needsUpdate = false
        let now = Date()

        for (sessionId, session) in sessions {
            if session.status == .freshWaiting,
               let startTime = session.waitingStartTime,
               now.timeIntervalSince(startTime) > 60 {  // 1 minute
                var updated = session
                updated.status = .waiting
                sessions[sessionId] = updated
                needsUpdate = true
            }
        }

        if needsUpdate && sessionWindow.isVisible {
            updateSessionUI()
        }
    }

    func statusPriority(_ status: SessionStatus) -> Int {
        switch status {
        case .freshWaiting: return 0  // Highest priority
        case .waiting: return 1
        case .working: return 2
        case .ended: return 3
        }
    }

    // MARK: - Status Item Click Handling

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right click: show menu
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // Left click: toggle session window
            toggleSessionWindow()
        }
    }

    // MARK: - Session Window (Floating Panel Style)

    func setupSessionWindow() {
        sessionWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        sessionWindow.isOpaque = false
        sessionWindow.backgroundColor = .clear
        sessionWindow.level = .floating
        sessionWindow.delegate = self
        sessionWindow.isMovableByWindowBackground = true
        sessionWindow.hasShadow = true

        // Position near status item (top right)
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            sessionWindow.setFrameOrigin(NSPoint(
                x: screenRect.maxX - 340,
                y: screenRect.maxY - 400
            ))
        }

        // Make window content view rounded
        let contentView = sessionWindow.contentView!
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12
        contentView.layer?.masksToBounds = true

        // Visual effect view (frosted glass)
        let visualEffect = NSVisualEffectView(frame: contentView.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true
        contentView.addSubview(visualEffect, positioned: .below, relativeTo: nil)

        // Scroll view for sessions
        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        contentView.addSubview(scrollView)

        // Stack view for session items
        sessionStackView = NSStackView()
        sessionStackView.orientation = .vertical
        sessionStackView.alignment = .leading
        sessionStackView.spacing = 6
        sessionStackView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.documentView = sessionStackView
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

            sessionStackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -8)
        ])
    }

    func logPerf(_ msg: String) {
        let log = "/tmp/agent-monitor-perf.log"
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: log) {
                if let handle = FileHandle(forWritingAtPath: log) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: log, contents: data)
            }
        }
    }

    func toggleSessionWindow() {
        if sessionWindow.isVisible {
            sessionWindow.orderOut(nil)
            // Stop tab title refresh timer when window is hidden
            tabTitleRefreshTimer?.invalidate()
            tabTitleRefreshTimer = nil
        } else {
            let t0 = CFAbsoluteTimeGetCurrent()
            // Reset tab title loading state
            hasLoadedTabTitles = false

            // Quick load without iTerm titles, then show window immediately
            reloadSessions(fetchTabTitles: false)
            let t1 = CFAbsoluteTimeGetCurrent()
            logPerf("reloadSessions: \(Int((t1-t0)*1000))ms")

            updateSessionUI()
            let t2 = CFAbsoluteTimeGetCurrent()
            logPerf("updateSessionUI: \(Int((t2-t1)*1000))ms")

            sessionWindow.makeKeyAndOrderFront(nil)
            let t3 = CFAbsoluteTimeGetCurrent()
            logPerf("showWindow: \(Int((t3-t2)*1000))ms")
            logPerf("TOTAL: \(Int((t3-t0)*1000))ms")

            // Fetch iTerm2 titles immediately
            refreshTabTitles()

            // Start periodic tab title refresh (every 10 seconds)
            tabTitleRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.refreshTabTitles()
            }
        }
    }

    func refreshTabTitles() {
        // Async fetch iTerm2 titles and update UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let ta = CFAbsoluteTimeGetCurrent()
            let tabTitles = self.getITermTabTitles()
            let tb = CFAbsoluteTimeGetCurrent()
            self.logPerf("getITermTabTitles (async): \(Int((tb-ta)*1000))ms")
            DispatchQueue.main.async {
                self.hasLoadedTabTitles = true
                self.updateSessionTabTitles(tabTitles)
                self.updateSessionUI()
            }
        }
    }

    func updateSessionTabTitles(_ tabTitles: [String: String]) {
        for (sessionId, session) in sessions {
            var updatedSession = session
            if let pid = session.claudePid, let tty = getTtyForPid(pid) {
                if let rawTitle = tabTitles[tty] {
                    updatedSession.tabTitle = cleanTabTitle(rawTitle)
                    sessions[sessionId] = updatedSession
                }
            }
        }
    }

    func updateSessionUI() {
        // Clear existing views
        sessionStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Filter active sessions (not ended)
        let activeSessions = sessions.values
            .filter { $0.status != .ended }
            .sorted { s1, s2 in
                // Priority: freshWaiting > waiting > working
                let priority1 = self.statusPriority(s1.status)
                let priority2 = self.statusPriority(s2.status)
                if priority1 != priority2 {
                    return priority1 < priority2
                }
                // Same status: sort by project name, then sessionId for stable ordering
                let nameCompare = s1.projectPath.localizedCaseInsensitiveCompare(s2.projectPath)
                if nameCompare != .orderedSame {
                    return nameCompare == .orderedAscending
                }
                return s1.sessionId < s2.sessionId
            }

        if activeSessions.isEmpty {
            let emptyContainer = NSView()
            emptyContainer.translatesAutoresizingMaskIntoConstraints = false
            emptyContainer.heightAnchor.constraint(equalToConstant: 60).isActive = true

            let emptyLabel = NSTextField(labelWithString: "No active sessions")
            emptyLabel.font = NSFont.systemFont(ofSize: 12)
            emptyLabel.textColor = .tertiaryLabelColor
            emptyLabel.alignment = .center
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            emptyContainer.addSubview(emptyLabel)

            NSLayoutConstraint.activate([
                emptyLabel.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor)
            ])

            sessionStackView.addArrangedSubview(emptyContainer)
        } else {
            for session in activeSessions {
                let itemView = createSessionItemView(session: session)
                sessionStackView.addArrangedSubview(itemView)
            }
        }

        // Adaptive window height
        resizeSessionWindow(sessionCount: activeSessions.count)
    }

    func resizeSessionWindow(sessionCount: Int) {
        let padding: CGFloat = 16  // 8 top + 8 bottom
        let itemHeight: CGFloat = 28
        let itemSpacing: CGFloat = 6
        let minHeight: CGFloat = 60
        let maxHeight: CGFloat = 360

        let contentHeight: CGFloat
        if sessionCount == 0 {
            contentHeight = padding + 40  // empty state
        } else {
            contentHeight = padding + (itemHeight * CGFloat(sessionCount)) + (itemSpacing * CGFloat(max(0, sessionCount - 1)))
        }

        let newHeight = min(max(contentHeight, minHeight), maxHeight)
        var frame = sessionWindow.frame
        let heightDiff = newHeight - frame.height
        frame.origin.y -= heightDiff  // Keep top edge fixed
        frame.size.height = newHeight
        sessionWindow.setFrame(frame, display: true, animate: true)
    }

    func createSessionItemView(session: SessionInfo) -> NSView {
        let isSelected = selectedSessionId == session.sessionId
        let container = SessionItemView(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        container.sessionId = session.sessionId
        container.delegate = self
        container.wantsLayer = true
        container.layerContentsRedrawPolicy = .onSetNeedsDisplay  // Critical for animations
        container.layer?.cornerRadius = 6

        // Background color based on status and selection
        if isSelected {
            container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        } else if session.status == .freshWaiting {
            // Fresh waiting: vibrant orange with stronger emphasis
            container.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.2).cgColor
            container.layer?.borderWidth = 1.5
            container.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.5).cgColor
        } else if session.status == .waiting {
            // Regular waiting: softer yellow
            container.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.12).cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
        } else {
            container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            container.layer?.borderWidth = 0.5
            container.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        }

        // Status indicator dot
        let isLoading = loadingSessionId == session.sessionId
        let statusDot = NSView(frame: NSRect(x: 8, y: 10, width: 8, height: 8))
        statusDot.wantsLayer = true
        statusDot.layerContentsRedrawPolicy = .onSetNeedsDisplay  // Critical for animations
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.masksToBounds = false  // Allow shadow to show

        if isLoading {
            // Loading state: blue pulsing dot
            statusDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            statusDot.layer?.shadowColor = NSColor.systemBlue.cgColor
            statusDot.layer?.shadowRadius = 4
            statusDot.layer?.shadowOpacity = 0.8
            statusDot.layer?.shadowOffset = .zero

            // Pulse animation
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.duration = 0.5
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.isRemovedOnCompletion = false
            statusDot.layer?.add(pulse, forKey: "pulse")
        } else if session.status == .freshWaiting {
            // Fresh waiting: bright orange with pulsing animation
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusDot.layer?.shadowColor = NSColor.systemOrange.cgColor
            statusDot.layer?.shadowRadius = 4
            statusDot.layer?.shadowOpacity = 0.8
            statusDot.layer?.shadowOffset = .zero

            // Pulse animation - animate shadow opacity for more visible effect
            let shadowPulse = CABasicAnimation(keyPath: "shadowOpacity")
            shadowPulse.fromValue = 0.8
            shadowPulse.toValue = 0.2
            shadowPulse.duration = 0.8
            shadowPulse.autoreverses = true
            shadowPulse.repeatCount = .infinity
            shadowPulse.isRemovedOnCompletion = false
            statusDot.layer?.add(shadowPulse, forKey: "shadowPulse")

            // Also pulse the opacity
            let opacityPulse = CABasicAnimation(keyPath: "opacity")
            opacityPulse.fromValue = 1.0
            opacityPulse.toValue = 0.5
            opacityPulse.duration = 0.8
            opacityPulse.autoreverses = true
            opacityPulse.repeatCount = .infinity
            opacityPulse.isRemovedOnCompletion = false
            statusDot.layer?.add(opacityPulse, forKey: "opacityPulse")
        } else if session.status == .waiting {
            // Regular waiting: yellow with soft glow
            statusDot.layer?.backgroundColor = NSColor.systemYellow.cgColor
            statusDot.layer?.shadowColor = NSColor.systemYellow.cgColor
            statusDot.layer?.shadowRadius = 3
            statusDot.layer?.shadowOpacity = 0.6
            statusDot.layer?.shadowOffset = .zero
        } else {
            // Working: green
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        }
        container.addSubview(statusDot)

        // Project name
        let nameLabel = NSTextField(labelWithString: session.projectPath)
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: 22, y: 6, width: 70, height: 16)
        container.addSubview(nameLabel)

        // Description: prefer tab title, fallback to prompt (only after loading tab titles)
        let description: String
        if let tabTitle = session.tabTitle {
            // Has tab title: show it
            description = tabTitle
        } else if hasLoadedTabTitles {
            // Tab titles loaded but this session doesn't have one: show prompt
            description = session.lastPrompt.isEmpty ? "..." : session.lastPrompt
        } else {
            // Still loading tab titles: show loading indicator
            description = "..."
        }

        let descLabel = NSTextField(labelWithString: description)
        descLabel.font = NSFont.systemFont(ofSize: 10)
        descLabel.textColor = hasLoadedTabTitles ? .secondaryLabelColor : .tertiaryLabelColor
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.frame = NSRect(x: 94, y: 6, width: isSelected ? 150 : 175, height: 16)
        container.addSubview(descLabel)

        // Tooltip: show last prompt on hover (useful when tab title is shown)
        if !session.lastPrompt.isEmpty {
            container.toolTip = session.lastPrompt
        }

        // Delete button (only when selected)
        if isSelected {
            let deleteBtn = NSButton(frame: NSRect(x: 250, y: 3, width: 22, height: 22))
            deleteBtn.bezelStyle = .circular
            deleteBtn.title = ""
            deleteBtn.image = NSImage(systemSymbolName: "trash.circle.fill", accessibilityDescription: "Delete")
            deleteBtn.imagePosition = .imageOnly
            deleteBtn.isBordered = false
            deleteBtn.contentTintColor = .systemRed
            deleteBtn.target = self
            deleteBtn.action = #selector(deleteSelectedSession)
            container.addSubview(deleteBtn)
        }

        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 28).isActive = true

        return container
    }

    func sessionItemClicked(sessionId: String) {
        if selectedSessionId == sessionId {
            selectedSessionId = nil  // Deselect
        } else {
            selectedSessionId = sessionId  // Select
        }
        updateSessionUI()
    }

    func activateITermTab(sessionId: String) {
        guard let session = sessions[sessionId],
              !session.fullProjectPath.isEmpty else { return }

        // Set loading state and refresh UI
        loadingSessionId = sessionId
        updateSessionUI()

        // Build AppleScript with optional PID matching
        let pidCondition: String
        if let pid = session.claudePid {
            pidCondition = """
            -- First: try exact PID match (most precise)
            set targetPid to "\(pid)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set sessionTty to tty of s
                        set ttyShort to do shell script "basename " & quoted form of sessionTty
                        set pidCheck to do shell script "ps -t " & ttyShort & " -o pid 2>/dev/null | grep -w " & targetPid & " || true"
                        if pidCheck is not "" then
                            select t
                            select w
                            activate
                            return "OK"
                        end if
                    end repeat
                end repeat
            end repeat

            """
        } else {
            pidCondition = ""
        }

        let activateScript = """
        set targetPath to "\(session.fullProjectPath)"

        tell application "iTerm2"
            \(pidCondition)
            -- Second: find session with claude process matching cwd
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set sessionTty to tty of s
                        set ttyShort to do shell script "basename " & quoted form of sessionTty
                        set claudeCheck to do shell script "ps -t " & ttyShort & " -o pid,comm 2>/dev/null | grep claude | awk '{print $1}' | head -1"
                        if claudeCheck is not "" then
                            set claudeCwd to do shell script "lsof -p " & claudeCheck & " 2>/dev/null | grep cwd | awk '{print $NF}'"
                            if claudeCwd is targetPath then
                                select t
                                select w
                                activate
                                return "OK"
                            end if
                        end if
                    end repeat
                end repeat
            end repeat

            -- Third: fallback to shell cwd matching
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set sessionTty to tty of s
                        set ttyShort to do shell script "basename " & quoted form of sessionTty
                        set shellPid to do shell script "ps -t " & ttyShort & " -o pid,comm 2>/dev/null | grep -E 'zsh|bash' | head -1 | awk '{print $1}'"
                        if shellPid is not "" then
                            set shellCwd to do shell script "lsof -p " & shellPid & " 2>/dev/null | grep cwd | awk '{print $NF}'"
                            if shellCwd is targetPath then
                                select t
                                select w
                                activate
                                return "OK"
                            end if
                        end if
                    end repeat
                end repeat
            end repeat
            return "Not found"
        end tell
        """

        // Run AppleScript asynchronously
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", activateScript]
            task.launch()
            task.waitUntilExit()

            // Clear loading state on main thread
            DispatchQueue.main.async {
                self?.loadingSessionId = nil
                self?.updateSessionUI()
            }
        }
    }

    @objc func deleteSelectedSession() {
        guard let sessionId = selectedSessionId else { return }
        let filePath = (logDir as NSString).appendingPathComponent("session-\(sessionId).log")
        try? FileManager.default.removeItem(atPath: filePath)
        selectedSessionId = nil
        reloadSessions()
        updateSessionUI()
    }

    // MARK: - Log Management

    @objc func cleanEndedSessions() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logDir) else { return }

        for file in files {
            guard file.hasPrefix("session-") && file.hasSuffix(".log") else { continue }

            let filePath = (logDir as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: filePath),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }

            // Check if session has ended
            if content.contains("EVENT: SessionEnd") {
                try? FileManager.default.removeItem(atPath: filePath)
            }
        }

        reloadSessions()
        if sessionWindow.isVisible {
            updateSessionUI()
        }
    }

    @objc func deleteAllLogs() {
        let alert = NSAlert()
        alert.messageText = "Delete All Logs?"
        alert.informativeText = "This will delete all session log files. This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: logDir) else { return }

            for file in files {
                let filePath = (logDir as NSString).appendingPathComponent(file)
                try? FileManager.default.removeItem(atPath: filePath)
            }

            reloadSessions()
            if sessionWindow.isVisible {
                updateSessionUI()
            }
        }
    }

    // MARK: - Session Monitoring (FSEvents)

    func startFileMonitoring() {
        // Create log directory if needed
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        let paths = [logDir] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (stream, clientInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let clientInfo = clientInfo else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(clientInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                delegate.onFileSystemEvent()
            }
        }

        fsEventStream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,  // 300ms latency
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream = fsEventStream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
        }
    }

    func onFileSystemEvent() {
        let oldSessions = sessions
        // Skip iTerm titles on FSEvents - preserve existing titles
        reloadSessions(fetchTabTitles: false)

        // Preserve existing tab titles from old sessions
        for (sessionId, oldSession) in oldSessions {
            if var newSession = sessions[sessionId], newSession.tabTitle == nil {
                newSession.tabTitle = oldSession.tabTitle
                sessions[sessionId] = newSession
            }
        }

        // Update UI if visible and something changed
        if sessionWindow.isVisible {
            let changed = sessions.count != oldSessions.count ||
                sessions.contains { key, value in
                    oldSessions[key]?.status != value.status
                }
            if changed {
                updateSessionUI()
            }
        }
    }

    // MARK: - iTerm2 Tab Title Integration

    /// Get TTY for a given PID
    func getTtyForPid(_ pid: Int) -> String? {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(pid), "-o", "tty="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let tty = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tty = tty, !tty.isEmpty, tty != "??" {
                return tty
            }
        } catch {}
        return nil
    }

    /// Get all iTerm2 session titles mapped by TTY (e.g., "ttys012" -> "✳ Task Name")
    func getITermTabTitles() -> [String: String] {
        let script = """
        tell application "iTerm2"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set sessionName to name of s
                        set sessionTty to tty of s
                        set ttyShort to do shell script "basename " & quoted form of sessionTty
                        set output to output & ttyShort & "\\t" & sessionName & "\\n"
                    end repeat
                end repeat
            end repeat
            return output
        end tell
        """

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [:] }

            var result: [String: String] = [:]
            for line in output.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: "\t")
                if parts.count >= 2 {
                    let tty = parts[0].trimmingCharacters(in: .whitespaces)
                    let title = parts[1].trimmingCharacters(in: .whitespaces)
                    if !tty.isEmpty && !title.isEmpty {
                        result[tty] = title
                    }
                }
            }
            return result
        } catch {
            return [:]
        }
    }

    /// Extract clean task name from iTerm2 tab title
    /// e.g., "✳ Database Usage Count (node)" -> "Database Usage Count"
    func cleanTabTitle(_ title: String) -> String {
        var clean = title
        // Remove leading status indicators (✳, ⠂, etc.)
        let prefixes = ["✳ ", "⠂ ", "⠈ ", "⠐ ", "⠠ ", "⡀ ", "⢀ ", "⠄ "]
        for prefix in prefixes {
            if clean.hasPrefix(prefix) {
                clean = String(clean.dropFirst(prefix.count))
                break
            }
        }
        // Remove trailing process indicator like " (node)", " (-zsh)"
        if let parenRange = clean.range(of: " (", options: .backwards) {
            clean = String(clean[..<parenRange.lowerBound])
        }
        return clean.trimmingCharacters(in: .whitespaces)
    }

    func reloadSessions(fetchTabTitles: Bool = true) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var newSessions: [String: SessionInfo] = [:]
        var previousStates: [String: SessionStatus] = [:]

        // Save previous states for notification comparison
        for (id, session) in sessions {
            previousStates[id] = session.status
        }

        // Get iTerm2 tab titles (TTY -> title mapping) - skip if not needed for faster loading
        let tabTitles: [String: String] = fetchTabTitles ? getITermTabTitles() : [:]
        let t1 = CFAbsoluteTimeGetCurrent()
        logPerf("  tabTitles: \(Int((t1-t0)*1000))ms (fetch=\(fetchTabTitles))")

        // Scan session-*.log files in directory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logDir) else {
            return
        }
        logPerf("  listDir: \(Int((CFAbsoluteTimeGetCurrent()-t1)*1000))ms, files=\(files.count)")

        for file in files {
            guard file.hasPrefix("session-") && file.hasSuffix(".log") else { continue }

            let filePath = (logDir as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: filePath) else {
                continue
            }
            let content = String(decoding: data, as: UTF8.self)

            // Extract session ID from filename: session-{id}.log
            let sessionId = String(file.dropFirst(8).dropLast(4))

            // Parse log file content
            var projectPath = sessionId
            var fullProjectPath = ""
            var lastPrompt = ""
            var lastTimestamp = Date()
            var claudePid: Int? = nil

            let blocks = content.components(separatedBy: "---")
            for block in blocks {
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                // Parse project path (full path and display name)
                if let projectRange = trimmed.range(of: "Project: ") {
                    let afterProject = trimmed[projectRange.upperBound...]
                    if let endIndex = afterProject.firstIndex(of: "\n") {
                        fullProjectPath = String(afterProject[..<endIndex])
                        let components = fullProjectPath.components(separatedBy: "/")
                        if let lastName = components.last, !lastName.isEmpty {
                            projectPath = lastName
                        }
                    }
                }

                // Parse PID from SessionStart (updated on each session start/resume)
                if trimmed.contains("EVENT: SessionStart"),
                   let pidRange = trimmed.range(of: "PID: ") {
                    let afterPid = trimmed[pidRange.upperBound...]
                    if let endIndex = afterPid.firstIndex(where: { !$0.isNumber }) {
                        claudePid = Int(afterPid[..<endIndex])
                    } else {
                        claudePid = Int(afterPid.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }

                // Parse prompt from UserPromptSubmit
                if trimmed.contains("EVENT: UserPromptSubmit"),
                   let promptRange = trimmed.range(of: "Prompt: ") {
                    let afterPrompt = trimmed[promptRange.upperBound...]
                    var prompt: String
                    if let endIndex = afterPrompt.firstIndex(of: "\n") {
                        prompt = String(afterPrompt[..<endIndex])
                    } else {
                        prompt = String(afterPrompt)
                    }
                    if !prompt.hasPrefix("<task-notification>") {
                        lastPrompt = prompt
                    }
                }

                // Parse timestamp
                if let startBracket = trimmed.firstIndex(of: "["),
                   let endBracket = trimmed.firstIndex(of: "]"),
                   startBracket < endBracket {
                    let timestampStr = String(trimmed[trimmed.index(after: startBracket)..<endBracket])
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    if let date = df.date(from: timestampStr) {
                        lastTimestamp = date
                    }
                }
            }

            // Determine status from events (forward scan)
            // State machine:
            //   SessionStart (startup/resume/clear) → freshWaiting
            //   SessionStart (compact, after auto PreCompact) → working (Claude continues)
            //   SessionStart (compact, after manual PreCompact) → freshWaiting
            //   PreCompact → working (compact operation in progress)
            //   SessionEnd → ended
            //   Stop (not SubagentStop) → freshWaiting
            //   UserPromptSubmit (not task-notification) → working
            var status: SessionStatus = .freshWaiting
            var lastCompactTrigger: String? = nil  // Track trigger from PreCompact event
            for block in blocks {
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if trimmed.contains("EVENT: SessionEnd") {
                    status = .ended
                } else if trimmed.contains("EVENT: PreCompact") {
                    // Compact operation starting → working
                    status = .working
                    // Record trigger for upcoming SessionStart (compact)
                    if trimmed.contains("Trigger: auto") {
                        lastCompactTrigger = "auto"
                    } else {
                        lastCompactTrigger = "manual"
                    }
                } else if trimmed.contains("EVENT: SessionStart") {
                    if trimmed.contains("Source: compact") {
                        // Compact finished: check trigger from PreCompact
                        if lastCompactTrigger == "auto" {
                            status = .working  // Auto compact, Claude continues working
                        } else {
                            status = .freshWaiting  // Manual compact, waiting for user
                        }
                    } else {
                        // startup/resume/clear → waiting for user input
                        status = .freshWaiting
                    }
                    lastCompactTrigger = nil  // Reset after processing
                } else if trimmed.contains("EVENT: Stop") && !trimmed.contains("EVENT: SubagentStop") {
                    status = .freshWaiting
                } else if trimmed.contains("EVENT: UserPromptSubmit") {
                    // Only count as working if it's a real user prompt (not system notification)
                    if !trimmed.contains("Prompt: <task-notification>") {
                        status = .working
                    }
                }
            }

            // Skip ended sessions
            guard status != .ended else { continue }

            // Skip sessions without any prompt (empty sessions that were reset/resumed away)
            guard !lastPrompt.isEmpty else { continue }

            // Try to get iTerm2 tab title for this session (only if we have titles)
            var tabTitle: String? = nil
            if !tabTitles.isEmpty, let pid = claudePid, let tty = getTtyForPid(pid) {
                if let rawTitle = tabTitles[tty] {
                    tabTitle = cleanTabTitle(rawTitle)
                }
            }

            // Determine waitingStartTime and adjust status based on elapsed time
            let waitingStartTime: Date?
            if status == .freshWaiting || status == .waiting {
                // Check if transitioning to waiting state from non-waiting state
                if let prevStatus = previousStates[sessionId],
                   prevStatus != .freshWaiting && prevStatus != .waiting {
                    // New waiting state: record current time
                    waitingStartTime = Date()
                } else if let oldSession = sessions[sessionId] {
                    // Already in waiting state: preserve existing timestamp
                    waitingStartTime = oldSession.waitingStartTime
                } else {
                    // First time seeing this session: record current time
                    waitingStartTime = Date()
                }

                // Adjust status based on how long we've been waiting
                if let startTime = waitingStartTime {
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed > 60 {
                        status = .waiting
                    } else {
                        status = .freshWaiting
                    }
                }
            } else {
                // Not waiting: clear timestamp
                waitingStartTime = nil
            }

            let session = SessionInfo(
                sessionId: sessionId,
                projectPath: projectPath,
                fullProjectPath: fullProjectPath,
                lastPrompt: lastPrompt,
                status: status,
                lastUpdate: lastTimestamp,
                claudePid: claudePid,
                tabTitle: tabTitle,
                waitingStartTime: waitingStartTime
            )

            newSessions[sessionId] = session

            // Send notification if newly waiting (freshWaiting or waiting, but not from waiting states)
            if (status == .freshWaiting || status == .waiting) {
                if let prevStatus = previousStates[sessionId],
                   prevStatus != .freshWaiting && prevStatus != .waiting {
                    sendStopNotification(session: session)
                }
            }
        }

        sessions = newSessions
    }

    // MARK: - Notifications

    func sendStopNotification(session: SessionInfo) {
        // Only send notifications if running as proper .app bundle
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            print("Stop notification (no bundle): \(session.projectPath)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Claude Ready"
        content.body = "\(session.projectPath) is waiting for input"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "stop-\(session.sessionId)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Notification error: \(error)")
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: - IP Monitor UI

    func setupUI() {
        let content = window.contentView!
        var y: CGFloat = 320

        // === Header ===
        let title = NSTextField(labelWithString: "IP Monitor")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.frame = NSRect(x: 20, y: y, width: 150, height: 24)
        content.addSubview(title)

        // Refresh button (in header)
        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(fetchIP))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.controlSize = .small
        refreshBtn.frame = NSRect(x: 210, y: y, width: 70, height: 24)
        content.addSubview(refreshBtn)

        // Status badge
        let badgeBg = NSView(frame: NSRect(x: 290, y: y, width: 100, height: 24))
        badgeBg.wantsLayer = true
        badgeBg.layer?.cornerRadius = 12
        badgeBg.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.15).cgColor
        content.addSubview(badgeBg)

        statusDot = NSView(frame: NSRect(x: 10, y: 8, width: 8, height: 8))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        badgeBg.addSubview(statusDot)

        statusLabel = NSTextField(labelWithString: "Loading...")
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .systemGray
        statusLabel.frame = NSRect(x: 24, y: 4, width: 70, height: 16)
        badgeBg.addSubview(statusLabel)

        y -= 50

        // === Request Info Card ===
        let requestBox = createCard(frame: NSRect(x: 20, y: y - 60, width: 360, height: 80))
        content.addSubview(requestBox)

        let reqTitle = NSTextField(labelWithString: "REQUEST INFO")
        reqTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        reqTitle.textColor = .secondaryLabelColor
        reqTitle.frame = NSRect(x: 12, y: 55, width: 100, height: 14)
        (requestBox.contentView ?? requestBox).addSubview(reqTitle)

        addRow(to: requestBox, icon: "🕐", label: "Time", y: 30, valueField: &timeValue)
        addRow(to: requestBox, icon: "🌐", label: "URL", y: 8, valueField: &urlValue)

        y -= 100

        // === Location Info Card ===
        let locBox = createCard(frame: NSRect(x: 20, y: y - 140, width: 360, height: 160))
        content.addSubview(locBox)

        let locTitle = NSTextField(labelWithString: "LOCATION INFO")
        locTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        locTitle.textColor = .secondaryLabelColor
        locTitle.frame = NSRect(x: 12, y: 135, width: 100, height: 14)
        (locBox.contentView ?? locBox).addSubview(locTitle)

        addRow(to: locBox, icon: "📍", label: "IP", y: 108, valueField: &ipValue)
        addRow(to: locBox, icon: "🏳️", label: "Country", y: 84, valueField: &countryValue)
        addRow(to: locBox, icon: "🗺️", label: "Region", y: 60, valueField: &regionValue)
        addRow(to: locBox, icon: "🏙️", label: "City", y: 36, valueField: &cityValue)
        addRow(to: locBox, icon: "🏢", label: "Org", y: 12, valueField: &orgValue)

        y -= 180

        // === Error Card (hidden) ===
        errorBox = NSBox(frame: NSRect(x: 20, y: y - 40, width: 360, height: 50))
        errorBox.boxType = .custom
        errorBox.cornerRadius = 8
        errorBox.borderWidth = 1
        errorBox.borderColor = NSColor.systemRed.withAlphaComponent(0.3)
        errorBox.fillColor = NSColor.systemRed.withAlphaComponent(0.1)
        errorBox.titlePosition = .noTitle
        errorBox.isHidden = true
        content.addSubview(errorBox)

        let errorContent: NSView = errorBox.contentView ?? errorBox
        let errIcon = NSTextField(labelWithString: "⚠️")
        errIcon.font = NSFont.systemFont(ofSize: 16)
        errIcon.frame = NSRect(x: 12, y: 14, width: 24, height: 22)
        errorContent.addSubview(errIcon)

        errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = NSFont.systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.frame = NSRect(x: 40, y: 14, width: 308, height: 22)
        errorContent.addSubview(errorLabel)
    }

    func createCard(frame: NSRect) -> NSBox {
        let box = NSBox(frame: frame)
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = NSColor.separatorColor
        box.fillColor = NSColor.controlBackgroundColor
        box.titlePosition = .noTitle
        return box
    }

    func addRow(to box: NSBox, icon: String, label: String, y: CGFloat, valueField: inout NSTextField!) {
        let container = box.contentView ?? box

        let iconLabel = NSTextField(labelWithString: icon)
        iconLabel.font = NSFont.systemFont(ofSize: 14)
        iconLabel.frame = NSRect(x: 12, y: y, width: 22, height: 18)
        container.addSubview(iconLabel)

        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 36, y: y, width: 55, height: 18)
        container.addSubview(titleLabel)

        valueField = NSTextField(labelWithString: "-")
        valueField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        valueField.textColor = .labelColor
        valueField.lineBreakMode = .byTruncatingTail
        valueField.frame = NSRect(x: 95, y: y, width: 250, height: 18)
        container.addSubview(valueField)
    }

    func setStatus(text: String, color: NSColor) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = color
        statusDot?.layer?.backgroundColor = color.cgColor
        statusDot?.superview?.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
    }

    func updateIPUI() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        timeValue?.stringValue = df.string(from: lastIPInfo.timestamp)
        urlValue?.stringValue = lastIPInfo.statusCode > 0 ? "\(lastIPInfo.url) [\(lastIPInfo.statusCode)]" : lastIPInfo.url
        ipValue?.stringValue = lastIPInfo.ip
        countryValue?.stringValue = lastIPInfo.country
        countryValue?.textColor = getColorForCountry(lastIPInfo.country)
        regionValue?.stringValue = lastIPInfo.region
        cityValue?.stringValue = lastIPInfo.city
        orgValue?.stringValue = lastIPInfo.org

        if let err = lastIPInfo.error {
            errorLabel?.stringValue = err
            errorBox?.isHidden = false
            setStatus(text: "Error", color: .systemRed)
        } else {
            errorBox?.isHidden = true
            if lastIPInfo.country == "-" {
                setStatus(text: "Loading...", color: .systemGray)
            } else {
                setStatus(text: "Connected", color: .systemGreen)
            }
        }
    }

    func getColorForCountry(_ country: String) -> NSColor {
        switch country {
        case "US": return .systemGreen
        case "CN": return .systemRed
        case "-", "ERR": return .labelColor
        default: return .systemOrange
        }
    }

    func createStatusImage(text: String, backgroundColor: NSColor) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let padding: CGFloat = 6
        let h: CGFloat = 18
        let w = size.width + padding * 2

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: 4, yRadius: 4)
        backgroundColor.setFill()
        path.fill()
        text.draw(in: NSRect(x: padding, y: (h - size.height) / 2, width: size.width, height: size.height), withAttributes: attrs)
        img.unlockFocus()
        return img
    }

    func updateStatusItem(country: String, color: NSColor) {
        statusItem.button?.image = createStatusImage(text: country, backgroundColor: color)
        statusItem.button?.title = ""
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        // Stop tab title refresh timer if session window is being closed
        if sender == sessionWindow {
            tabTitleRefreshTimer?.invalidate()
            tabTitleRefreshTimer = nil
        }
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc func fetchIP() {
        fetchIPInternal(showLoading: true)
    }

    func fetchIPInternal(showLoading: Bool) {
        if showLoading {
            updateStatusItem(country: "...", color: .gray)
            setStatus(text: "Fetching...", color: .systemOrange)
        }

        lastIPInfo = IPInfo()
        lastIPInfo.url = "https://ipinfo.io/json"
        lastIPInfo.timestamp = Date()
        updateIPUI()

        guard let url = URL(string: lastIPInfo.url) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, resp, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let err = err {
                    self.lastIPInfo.error = err.localizedDescription
                    self.updateIPUI()
                    self.updateStatusItem(country: "ERR", color: .gray)
                    return
                }
                if let http = resp as? HTTPURLResponse {
                    self.lastIPInfo.statusCode = http.statusCode
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.lastIPInfo.error = "Invalid response"
                    self.updateIPUI()
                    self.updateStatusItem(country: "ERR", color: .gray)
                    return
                }
                self.lastIPInfo.ip = json["ip"] as? String ?? "-"
                self.lastIPInfo.country = json["country"] as? String ?? "-"
                self.lastIPInfo.region = json["region"] as? String ?? "-"
                self.lastIPInfo.city = json["city"] as? String ?? "-"
                self.lastIPInfo.org = json["org"] as? String ?? "-"
                self.lastIPInfo.error = nil

                let country = self.lastIPInfo.country
                self.updateStatusItem(country: country, color: self.getColorForCountry(country))
                self.updateIPUI()
            }
        }.resume()
    }

    // MARK: - AI Productivity Stats

    @objc func showProductivityStats() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let report = self.runProductivityScript()
            DispatchQueue.main.async {
                self.displayProductivityReport(report)
            }
        }
    }

    func runProductivityScript() -> String {
        let scriptPath = NSString(string: "~/.claude/scripts/productivity_stats.py").expandingTildeInPath

        let task = Process()
        task.launchPath = "/usr/bin/python3"
        task.arguments = [scriptPath]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let report = String(data: data, encoding: .utf8) {
                return report
            }
        } catch {
            return "Error running stats script: \(error.localizedDescription)"
        }

        return "No data available"
    }

    func displayProductivityReport(_ report: String) {
        // Reuse existing window or create new one
        if statsWindow == nil {
            statsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            statsWindow!.title = "AI Productivity Stats - Today"
            statsWindow!.center()
            statsWindow!.delegate = self
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 480))
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.string = report

        scrollView.documentView = textView
        statsWindow!.contentView = scrollView

        NSApp.activate(ignoringOtherApps: true)
        statsWindow!.makeKeyAndOrderFront(nil)
        statsWindow!.orderFrontRegardless()
    }

    func calculateProductivityStats() -> ProductivityStats {
        let logFile = NSString(string: "~/.claude/logs/lifecycle/all-events.jsonl").expandingTildeInPath

        let today = Calendar.current.startOfDay(for: Date())
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var sessions: [String: SessionTimeline] = [:]

        // Stream file line-by-line to avoid memory issues
        guard let fileHandle = FileHandle(forReadingAtPath: logFile) else {
            return ProductivityStats(sessions: [:], concurrencyTimeline: [])
        }
        defer { fileHandle.closeFile() }

        // Robust line-by-line parsing (handles malformed JSON)
        var currentTimestamp: Date? = nil
        var currentEvent: String? = nil
        var currentSessionId: String? = nil
        var lineBuffer = ""

        while true {
            let data = fileHandle.readData(ofLength: 8192)  // Read 8KB chunks
            if data.isEmpty { break }

            guard let chunk = String(data: data, encoding: .utf8) else { continue }
            lineBuffer += chunk

            let lines = lineBuffer.components(separatedBy: "\n")
            lineBuffer = lines.last ?? ""  // Keep incomplete line for next iteration

            for line in lines.dropLast() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

                // Extract timestamp using regex
                if trimmed.contains("\"timestamp\":") {
                    let pattern = "\"timestamp\":\\s*\"([0-9]{4}-[0-9]{2}-[0-9]{2}\\s[0-9]{2}:[0-9]{2}:[0-9]{2})\""
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                       let timestampRange = Range(match.range(at: 1), in: trimmed) {
                        let timestampStr = String(trimmed[timestampRange])
                        if let timestamp = dateFormatter.date(from: timestampStr), timestamp >= today {
                            currentTimestamp = timestamp
                        } else {
                            currentTimestamp = nil
                        }
                    }
                }

                // Extract event type
                if trimmed.contains("\"event\":") && currentTimestamp != nil {
                    let pattern = "\"event\":\\s*\"([A-Za-z]+)\""
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                       let eventRange = Range(match.range(at: 1), in: trimmed) {
                        currentEvent = String(trimmed[eventRange])
                    }
                }

                // Extract session ID
                if trimmed.contains("\"session_id\":") && currentTimestamp != nil {
                    let pattern = "\"session_id\":\\s*\"([a-f0-9-]+)\""
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                       let sessionRange = Range(match.range(at: 1), in: trimmed) {
                        currentSessionId = String(trimmed[sessionRange])
                    }
                }

                // Complete event when we hit closing brace (heuristic: line with only "}")
                if trimmed == "}" && currentTimestamp != nil && currentEvent != nil && currentSessionId != nil {
                    if sessions[currentSessionId!] == nil {
                        sessions[currentSessionId!] = SessionTimeline(sessionId: currentSessionId!, events: [])
                    }

                    sessions[currentSessionId!]?.events.append(StateEvent(
                        timestamp: currentTimestamp!,
                        eventType: currentEvent!,
                        eventData: [:]
                    ))

                    // Reset for next event
                    currentTimestamp = nil
                    currentEvent = nil
                    currentSessionId = nil
                }
            }
        }

        // Calculate concurrency timeline
        let concurrencyTimeline = calculateConcurrency(sessions: sessions)

        return ProductivityStats(sessions: sessions, concurrencyTimeline: concurrencyTimeline)
    }

    func calculateConcurrency(sessions: [String: SessionTimeline]) -> [ConcurrencyPeriod] {
        var stateChanges: [(Date, String, SessionStatus)] = []

        // Collect all state changes
        for (sessionId, timeline) in sessions {
            var currentStatus: SessionStatus = .waiting
            for event in timeline.events.sorted(by: { $0.timestamp < $1.timestamp }) {
                let newStatus: SessionStatus
                switch event.eventType {
                case "SessionStart":
                    newStatus = .waiting
                case "UserPromptSubmit":
                    newStatus = .working
                case "Stop":
                    if event.eventData["event"] as? String != "SubagentStop" {
                        newStatus = .waiting
                    } else {
                        newStatus = currentStatus
                    }
                case "SessionEnd":
                    newStatus = .ended
                default:
                    newStatus = currentStatus
                }

                if newStatus != currentStatus {
                    stateChanges.append((event.timestamp, sessionId, newStatus))
                    currentStatus = newStatus
                }
            }
        }

        stateChanges.sort { $0.0 < $1.0 }

        // Calculate concurrency over time
        var periods: [ConcurrencyPeriod] = []
        var sessionStates: [String: SessionStatus] = [:]
        var lastTimestamp: Date?

        for (timestamp, sessionId, newStatus) in stateChanges {
            if let last = lastTimestamp, last < timestamp {
                let workingCount = sessionStates.values.filter { $0 == .working }.count
                if let lastPeriod = periods.last, lastPeriod.concurrency == workingCount {
                    // Extend last period
                    periods[periods.count - 1].endTime = timestamp
                } else {
                    periods.append(ConcurrencyPeriod(startTime: last, endTime: timestamp, concurrency: workingCount))
                }
            }

            sessionStates[sessionId] = newStatus
            if newStatus == .ended {
                sessionStates.removeValue(forKey: sessionId)
            }
            lastTimestamp = timestamp
        }

        // Add final period if needed
        if let last = lastTimestamp {
            let workingCount = sessionStates.values.filter { $0 == .working }.count
            if let lastPeriod = periods.last, lastPeriod.concurrency == workingCount {
                periods[periods.count - 1].endTime = Date()
            } else {
                periods.append(ConcurrencyPeriod(startTime: last, endTime: Date(), concurrency: workingCount))
            }
        }

        return periods
    }

    func displayProductivityStats(_ stats: ProductivityStats) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Productivity Stats - Today"
        window.center()

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 480))
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]

        var report = "=== AI PRODUCTIVITY REPORT ===\n"
        report += "Date: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none))\n\n"

        // Session stats
        report += "📊 SESSION SUMMARY\n"
        report += "Total sessions today: \(stats.sessions.count)\n\n"

        for (sessionId, timeline) in stats.sessions.sorted(by: { $0.key < $1.key }) {
            let workingTime = calculateWorkingTime(timeline: timeline)
            report += "Session: \(sessionId.prefix(8))...\n"
            report += "  Working time: \(formatDuration(workingTime))\n"
            report += "  Events: \(timeline.events.count)\n\n"
        }

        // Concurrency stats
        report += "\n🚀 CONCURRENCY ANALYSIS\n"
        let maxConcurrency = stats.concurrencyTimeline.map { $0.concurrency }.max() ?? 0
        report += "Max concurrent working sessions: \(maxConcurrency)\n\n"

        var concurrencySummary: [Int: TimeInterval] = [:]
        for period in stats.concurrencyTimeline {
            let duration = period.endTime.timeIntervalSince(period.startTime)
            concurrencySummary[period.concurrency, default: 0] += duration
        }

        for level in concurrencySummary.keys.sorted(by: >) {
            let duration = concurrencySummary[level]!
            report += "Concurrency \(level): \(formatDuration(duration))\n"
        }

        // Find longest max concurrency period
        if let maxPeriod = stats.concurrencyTimeline.filter({ $0.concurrency == maxConcurrency }).max(by: { $0.duration < $1.duration }) {
            report += "\nLongest max concurrency period:\n"
            report += "  From \(formatTime(maxPeriod.startTime)) to \(formatTime(maxPeriod.endTime))\n"
            report += "  Duration: \(formatDuration(maxPeriod.duration))\n"
        }

        // AI utilization
        let totalTime = stats.concurrencyTimeline.reduce(0.0) { $0 + $1.duration }
        let idleTime = concurrencySummary[0] ?? 0
        if totalTime > 0 {
            let utilization = ((totalTime - idleTime) / totalTime) * 100
            report += "\n📈 AI UTILIZATION: \(String(format: "%.1f%%", utilization))\n"
        }

        textView.string = report
        scrollView.documentView = textView
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
    }

    func calculateWorkingTime(timeline: SessionTimeline) -> TimeInterval {
        var totalWorking: TimeInterval = 0
        var currentStatus: SessionStatus = .waiting
        var statusStartTime: Date?

        for event in timeline.events.sorted(by: { $0.timestamp < $1.timestamp }) {
            let newStatus: SessionStatus
            switch event.eventType {
            case "UserPromptSubmit":
                newStatus = .working
            case "Stop":
                newStatus = .waiting
            default:
                newStatus = currentStatus
            }

            if newStatus != currentStatus {
                if let startTime = statusStartTime, currentStatus == .working {
                    totalWorking += event.timestamp.timeIntervalSince(startTime)
                }
                currentStatus = newStatus
                statusStartTime = event.timestamp
            }
        }

        // Add current period if still working
        if currentStatus == .working, let startTime = statusStartTime {
            totalWorking += Date().timeIntervalSince(startTime)
        }

        return totalWorking
    }

    func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Productivity Stats Data Structures

struct StateEvent {
    var timestamp: Date
    var eventType: String
    var eventData: [String: Any]
}

struct SessionTimeline {
    var sessionId: String
    var events: [StateEvent]
}

struct ConcurrencyPeriod {
    var startTime: Date
    var endTime: Date
    var concurrency: Int

    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

struct ProductivityStats {
    var sessions: [String: SessionTimeline]
    var concurrencyTimeline: [ConcurrencyPeriod]
}

print("Starting Agent Monitor...")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
print("Running...")
app.run()
