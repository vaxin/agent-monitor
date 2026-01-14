import Cocoa
import UserNotifications

// MARK: - Data Structures

enum SessionStatus {
    case working    // Claude is processing
    case waiting    // Waiting for user input (highlight)
    case ended      // Session ended (don't show)
}

struct SessionInfo {
    var sessionId: String
    var projectPath: String
    var lastPrompt: String
    var status: SessionStatus
    var lastUpdate: Date
}

// MARK: - SessionItemView

class SessionItemView: NSView {
    var sessionId: String = ""
    weak var delegate: AppDelegate?

    override func mouseDown(with event: NSEvent) {
        delegate?.sessionItemClicked(sessionId: sessionId)
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!

    // Session Monitor
    var sessionWindow: NSWindow!
    var sessionStackView: NSStackView!
    var sessions: [String: SessionInfo] = [:]
    var selectedSessionId: String? = nil
    var fsEventStream: FSEventStreamRef?
    let logDir = NSString(string: "~/.claude/logs/lifecycle").expandingTildeInPath

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
        updateStatusItem()

        // Setup menu (for right-click)
        statusMenu = NSMenu()
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

        // Setup Session Monitor window
        setupSessionWindow()

        // Start file monitoring
        startFileMonitoring()
        reloadSessions()

        print("Agent Monitor ready")
    }

    // MARK: - Status Item

    func updateStatusItem() {
        let waitingCount = sessions.values.filter { $0.status == .waiting }.count
        let workingCount = sessions.values.filter { $0.status == .working }.count

        let color: NSColor
        let text: String

        if waitingCount > 0 {
            color = .systemYellow
            text = "\(waitingCount)"
        } else if workingCount > 0 {
            color = .systemGreen
            text = "\(workingCount)"
        } else {
            color = .systemGray
            text = "0"
        }

        statusItem.button?.image = createStatusImage(text: text, backgroundColor: color)
        statusItem.button?.title = ""
    }

    func createStatusImage(text: String, backgroundColor: NSColor) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let padding: CGFloat = 6
        let h: CGFloat = 18
        let w = max(size.width + padding * 2, h)

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: 4, yRadius: 4)
        backgroundColor.setFill()
        path.fill()
        text.draw(in: NSRect(x: (w - size.width) / 2, y: (h - size.height) / 2, width: size.width, height: size.height), withAttributes: attrs)
        img.unlockFocus()
        return img
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

    func toggleSessionWindow() {
        if sessionWindow.isVisible {
            sessionWindow.orderOut(nil)
        } else {
            reloadSessions()
            updateSessionUI()
            sessionWindow.makeKeyAndOrderFront(nil)
        }
    }

    func updateSessionUI() {
        // Clear existing views
        sessionStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Filter active sessions (not ended)
        let activeSessions = sessions.values
            .filter { $0.status != .ended }
            .sorted { s1, s2 in
                // Waiting sessions first
                if s1.status == .waiting && s2.status != .waiting { return true }
                if s1.status != .waiting && s2.status == .waiting { return false }
                return s1.lastUpdate > s2.lastUpdate
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

        // Update status item
        updateStatusItem()
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
        container.layer?.cornerRadius = 6

        // Background color based on status and selection
        if isSelected {
            container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        } else if session.status == .waiting {
            container.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.12).cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
        } else {
            container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            container.layer?.borderWidth = 0.5
            container.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        }

        // Status indicator dot
        let statusDot = NSView(frame: NSRect(x: 8, y: 10, width: 8, height: 8))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        let dotColor = session.status == .waiting ? NSColor.systemYellow : NSColor.systemGreen
        statusDot.layer?.backgroundColor = dotColor.cgColor
        if session.status == .waiting {
            statusDot.layer?.shadowColor = NSColor.systemYellow.cgColor
            statusDot.layer?.shadowRadius = 3
            statusDot.layer?.shadowOpacity = 0.6
            statusDot.layer?.shadowOffset = .zero
        }
        container.addSubview(statusDot)

        // Project name
        let nameLabel = NSTextField(labelWithString: session.projectPath)
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: 22, y: 6, width: 70, height: 16)
        container.addSubview(nameLabel)

        // Prompt description
        let prompt = session.lastPrompt.isEmpty ? "..." : session.lastPrompt
        let descLabel = NSTextField(labelWithString: prompt)
        descLabel.font = NSFont.systemFont(ofSize: 10)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.frame = NSRect(x: 94, y: 6, width: isSelected ? 150 : 175, height: 16)
        container.addSubview(descLabel)

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
        reloadSessions()

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

        // Always update status item
        updateStatusItem()
    }

    func reloadSessions() {
        var newSessions: [String: SessionInfo] = [:]
        var previousStates: [String: SessionStatus] = [:]

        // Save previous states for notification comparison
        for (id, session) in sessions {
            previousStates[id] = session.status
        }

        // Scan session-*.log files in directory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logDir) else {
            return
        }

        for file in files {
            guard file.hasPrefix("session-") && file.hasSuffix(".log") else { continue }

            let filePath = (logDir as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: filePath) else {
                continue
            }
            // Use lossy conversion to handle corrupted UTF-8 characters
            let content = String(decoding: data, as: UTF8.self)

            // Extract session ID from filename: session-{id}.log
            let sessionId = String(file.dropFirst(8).dropLast(4))

            // Parse log file content
            var projectPath = sessionId
            var lastPrompt = ""
            var lastTimestamp = Date()

            let blocks = content.components(separatedBy: "---")
            for block in blocks {
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                // Parse project path (only last directory name)
                if let projectRange = trimmed.range(of: "Project: ") {
                    let afterProject = trimmed[projectRange.upperBound...]
                    if let endIndex = afterProject.firstIndex(of: "\n") {
                        let fullPath = String(afterProject[..<endIndex])
                        let components = fullPath.components(separatedBy: "/")
                        if let lastName = components.last, !lastName.isEmpty {
                            projectPath = lastName
                        }
                    }
                }

                // Parse prompt from UserPromptSubmit
                if trimmed.contains("EVENT: UserPromptSubmit"),
                   let promptRange = trimmed.range(of: "Prompt: ") {
                    let afterPrompt = trimmed[promptRange.upperBound...]
                    // Get first line or up to certain length
                    if let endIndex = afterPrompt.firstIndex(of: "\n") {
                        lastPrompt = String(afterPrompt[..<endIndex])
                    } else {
                        lastPrompt = String(afterPrompt)
                    }
                }

                // Parse timestamp: [2026-01-14 10:17:06]
                if let startBracket = trimmed.firstIndex(of: "["),
                   let endBracket = trimmed.firstIndex(of: "]") {
                    let timestampStr = String(trimmed[trimmed.index(after: startBracket)..<endBracket])
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    if let date = df.date(from: timestampStr) {
                        lastTimestamp = date
                    }
                }
            }

            // Determine status based on events
            // - SessionEnd -> ended
            // - Stop (not SubagentStop) -> waiting (Claude finished, waiting for user)
            // - UserPromptSubmit -> working (user started new input)
            // - SessionStart (startup) -> working
            var status: SessionStatus = .working

            for block in blocks {
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if trimmed.contains("EVENT: SessionEnd") {
                    status = .ended
                } else if trimmed.contains("EVENT: Stop") && !trimmed.contains("EVENT: SubagentStop") {
                    // Stop event means Claude finished responding, waiting for user
                    status = .waiting
                } else if trimmed.contains("EVENT: UserPromptSubmit") {
                    status = .working
                } else if trimmed.contains("EVENT: SessionStart") && trimmed.contains("Source: startup") {
                    // Only fresh startup sets working, ignore compact/resume
                    status = .working
                }
            }

            // Skip ended sessions
            guard status != .ended else { continue }

            // Skip sessions without any prompt (empty sessions that were reset/resumed away)
            guard !lastPrompt.isEmpty else { continue }

            let session = SessionInfo(
                sessionId: sessionId,
                projectPath: projectPath,
                lastPrompt: lastPrompt,
                status: status,
                lastUpdate: lastTimestamp
            )

            newSessions[sessionId] = session

            // Send notification if newly waiting
            if status == .waiting && previousStates[sessionId] != .waiting {
                sendStopNotification(session: session)
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

    // MARK: - Window Delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

print("Starting Agent Monitor...")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
print("Running...")
app.run()
