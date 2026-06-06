import Carbon
import Cocoa
import Darwin
import Foundation

// MARK: - App Delegate

@main
final class ScriptDockApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private lazy var statusIcon = makeStatusIcon()
    fileprivate let store = TaskStore()
    fileprivate var configErrors: [String: String] = [:]  // taskID -> errorMessage
    private var dashboardController: DashboardWindowController?
    private let selfLaunchAgentLabel = "com.pangyun.ScriptDock.app"
    private var refreshTimer: Timer?
    private var quickLaunchPanel: QuickLaunchPanel?
    private var globalHotKey: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?
    private var isTerminating = false
    private(set) var supervisor: Supervisor!

    static func main() {
        let app = NSApplication.shared
        let delegate = ScriptDockApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        do {
            try store.ensureSupportFiles()
        } catch {
            showError("Failed to prepare ScriptDock files: \(error.localizedDescription)")
        }
        supervisor = Supervisor(store: store)
        supervisor.start()
        migrateFromLaunchd()
        ensureSelfLaunchAgent()
        reloadConfig(showAlert: false)
        setupStatusItem()
        registerGlobalHotKey()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        guard supervisor.hasTasksToStopOnAppQuit() else { return .terminateNow }

        isTerminating = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        supervisor.shutdownForAppQuit(timeout: 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (required for window management)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Hide ScriptDock", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit ScriptDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (enables Cmd+C / Cmd+V / Cmd+A in text fields)
        let editMenu = NSMenu()
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu (enables Cmd+W)
        let windowMenu = NSMenu()
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = statusIcon
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleProportionallyDown
            button.title = ""
            button.toolTip = "ScriptDock"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        rebuildMenu()
    }

    private func makeStatusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let window = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 4.0, width: 13.0, height: 10.0), xRadius: 2.6, yRadius: 2.6)
        window.lineWidth = 1.6
        window.stroke()

        let prompt = NSBezierPath()
        prompt.move(to: NSPoint(x: 5.2, y: 9.8))
        prompt.line(to: NSPoint(x: 7.4, y: 8.6))
        prompt.line(to: NSPoint(x: 5.2, y: 7.4))
        prompt.lineWidth = 1.5
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        prompt.stroke()

        let cursor = NSBezierPath()
        cursor.move(to: NSPoint(x: 8.8, y: 7.3))
        cursor.line(to: NSPoint(x: 12.8, y: 7.3))
        cursor.lineWidth = 1.5
        cursor.lineCapStyle = .round
        cursor.stroke()

        let dock = NSBezierPath(roundedRect: NSRect(x: 4.1, y: 2.4, width: 9.8, height: 1.3), xRadius: 0.65, yRadius: 0.65)
        dock.fill()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d"))
        menu.addItem(NSMenuItem.separator())

        if store.tasks.isEmpty {
            let empty = NSMenuItem(title: "No tasks configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for task in store.tasks {
                addTask(task, to: menu)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfigItem), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "MCP Info…", action: #selector(showMCPInfoFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Logs Folder", action: #selector(openLogsFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About ScriptDock", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
        updateStatusTitle()
    }

    private func addTask(_ task: ScriptTask, to menu: NSMenu) {
        let running = isRunning(task)
        let taskItem = NSMenuItem(title: "\(running ? "●" : "○") \(task.name)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let status = NSMenuItem(title: running ? "Running" : "Stopped", action: nil, keyEquivalent: "")
        status.isEnabled = false
        submenu.addItem(status)
        submenu.addItem(NSMenuItem.separator())

        submenu.addItem(menuItem("Start", action: #selector(startTask(_:)), task: task))
        submenu.addItem(menuItem("Stop", action: #selector(stopTask(_:)), task: task))
        submenu.addItem(menuItem("Restart", action: #selector(restartTask(_:)), task: task))
        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(menuItem("Edit Task", action: #selector(editTaskFromMenu(_:)), task: task))

        let hasPorts = !PortInspector.inferredPorts(for: task).isEmpty
        if hasPorts {
            submenu.addItem(NSMenuItem.separator())
            submenu.addItem(menuItem("Check Ports", action: #selector(checkPorts(_:)), task: task))
            submenu.addItem(menuItem("Kill Port Blockers", action: #selector(killPortBlockers(_:)), task: task))
        }

        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(menuItem("Show Recent Logs", action: #selector(showRecentLogs(_:)), task: task))
        submenu.addItem(menuItem("Open Output Log", action: #selector(openOutputLog(_:)), task: task))
        submenu.addItem(menuItem("Open Error Log", action: #selector(openErrorLog(_:)), task: task))
        if task.openURL != nil {
            submenu.addItem(menuItem("Open URL", action: #selector(openTaskURL(_:)), task: task))
        }

        taskItem.submenu = submenu
        menu.addItem(taskItem)
    }

    private func menuItem(_ title: String, action: Selector, task: ScriptTask) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = task.id
        return item
    }

    // MARK: - Config

    private func reloadConfig(showAlert: Bool) {
        let result = store.reload()
        configErrors = result.errors
        supervisor.syncTasks()
        if showAlert && !result.errors.isEmpty {
            let summary = "\(result.errors.count) task(s) have config errors"
            dashboardController?.showInlineError(summary)
            let fullMsg = result.errors.values.joined(separator: "\n\n---\n\n")
            dashboardController?.appendSystemLog(fullMsg)
        }
        rebuildMenu()
        dashboardController?.reload()
    }

    @objc private func reloadConfigItem() {
        reloadConfig(showAlert: true)
    }

    @objc private func openConfig() {
        openConfigFile()
    }

    @objc private func openLogsFolder() {
        openLogsDirectory()
    }

    @objc private func openDashboard() {
        showDashboard()
    }

    @objc private func showMCPInfoFromMenu() {
        showDashboard()
        dashboardController?.showMCPInfo()
    }

    @objc private func showAbout() {
        showInfo("ScriptDock manages local scripts as supervised processes.\n\nConfig:\n\(store.configURL.path)")
    }

    // MARK: - Task Actions (Menu)

    @objc private func startTask(_ sender: NSMenuItem) {
        guard let task = store.task(byID: sender.representedObject as? String ?? "") else { return }
        start(task)
    }

    @objc private func stopTask(_ sender: NSMenuItem) {
        guard let task = store.task(byID: sender.representedObject as? String ?? "") else { return }
        stop(task)
    }

    @objc private func restartTask(_ sender: NSMenuItem) {
        guard let task = store.task(byID: sender.representedObject as? String ?? "") else { return }
        restart(task)
    }

    @objc private func editTaskFromMenu(_ sender: NSMenuItem) {
        guard let task = store.task(byID: sender.representedObject as? String ?? "") else { return }
        showDashboard()
        dashboardController?.editTask(task)
    }

    @objc private func checkPorts(_ sender: NSMenuItem) {
        guard let task = store.task(byID: sender.representedObject as? String ?? "") else { return }
        showInfo(PortInspector.portReport(for: task))
    }

    @objc private func killPortBlockers(_ sender: NSMenuItem) {
        guard let task = store.task(byID: sender.representedObject as? String ?? "") else { return }
        killBlockers(for: task, showResult: true, askFirst: true)
    }

    @objc private func showRecentLogs(_ sender: NSMenuItem) {
        guard let task = store.task(byID: sender.representedObject as? String ?? "") else { return }
        showInfo(LogBuffer.recentLogSummary(for: task, store: store, supervisor: supervisor))
    }

    @objc private func openOutputLog(_ sender: NSMenuItem) {
        guard let task = store.task(byID: sender.representedObject as? String ?? "") else { return }
        let path = store.stdoutURL(for: task)
        ensureFile(path)
        NSWorkspace.shared.open(path)
    }

    @objc private func openErrorLog(_ sender: NSMenuItem) {
        guard let task = store.task(byID: sender.representedObject as? String ?? "") else { return }
        let path = store.stderrURL(for: task)
        ensureFile(path)
        NSWorkspace.shared.open(path)
    }

    @objc private func openTaskURL(_ sender: NSMenuItem) {
        guard let task = store.task(byID: sender.representedObject as? String ?? "") else { return }
        openURL(for: task)
    }

    @objc private func revealScript(_ sender: NSMenuItem) {
        guard let task = store.task(byID: sender.representedObject as? String ?? "") else { return }
        revealExecutable(for: task)
    }

    // MARK: - Task Actions (Internal)

    fileprivate func start(_ task: ScriptTask, extraArgs: [String]? = nil) {
        if let problem = store.preflightProblem(for: task) {
            dashboardController?.showInlineError(problem)
            return
        }
        guard checkPortDependencies(task) else { return }
        guard resolvePortConflictsBeforeStart(task) else { return }

        if let error = supervisor.startTask(id: task.id, source: "manual", extraArgs: extraArgs) {
            dashboardController?.showInlineError("Failed to start \(task.name): \(error)")
            rebuildMenu()
            dashboardController?.reload()
            return
        }
        checkTaskAfterStart(task)
        rebuildMenu()
        dashboardController?.reload()
    }

    fileprivate func stop(_ task: ScriptTask) {
        if let error = supervisor.stopTask(id: task.id) {
            dashboardController?.showInlineError("Failed to stop \(task.name): \(error)")
        }
        rebuildMenu()
        dashboardController?.reload()
    }

    fileprivate func restart(_ task: ScriptTask) {
        if let problem = store.preflightProblem(for: task) {
            showError(problem)
            return
        }
        guard resolvePortConflictsBeforeStart(task) else { return }
        if let error = supervisor.restartTask(id: task.id, source: "manual") {
            dashboardController?.showInlineError("Failed to restart \(task.name): \(error)")
            rebuildMenu()
            dashboardController?.reload()
            return
        }
        checkTaskAfterStart(task)
        rebuildMenu()
        dashboardController?.reload()
    }

    // MARK: - Dashboard Accessors

    fileprivate func configuredTasks() -> [ScriptTask] {
        store.tasks
    }

    fileprivate func taskError(for task: ScriptTask) -> String? {
        configErrors[task.id]
    }

    fileprivate func isRunning(_ task: ScriptTask) -> Bool {
        supervisor.taskStatus(id: task.id)?.state == .running
    }

    fileprivate func pid(for task: ScriptTask) -> Int32? {
        supervisor.taskStatus(id: task.id)?.pid
    }

    fileprivate func inferredPorts(for task: ScriptTask) -> [Int] {
        PortInspector.inferredPorts(for: task)
    }

    fileprivate func portReport(for task: ScriptTask) -> String {
        PortInspector.portReport(for: task)
    }

    fileprivate func logText(for task: ScriptTask, stream: LogStream, maxBytes: Int = 2_000_000) -> String {
        // Prefer RingBuffer (from Supervisor) — has timestamps injected by Pipe handler
        if let result = supervisor.readLogs(id: task.id, stream: stream, since: 0) {
            let text = String(data: result.data, encoding: .utf8) ?? ""
            if !text.isEmpty { return text }
        }
        // Fallback: read from log files
        return LogBuffer.logText(for: task, stream: stream, store: store, maxBytes: maxBytes)
    }

    @discardableResult
    fileprivate func killBlockers(for task: ScriptTask, showResult: Bool, askFirst: Bool = true) -> Bool {
        let taskPid = pid(for: task)
        let blockers = PortInspector.blockingPortOwners(for: task, taskPid: taskPid)
        if blockers.isEmpty {
            if showResult {
                showInfo("No external port blockers found for \(task.name).")
            }
            return true
        }

        if askFirst {
            let alert = NSAlert()
            alert.messageText = "Kill Port Blockers?"
            alert.alertStyle = .warning
            alert.informativeText = "ScriptDock will send SIGTERM to these processes:\n\n\(PortInspector.formatPortOwners(blockers))"
            alert.addButton(withTitle: "Kill")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return false
            }
        }

        let result = PortInspector.killPIDs(blockers.map(\.pid))
        if showResult {
            let killed = blockers.filter { result.killed.contains($0.pid) }
            let failed = blockers.filter { result.failed.contains($0.pid) }
            let killedText = killed.isEmpty ? "(none)" : PortInspector.formatPortOwners(killed)
            let failedText = failed.isEmpty ? "(none)" : PortInspector.formatPortOwners(failed)
            showInfo("""
            Port blocker cleanup for \(task.name)

            Terminated:
            \(killedText)

            Failed:
            \(failedText)
            """)
        }
        return result.failed.isEmpty
    }

    fileprivate func showDashboard() {
        if dashboardController == nil {
            dashboardController = DashboardWindowController(app: self)
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboardController?.window?.makeKeyAndOrderFront(nil)
        dashboardController?.reload()
    }

    fileprivate func reloadConfiguration(showAlert: Bool) {
        reloadConfig(showAlert: showAlert)
        dashboardController?.reload()
    }

    fileprivate func openConfigFile() {
        NSWorkspace.shared.open(store.configURL)
    }

    fileprivate func openLogsDirectory() {
        NSWorkspace.shared.open(store.logsURL)
    }

    fileprivate func openURL(for task: ScriptTask) {
        guard let rawURL = task.openURL, let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }

    fileprivate func revealExecutable(for task: ScriptTask) {
        guard let first = task.programArguments.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
    }

    // MARK: - Process Management

    private func checkTaskAfterStart(_ task: ScriptTask) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.rebuildMenu()
            self.dashboardController?.reload()
            if self.isRunning(task) { return }

            // One-shot tasks are expected to exit quickly — not an error
            if task.effectiveMode == .oneshot { return }

            let summary = LogBuffer.recentLogSummary(for: task, store: self.store, supervisor: self.supervisor)
            let msg = """
            \(task.name) did not stay running.

            \(summary)
            """
            self.dashboardController?.showInlineError(msg)
        }
    }

    private func resolvePortConflictsBeforeStart(_ task: ScriptTask) -> Bool {
        let taskPid = pid(for: task)
        let blockers = PortInspector.blockingPortOwners(for: task, taskPid: taskPid)
        guard !blockers.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = "Port Conflict"
        alert.alertStyle = .warning
        alert.informativeText = "\(task.name) needs a port that is already in use.\n\n\(PortInspector.formatPortOwners(blockers))"
        alert.addButton(withTitle: "Kill Blockers and Start")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            dashboardController?.showInlineError("\(task.name): port conflict — \(PortInspector.formatPortOwners(blockers))")
            return false
        }
        return killBlockers(for: task, showResult: false, askFirst: false)
    }

    /// Check if ports referenced in URLs/args (dependencies) have services listening.
    /// Ports that the task itself binds (from bindingPorts) are excluded — the task provides them.
    private func checkPortDependencies(_ task: ScriptTask) -> Bool {
        let bindingPorts = Set(PortInspector.bindingPorts(for: task))

        var depPorts = Set<Int>()
        if let rawURL = task.openURL, let url = URLComponents(string: rawURL), let port = url.port {
            depPorts.insert(port)
        }
        for arg in task.programArguments {
            if arg.hasPrefix("http://") || arg.hasPrefix("https://") {
                if let url = URLComponents(string: arg), let port = url.port {
                    depPorts.insert(port)
                }
            }
        }
        // Remove ports that this task itself will bind
        depPorts.subtract(bindingPorts)
        guard !depPorts.isEmpty else { return true }

        let unreachable = depPorts.filter { PortInspector.portOwners(for: $0).isEmpty }
        guard !unreachable.isEmpty else { return true }

        let portList = unreachable.sorted().map { ":\($0)" }.joined(separator: ", ")
        let msg = "\(task.name) depends on port\(unreachable.count > 1 ? "s" : "") \(portList) but no service is listening. Start the dependent task first."
        dashboardController?.showInlineError(msg)
        return false
    }

    private func migrateFromLaunchd() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: store.launchAgentsURL, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix("com.pangyun.ScriptDock.") && name != "\(selfLaunchAgentLabel).plist" else { continue }
            let label = name.replacingOccurrences(of: ".plist", with: "")
            _ = ProcessRunner.run("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())/\(label)"])
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    fileprivate func updateStatusTitle() {
        let running = store.tasks.filter { isRunning($0) }.count
        statusItem?.button?.title = running > 0 ? " \(running)" : ""
    }

    private func selfLaunchAgentURL() -> URL {
        store.launchAgentsURL.appendingPathComponent("\(selfLaunchAgentLabel).plist")
    }

    private func ensureFile(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    private func ensureSelfLaunchAgent() {
        guard let executablePath = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": selfLaunchAgentLabel,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "WorkingDirectory": FileManager.default.homeDirectoryForCurrentUser.path
        ]

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            let url = selfLaunchAgentURL()
            if let existing = try? Data(contentsOf: url), existing == data {
                return
            }
            try data.write(to: url, options: .atomic)
        } catch {
            showError("Failed to enable ScriptDock auto-launch at login: \(error.localizedDescription)")
        }
    }

    // MARK: - Global Hot Key (Cmd+K)

    private func registerGlobalHotKey() {
        // Cmd+K = key code 40, cmdKey
        let keyCode: UInt32 = 40
        let modifiers: UInt32 = UInt32(cmdKey)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<ScriptDockApp>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                app.showQuickLaunch()
            }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &hotKeyEventHandler)
        guard installStatus == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: OSType(0x53434B4C), id: 1)  // 'SCKL'
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &globalHotKey)
        if registerStatus != noErr {
            // Hotkey registration failed (e.g. already taken), non-fatal
            print("ScriptDock: Cmd+K hotkey registration failed (\(registerStatus))")
        }
    }

    fileprivate func showQuickLaunch() {
        if quickLaunchPanel == nil {
            quickLaunchPanel = QuickLaunchPanel(app: self)
        }
        quickLaunchPanel?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Alerts

    private func showError(_ message: String) {
        showAlert(title: "ScriptDock Error", message: message, style: .warning)
    }

    private func showInfo(_ message: String) {
        showAlert(title: "ScriptDock", message: message, style: .informational)
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = style

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.string = message
        scrollView.documentView = textView

        // Fixed height so long messages don't push buttons off screen
        let width: CGFloat = 480
        let height: CGFloat = min(200, max(60, CGFloat(message.count) / 3))
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: width),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 200),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
        ])

        alert.accessoryView = scrollView
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

}

// MARK: - Dashboard

enum SidebarItem {
    case header(String)
    case task(ScriptTask)
    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }
    var task: ScriptTask? {
        if case .task(let t) = self { return t }
        return nil
    }
}

final class DashboardWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let app: ScriptDockApp
    private var allTasks: [ScriptTask] = []
    private var sidebarItems: [SidebarItem] = []
    private var collapsedSections: Set<String> = []
    private var cachedSupervisorStatuses: [TaskStatus] = []
    private var supervisorStatusTime: Date = .distantPast
    private var selectedTaskID: String?
    private var logStreamMode: Int = 0  // 0=combined, 1=stdout, 2=stderr
    private var refreshTimer: Timer?
    private var userScrolledUp = false
    private var currentEditor: TaskEditorWindowController?

    private let taskSearchField = NSSearchField()
    private let sidebarTable = NSTableView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeStack = NSStackView()
    private let commandLabel = NSTextField(labelWithString: "")
    private let errorBanner = NSTextField(labelWithString: "")
    private let portTextView = NSTextView()
    private let portScrollView = NSScrollView()
    private var portHeightConstraint: NSLayoutConstraint!
    private let logTextView = NSTextView()
    private let logScrollView = NSScrollView()
    private let logSearchField = NSSearchField()
    private let streamControl = NSSegmentedControl(labels: ["Combined", "stdout", "stderr"], trackingMode: .selectOne, target: nil, action: nil)
    private let liveCheckbox = NSButton(checkboxWithTitle: "Live", target: nil, action: nil)
    private let clearLogButton = NSButton(title: "Clear", target: nil, action: nil)

    private var isDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    init(app: ScriptDockApp) {
        self.app = app
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScriptDock"
        window.minSize = NSSize(width: 900, height: 580)
        super.init(window: window)
        buildInterface()
        startRefreshTimer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload() {
        allTasks = app.configuredTasks()
        rebuildSidebarItems()
        sidebarTable.reloadData()
        restoreSelection()
        updateDetail()
    }

    /// Persistent inline error — shown until task is restarted or cleared
    private var stickyError: String?

    func showInlineError(_ message: String) {
        stickyError = message
        errorBanner.stringValue = message
        errorBanner.isHidden = false
    }

    private var logFont: NSFont { NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) }

    private func setLogText(_ text: String, color: NSColor = .textColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: logFont, .foregroundColor: color]
        logTextView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    func appendSystemLog(_ message: String) {
        // Prepend system message to the current log view
        let current = logTextView.string
        let separator = current.isEmpty ? "" : "\n\n"
        let fullText = "[ScriptDock] \(message)\(separator)\(current)"
        let attrs: [NSAttributedString.Key: Any] = [.font: logFont, .foregroundColor: NSColor.secondaryLabelColor]
        logTextView.textStorage?.setAttributedString(NSAttributedString(string: fullText, attributes: attrs))
    }

    private func restoreSelection() {
        if let selectedTaskID {
            for row in 0..<sidebarItems.count {
                if sidebarItems[row].task?.id == selectedTaskID {
                    if sidebarTable.selectedRow != row {
                        sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    }
                    return
                }
            }
        }
        // Auto-select first task row (skip headers)
        for row in 0..<sidebarItems.count {
            if sidebarItems[row].task != nil {
                if sidebarTable.selectedRow != row {
                    sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                return
            }
        }
    }

    private var selectedTask: ScriptTask? {
        guard let selectedTaskID else { return nil }
        return allTasks.first { $0.id == selectedTaskID }
    }

    // MARK: - Build Interface

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }
        let splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        contentView.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let sidebar = buildSidebar()
        let detail = buildDetail()
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(detail)
        sidebar.widthAnchor.constraint(equalToConstant: 280).isActive = true
    }

    private func buildSidebar() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        taskSearchField.placeholderString = "Search tasks..."
        taskSearchField.target = self
        taskSearchField.action = #selector(taskFilterChanged)
        taskSearchField.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        sidebarTable.headerView = nil
        sidebarTable.usesAlternatingRowBackgroundColors = false
        sidebarTable.style = .sourceList
        sidebarTable.rowHeight = 28
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        sidebarTable.target = self
        sidebarTable.doubleAction = #selector(toggleSelectedTask)
        sidebarTable.action = #selector(sidebarClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = 260
        sidebarTable.addTableColumn(column)
        scrollView.documentView = sidebarTable

        let reloadButton = sidebarUtilButton(title: "Reload", icon: "arrow.clockwise", action: #selector(reloadConfig))
        let configButton = sidebarUtilButton(title: "Config", icon: "gearshape", action: #selector(openConfig))
        let logsButton = sidebarUtilButton(title: "Logs", icon: "folder", action: #selector(openLogs))

        let addButton = NSButton(title: "+ Add Task", target: self, action: #selector(addTask))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small

        let addRow = NSStackView(views: [addButton])
        addRow.orientation = .horizontal

        let utilRow = NSStackView(views: [reloadButton, configButton, logsButton])
        utilRow.orientation = .horizontal
        utilRow.distribution = .fillEqually
        utilRow.spacing = 8

        let bottomStack = NSStackView(views: [addRow, utilRow])
        bottomStack.orientation = .vertical
        bottomStack.spacing = 4
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(taskSearchField)
        view.addSubview(scrollView)
        view.addSubview(bottomStack)
        NSLayoutConstraint.activate([
            taskSearchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            taskSearchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            taskSearchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: taskSearchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -8),
            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bottomStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
        return view
    }

    private func buildDetail() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        // Title
        titleLabel.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isSelectable = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Badge bar (status + pid + ports as badge labels)
        badgeStack.orientation = .horizontal
        badgeStack.spacing = 6
        badgeStack.alignment = .centerY
        badgeStack.translatesAutoresizingMaskIntoConstraints = false

        // Command
        commandLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        commandLabel.textColor = NSColor(calibratedWhite: 0.15, alpha: 1.0)
        commandLabel.isSelectable = true
        commandLabel.maximumNumberOfLines = 1
        commandLabel.lineBreakMode = .byTruncatingMiddle
        commandLabel.translatesAutoresizingMaskIntoConstraints = false

        // Error banner (shown when task has error info)
        errorBanner.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        errorBanner.textColor = NSColor.systemRed
        errorBanner.lineBreakMode = .byTruncatingTail
        errorBanner.translatesAutoresizingMaskIntoConstraints = false
        errorBanner.isHidden = true
        errorBanner.wantsLayer = true
        errorBanner.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
        errorBanner.layer?.cornerRadius = 4
        errorBanner.drawsBackground = true

        // Action bar: Start Stop Restart Edit ⋯
        let startButton = actionButton("▶ Start", action: #selector(startSelected), primary: true)
        let stopButton = actionButton("Stop", action: #selector(stopSelected))
        let restartButton = actionButton("Restart", action: #selector(restartSelected))
        let editButton = actionButton("Edit", action: #selector(editSelected))
        let moreButton = actionButton("⋯", action: #selector(showMoreMenu))
        let actionBar = NSStackView(views: [startButton, stopButton, restartButton, editButton, moreButton])
        actionBar.orientation = .horizontal
        actionBar.spacing = 6
        actionBar.translatesAutoresizingMaskIntoConstraints = false

        // Port scroll view (conditionally shown)
        portScrollView.hasVerticalScroller = true
        portScrollView.hasHorizontalScroller = false
        portScrollView.borderType = .noBorder
        portScrollView.drawsBackground = false
        portScrollView.translatesAutoresizingMaskIntoConstraints = false
        portTextView.isEditable = false
        portTextView.isSelectable = true
        portTextView.isRichText = false
        portTextView.drawsBackground = false
        portTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        portTextView.textContainerInset = NSSize(width: 4, height: 4)
        portTextView.textContainer?.widthTracksTextView = true
        portTextView.isHorizontallyResizable = false
        portTextView.isVerticallyResizable = true
        portScrollView.documentView = portTextView
        portHeightConstraint = portScrollView.heightAnchor.constraint(equalToConstant: 0)
        portHeightConstraint.isActive = true
        portScrollView.isHidden = true

        // Log toolbar
        streamControl.selectedSegment = 0
        streamControl.target = self
        streamControl.action = #selector(streamChanged)
        streamControl.translatesAutoresizingMaskIntoConstraints = false
        streamControl.segmentStyle = .rounded
        streamControl.controlSize = .small

        logSearchField.placeholderString = "Search logs"
        logSearchField.target = self
        logSearchField.action = #selector(logSearchChanged)
        logSearchField.translatesAutoresizingMaskIntoConstraints = false

        liveCheckbox.state = .on
        liveCheckbox.target = self
        liveCheckbox.action = #selector(liveToggled)
        liveCheckbox.translatesAutoresizingMaskIntoConstraints = false

        clearLogButton.bezelStyle = .recessed
        clearLogButton.controlSize = .small
        clearLogButton.target = self
        clearLogButton.action = #selector(clearLogView)
        clearLogButton.translatesAutoresizingMaskIntoConstraints = false

        let logToolbar = NSStackView(views: [streamControl, logSearchField, liveCheckbox, clearLogButton])
        logToolbar.orientation = .horizontal
        logToolbar.spacing = 8
        logToolbar.translatesAutoresizingMaskIntoConstraints = false

        // Log scroll view — dark theme
        logScrollView.hasVerticalScroller = true
        logScrollView.hasHorizontalScroller = false
        logScrollView.borderType = .noBorder
        logScrollView.autohidesScrollers = true
        logScrollView.wantsLayer = true
        logScrollView.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1.0).cgColor
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.isRichText = true
        logTextView.drawsBackground = false
        logTextView.textColor = NSColor(calibratedWhite: 0.2, alpha: 1.0)
        logTextView.insertionPointColor = NSColor(calibratedWhite: 0.2, alpha: 1.0)
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        logTextView.textContainerInset = NSSize(width: 12, height: 10)
        logTextView.textContainer?.widthTracksTextView = true
        logTextView.isHorizontallyResizable = false
        logTextView.isVerticallyResizable = true
        logScrollView.documentView = logTextView
        logScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(logScrollViewBoundsChanged), name: NSView.boundsDidChangeNotification, object: logScrollView.contentView)

        // Layout
        view.addSubview(titleLabel)
        view.addSubview(badgeStack)
        view.addSubview(commandLabel)
        view.addSubview(errorBanner)
        view.addSubview(actionBar)
        view.addSubview(portScrollView)
        view.addSubview(logToolbar)
        view.addSubview(logScrollView)

        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            badgeStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            badgeStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            commandLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            commandLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            commandLabel.topAnchor.constraint(equalTo: badgeStack.bottomAnchor, constant: 4),
            errorBanner.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: -6),
            errorBanner.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            errorBanner.topAnchor.constraint(equalTo: commandLabel.bottomAnchor, constant: 4),
            errorBanner.heightAnchor.constraint(equalToConstant: 24),
            actionBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            actionBar.topAnchor.constraint(equalTo: errorBanner.bottomAnchor, constant: 6),
            portScrollView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            portScrollView.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            portScrollView.topAnchor.constraint(equalTo: actionBar.bottomAnchor, constant: 6),
            logToolbar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            logToolbar.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            logToolbar.topAnchor.constraint(equalTo: portScrollView.bottomAnchor, constant: 8),
            logSearchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            logScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            logScrollView.topAnchor.constraint(equalTo: logToolbar.bottomAnchor, constant: 6),
            logScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        ])
        return view
    }

    // MARK: - UI Helpers

    private func actionButton(_ title: String, action: Selector, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        if primary {
            button.bezelStyle = .recessed
            button.controlSize = .regular
            button.keyEquivalent = "\r"
        } else {
            button.bezelStyle = .recessed
            button.controlSize = .small
        }
        return button
    }

    private func badgeLabel(_ text: String, color: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = color
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        container.layer?.cornerRadius = 4
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3)
        ])
        return container
    }

    @objc private func showMoreMenu() {
        guard let task = selectedTask else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Delete Task", action: #selector(deleteSelected), keyEquivalent: ""))
        if task.openURL != nil {
            menu.addItem(NSMenuItem(title: "Open URL", action: #selector(openSelectedURL), keyEquivalent: ""))
        }
        let ports = app.inferredPorts(for: task)
        if !ports.isEmpty {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Check Ports", action: #selector(checkSelectedPorts), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Kill Blockers", action: #selector(killSelectedBlockers), keyEquivalent: ""))
        }
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: (window?.contentView)!)
        }
    }

    private var mcpSnippetTexts: [Int: String] = [:]

    @objc func showMCPInfo() {
        let mcpPath = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("scriptdock-mcp").path ?? "scriptdock-mcp"
        NSApp.activate(ignoringOtherApps: true)

        let claudeCmd = "claude mcp add scriptdock -- \(mcpPath)"
        let cursorCmd = mcpPath
        let httpCmd = "\(mcpPath) --transport http --port 26215"

        mcpSnippetTexts = [0: claudeCmd, 1: cursorCmd, 2: httpCmd]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 260))

        let card1 = snippetCard(label: "Claude Code", code: claudeCmd, tag: 0, in: NSRect(x: 0, y: 180, width: 540, height: 72))
        let card2 = snippetCard(label: "Cursor / MCP (stdio)", code: cursorCmd, tag: 1, in: NSRect(x: 0, y: 96, width: 540, height: 72))
        let card3 = snippetCard(label: "HTTP / SSE", code: httpCmd, tag: 2, in: NSRect(x: 0, y: 8, width: 540, height: 72))
        container.addSubview(card1)
        container.addSubview(card2)
        container.addSubview(card3)

        let alert = NSAlert()
        alert.messageText = "ScriptDock MCP Server"
        alert.alertStyle = .informational
        alert.informativeText = ""
        alert.accessoryView = container
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    private func snippetCard(label: String, code: String, tag: Int, in frame: NSRect) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.96, alpha: 1.0).cgColor
        card.layer?.cornerRadius = 6

        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        labelField.textColor = .secondaryLabelColor
        labelField.frame = NSRect(x: 10, y: frame.height - 18, width: 400, height: 14)

        // Code area with horizontal scroll
        let codeAreaY: CGFloat = 4
        let codeAreaHeight = frame.height - 26
        let codeArea = NSView(frame: NSRect(x: 0, y: codeAreaY, width: frame.width, height: codeAreaHeight))
        codeArea.wantsLayer = true
        codeArea.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor
        codeArea.layer?.cornerRadius = 4

        let codeField = NSTextField(labelWithString: code)
        codeField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        codeField.textColor = NSColor(white: 0.85, alpha: 1.0)
        codeField.lineBreakMode = .byClipping
        codeField.sizeToFit()
        let codeWidth = max(codeField.frame.width + 20, frame.width - 16)

        let codeScrollView = NSScrollView(frame: NSRect(x: 6, y: 4, width: frame.width - 44, height: codeAreaHeight - 8))
        let codeClipView = NSClipView()
        codeClipView.documentView = codeField
        codeField.frame = NSRect(x: 0, y: 0, width: codeWidth, height: codeAreaHeight - 8)
        codeScrollView.contentView = codeClipView
        codeScrollView.hasHorizontalScroller = true
        codeScrollView.hasVerticalScroller = false
        codeScrollView.autohidesScrollers = true
        codeScrollView.drawsBackground = false
        codeScrollView.borderType = .noBorder

        // Copy icon button inside code block
        let copyBtn = NSButton(frame: NSRect(x: frame.width - 32, y: 6, width: 22, height: 22))
        copyBtn.bezelStyle = .inline
        copyBtn.isBordered = false
        copyBtn.tag = tag
        copyBtn.target = self
        copyBtn.action = #selector(mcpCopySnippet(_:))
        let copyIcon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyBtn.image = copyIcon
        copyBtn.imagePosition = .imageOnly
        copyBtn.contentTintColor = NSColor(white: 0.6, alpha: 1.0)

        codeArea.addSubview(codeScrollView)
        codeArea.addSubview(copyBtn)
        card.addSubview(labelField)
        card.addSubview(codeArea)
        return card
    }

    @objc private func mcpCopySnippet(_ sender: NSButton) {
        guard let text = mcpSnippetTexts[sender.tag] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let checkIcon = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        sender.image = checkIcon
        sender.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let copyIcon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            sender.image = copyIcon
            sender.contentTintColor = NSColor(white: 0.6, alpha: 1.0)
        }
    }

    private func ghostButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
        return button
    }

    private func sidebarUtilButton(title: String, icon: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .recessed
        btn.controlSize = .small
        btn.imagePosition = .imageLeft
        btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        btn.font = NSFont.systemFont(ofSize: 11)
        return btn
    }

    // MARK: - Sidebar Data

    private func rebuildSidebarItems() {
        let query = taskSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let all = query.isEmpty ? allTasks : allTasks.filter { task in
            task.name.lowercased().contains(query)
                || task.id.lowercased().contains(query)
                || task.programArguments.joined(separator: " ").lowercased().contains(query)
        }

        // Use cached supervisor statuses (refreshed asynchronously in the background)
        let supervisorStatuses = cachedSupervisorStatuses

        let running = all.filter { app.isRunning($0) && app.taskError(for: $0) == nil }
        let stopped = all.filter { !app.isRunning($0) && app.taskError(for: $0) == nil }
        let broken = all.filter { app.taskError(for: $0) != nil }

        // Split running into AI (started via MCP) and manual
        let aiRunning = running.filter { task in
            supervisorStatuses.first(where: { $0.id == task.id })?.startedBy == "mcp"
        }
        let manualRunning = running.filter { task in
            supervisorStatuses.first(where: { $0.id == task.id })?.startedBy != "mcp"
        }

        var items: [SidebarItem] = []

        if !manualRunning.isEmpty {
            let headerTitle = "Running (\(manualRunning.count))"
            items.append(.header(headerTitle))
            if !collapsedSections.contains(headerTitle) {
                items.append(contentsOf: manualRunning.map { .task($0) })
            }
        }

        if !aiRunning.isEmpty {
            let headerTitle = "AI Processes (\(aiRunning.count))"
            items.append(.header(headerTitle))
            if !collapsedSections.contains(headerTitle) {
                items.append(contentsOf: aiRunning.map { .task($0) })
            }
        }

        if !stopped.isEmpty {
            let headerTitle = "Stopped (\(stopped.count))"
            items.append(.header(headerTitle))
            if !collapsedSections.contains(headerTitle) {
                items.append(contentsOf: stopped.map { .task($0) })
            }
        }

        if !broken.isEmpty {
            let headerTitle = "Errors (\(broken.count))"
            items.append(.header(headerTitle))
            if !collapsedSections.contains(headerTitle) {
                items.append(contentsOf: broken.map { .task($0) })
            }
        }

        sidebarItems = items
    }

    private func refreshSupervisorStatuses() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let statuses = SupervisorClient.shared.allStatuses() ?? []
            DispatchQueue.main.async {
                self?.cachedSupervisorStatuses = statuses
                self?.supervisorStatusTime = Date()
            }
        }
    }

    // MARK: - Refresh

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.refreshSupervisorStatuses()
            let oldItems = self.sidebarItems
            self.rebuildSidebarItems()
            let newItems = self.sidebarItems

            // Only full reload if structure changed; otherwise update cells in place
            let structureChanged = oldItems.count != newItems.count || !zip(oldItems, newItems).allSatisfy { a, b in
                switch (a, b) {
                case (.header(let h1), .header(let h2)): return h1 == h2
                case (.task(let t1), .task(let t2)): return t1.id == t2.id
                default: return false
                }
            }

            if structureChanged {
                self.sidebarTable.reloadData()
                self.restoreSelection()
            } else {
                // Update visible task cells in place (status may have changed)
                let visibleRange = self.sidebarTable.rows(in: self.sidebarTable.visibleRect)
                for row in visibleRange.location..<(visibleRange.location + visibleRange.length) where row < newItems.count {
                    if case .task = newItems[row] {
                        if let cell = self.sidebarTable.view(atColumn: 0, row: row, makeIfNecessary: false) {
                            self.updateTaskCell(cell, at: row)
                        }
                    }
                }
            }
            self.updateDetail(refreshLogsOnly: self.liveCheckbox.state == .on)
            self.app.updateStatusTitle()
        }
    }

    private func updateTaskCell(_ cell: NSView, at row: Int) {
        guard row < sidebarItems.count, case .task(let task) = sidebarItems[row] else { return }
        let running = app.isRunning(task)
        let error = app.taskError(for: task)

        guard let toggleBtn = cell.viewWithTag(100) as? NSButton,
              let nameField = cell.viewWithTag(101) as? NSTextField,
              let restartBtn = cell.viewWithTag(102) as? NSButton else { return }

        if let error {
            // Broken task: red indicator, no toggle
            toggleBtn.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
            toggleBtn.contentTintColor = .systemRed
            toggleBtn.toolTip = error.components(separatedBy: "\n").first ?? error
            nameField.stringValue = "⚠ \(task.name)"
            nameField.textColor = .systemRed
            restartBtn.isHidden = true
        } else {
            let toggleIcon = running
                ? NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
                : NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Start")
            toggleBtn.image = toggleIcon
            toggleBtn.contentTintColor = running ? .systemOrange : .systemGreen
            toggleBtn.toolTip = running ? "Stop \(task.name)" : "Start \(task.name)"
            nameField.stringValue = "\(running ? "● " : "○ ")\(task.name)"
            nameField.textColor = running ? .textColor : .secondaryLabelColor
            restartBtn.isHidden = !running
        }
    }

    // MARK: - Detail

    private func updateDetail(refreshLogsOnly: Bool = false) {
        guard let task = selectedTask else {
            titleLabel.stringValue = "No task selected"
            commandLabel.stringValue = ""
            portTextView.string = ""
            setLogText("")
            badgeStack.arrangedSubviews.forEach { badgeStack.removeView($0) }
            return
        }
        if !refreshLogsOnly {
            titleLabel.stringValue = task.name
            let running = app.isRunning(task)
            let taskPid = app.pid(for: task)
            let ports = app.inferredPorts(for: task)
            let configError = app.taskError(for: task)

            // Build badge bar
            badgeStack.arrangedSubviews.forEach { badgeStack.removeView($0) }
            if configError != nil {
                // Broken task: show error badge
                badgeStack.addArrangedSubview(badgeLabel("⚠ Config Error", color: .systemRed))
            } else {
                let statusBadge = badgeLabel(
                    running ? "● Running" : "○ Stopped",
                    color: running ? NSColor.systemGreen : NSColor.tertiaryLabelColor
                )
                badgeStack.addArrangedSubview(statusBadge)
                if let taskPid {
                    badgeStack.addArrangedSubview(badgeLabel("pid \(taskPid)", color: .secondaryLabelColor))
                }
                for port in ports {
                    badgeStack.addArrangedSubview(badgeLabel(":\(port)", color: .secondaryLabelColor))
                }
            }

            commandLabel.stringValue = task.programArguments.joined(separator: " ")
            commandLabel.textColor = NSColor(calibratedWhite: 0.2, alpha: 1.0)

            // Error banner: sticky error > config error > runtime error
            // Clear sticky error when task is running
            if running {
                stickyError = nil
            }
            if let stickyError {
                errorBanner.stringValue = stickyError
                errorBanner.isHidden = false
            } else if let configError {
                errorBanner.stringValue = configError.components(separatedBy: "\n").first ?? configError
                errorBanner.isHidden = false
            } else if !running {
                let status = app.supervisor.taskStatus(id: task.id)
                if let status {
                    if let exitCode = status.exitCode, exitCode != 0 {
                        var msg = "Exit code: \(exitCode)"
                        if let err = status.lastError, !err.isEmpty { msg += " — \(err)" }
                        errorBanner.stringValue = msg
                        errorBanner.isHidden = false
                    } else if status.state == .errored {
                        errorBanner.stringValue = status.lastError ?? "Process exited with error"
                        errorBanner.isHidden = false
                    } else {
                        errorBanner.isHidden = true
                    }
                } else {
                    errorBanner.isHidden = true
                }
            } else {
                errorBanner.isHidden = true
            }

            // Port section: show only when task has ports and no config error
            let hasPorts = !ports.isEmpty && configError == nil
            portScrollView.isHidden = !hasPorts
            portHeightConstraint.constant = hasPorts ? 60 : 0
            if hasPorts {
                portTextView.string = app.portReport(for: task)
            }
        }
        updateLogText(for: task)

        // For broken tasks, show the full config error in the log area
        if let configError = app.taskError(for: task) {
            setLogText("[Config Error]\n\n\(configError)", color: .systemRed)
        }
    }

    private func updateLogText(for task: ScriptTask) {
        let stdoutText = app.logText(for: task, stream: .stdout)
        let stderrText = app.logText(for: task, stream: .stderr)

        switch logStreamMode {
        case 1:  // stdout only
            applyLogText(stdoutText, colorize: false)
        case 2:  // stderr only
            applyLogText(stderrText, colorize: false)
        default:  // combined (0) — colorize to distinguish streams
            applyCombinedLog(stdout: stdoutText, stderr: stderrText)
        }
    }

    private func applyLogText(_ text: String, colorize: Bool) {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let query = logSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let displayText: String
        if query.isEmpty {
            displayText = text.isEmpty ? "(empty)" : text
        } else {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let matches = lines.filter { $0.localizedCaseInsensitiveContains(query) }
            displayText = matches.isEmpty ? "(no matches)" : matches.joined(separator: "\n")
        }

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        logTextView.textStorage?.setAttributedString(NSAttributedString(string: displayText, attributes: attrs))
        autoScrollLog()
    }

    private func applyCombinedLog(stdout: String, stderr: String) {
        let stdoutColor = NSColor.textColor
        let stderrColor = NSColor.systemOrange
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()

        if stdout.isEmpty && stderr.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
            result.append(NSAttributedString(string: "(empty)", attributes: attrs))
        } else {
            // Interleave stdout and stderr lines by timestamp
            struct TaggedLine {
                let time: Int          // seconds since midnight; -1 for untagged lines
                let text: String
                let isStderr: Bool
            }
            var tagged: [TaggedLine] = []

            let streams: [(text: String, isStderr: Bool)] = [(stdout, false), (stderr, true)]
            for (text, isStderr) in streams {
                var lines = text.components(separatedBy: "\n")
                // Drop trailing empty string from split
                if let last = lines.last, last.isEmpty { lines.removeLast() }
                for line in lines {
                    var time = -1
                    // Parse [HH:MM:SS] prefix
                    if let bracket = line.firstIndex(of: "]"),
                       line.hasPrefix("[") {
                        let ts = String(line[line.index(after: line.startIndex)..<bracket])
                        let parts = ts.split(separator: ":")
                        if parts.count == 3,
                           let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]) {
                            time = h * 3600 + m * 60 + s
                        }
                    }
                    tagged.append(TaggedLine(time: time, text: line, isStderr: isStderr))
                }
            }
            tagged.sort { $0.time < $1.time }

            for entry in tagged {
                let color = entry.isStderr ? stderrColor : stdoutColor
                let attrLine = NSAttributedString(
                    string: entry.text + "\n",
                    attributes: [.font: font, .foregroundColor: color]
                )
                result.append(attrLine)
            }
        }

        let query = logSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let fullText = result.string
            let lines = fullText.split(separator: "\n", omittingEmptySubsequences: false)
            let matches = lines.filter { $0.localizedCaseInsensitiveContains(query) }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            logTextView.textStorage?.setAttributedString(
                matches.isEmpty
                    ? NSAttributedString(string: "(no matches)", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
                    : NSAttributedString(string: matches.joined(separator: "\n"), attributes: attrs)
            )
        } else {
            logTextView.textStorage?.setAttributedString(result)
        }
        autoScrollLog()
    }

    private func autoScrollLog() {
        guard liveCheckbox.state == .on, !userScrolledUp else { return }
        logTextView.scrollRangeToVisible(NSRange(location: logTextView.string.count, length: 0))
    }

    @objc private func logScrollViewBoundsChanged() {
        let clipView = logScrollView.contentView
        let docHeight = logTextView.frame.height
        let visibleHeight = clipView.bounds.height
        let bottomEdge = clipView.bounds.origin.y + visibleHeight
        userScrolledUp = (docHeight - bottomEdge) > 40
    }

    // MARK: - TableView DataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        sidebarItems.count
    }

    // MARK: - TableView Delegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < sidebarItems.count else { return nil }
        let item = sidebarItems[row]

        switch item {
        case .header(let title):
            let cellID = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = cellID
            if cell.textField == nil {
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
                tf.textColor = .secondaryLabelColor
                cell.addSubview(tf)
                cell.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            let arrow = collapsedSections.contains(title) ? "▸ " : "▾ "
            cell.textField?.stringValue = arrow + title
            return cell

        case .task(let task):
            let cellID = NSUserInterfaceItemIdentifier("TaskCell")
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = cellID

            let running = app.isRunning(task)
            let rowHeight: CGFloat = 28
            let cellWidth: CGFloat = 260
            let btnSize: CGFloat = 16
            let btnY = (rowHeight - btnSize) / 2

            let toggleBtn: NSButton
            let nameField: NSTextField
            let restartBtn: NSButton

            if cell.viewWithTag(100) == nil {
                // First time: create subviews with tags
                toggleBtn = NSButton(frame: NSRect(x: 2, y: btnY, width: btnSize, height: btnSize))
                toggleBtn.tag = 100
                toggleBtn.bezelStyle = .inline
                toggleBtn.isBordered = false
                toggleBtn.imagePosition = .imageOnly
                toggleBtn.target = self
                toggleBtn.action = #selector(sidebarToggleTask(_:))

                nameField = NSTextField(labelWithString: "")
                nameField.tag = 101
                nameField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
                nameField.lineBreakMode = .byTruncatingTail
                nameField.sizeToFit()
                let nameY = (rowHeight - nameField.frame.height) / 2
                nameField.frame = NSRect(x: 20, y: nameY, width: cellWidth - 44, height: nameField.frame.height)

                restartBtn = NSButton(frame: NSRect(x: cellWidth - 38, y: btnY, width: btnSize, height: btnSize))
                restartBtn.tag = 102
                restartBtn.bezelStyle = .inline
                restartBtn.isBordered = false
                restartBtn.imagePosition = .imageOnly
                restartBtn.target = self
                restartBtn.action = #selector(sidebarRestartTask(_:))

                cell.addSubview(toggleBtn)
                cell.addSubview(nameField)
                cell.addSubview(restartBtn)
                cell.textField = nameField
            } else {
                // Reuse: find existing subviews
                toggleBtn = cell.viewWithTag(100) as! NSButton
                nameField = cell.viewWithTag(101) as! NSTextField
                restartBtn = cell.viewWithTag(102) as! NSButton
            }

            // Update dynamic content only
            let toggleIcon = running
                ? NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
                : NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Start")
            toggleBtn.image = toggleIcon
            toggleBtn.contentTintColor = running ? .systemOrange : .systemGreen
            toggleBtn.toolTip = running ? "Stop \(task.name)" : "Start \(task.name)"

            nameField.stringValue = "\(running ? "● " : "○ ")\(task.name)"
            nameField.textColor = running ? .textColor : .secondaryLabelColor

            restartBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Restart")
            restartBtn.contentTintColor = .secondaryLabelColor
            restartBtn.toolTip = "Restart \(task.name)"
            restartBtn.isHidden = !running

            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < sidebarItems.count else { return false }
        return !sidebarItems[row].isHeader
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < sidebarItems.count else { return 28 }
        return sidebarItems[row].isHeader ? 22 : 28
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard row < sidebarItems.count, sidebarItems[row].isHeader else { return nil }
        let rowView = NSTableRowView()
        rowView.isGroupRowStyle = true
        return rowView
    }

    @objc private func sidebarClicked() {
        let row = sidebarTable.clickedRow
        guard row >= 0, row < sidebarItems.count, case .header(let title) = sidebarItems[row] else { return }
        if collapsedSections.contains(title) {
            collapsedSections.remove(title)
        } else {
            collapsedSections.insert(title)
        }
        rebuildSidebarItems()
        sidebarTable.reloadData()
        restoreSelection()
    }

    private func rowForViewInSidebar(_ view: NSView) -> Int {
        var current: NSView? = view
        while let v = current {
            let row = sidebarTable.row(for: v)
            if row >= 0 { return row }
            current = v.superview
        }
        return -1
    }

    @objc private func sidebarToggleTask(_ sender: NSButton) {
        let row = rowForViewInSidebar(sender)
        guard row >= 0, row < sidebarItems.count, let task = sidebarItems[row].task else { return }
        if app.isRunning(task) {
            app.stop(task)
        } else {
            app.start(task)
        }
        rebuildSidebarItems()
        sidebarTable.reloadData()
        restoreSelection()
        updateDetail()
    }

    @objc private func sidebarRestartTask(_ sender: NSButton) {
        let row = rowForViewInSidebar(sender)
        guard row >= 0, row < sidebarItems.count, let task = sidebarItems[row].task else { return }
        app.restart(task)
        rebuildSidebarItems()
        sidebarTable.reloadData()
        restoreSelection()
        updateDetail()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarTable.selectedRow
        guard row >= 0, row < sidebarItems.count, let task = sidebarItems[row].task else { return }
        selectedTaskID = task.id
        stickyError = nil
        userScrolledUp = false
        updateDetail()
    }

    // MARK: - Actions

    @objc private func taskFilterChanged() {
        rebuildSidebarItems()
        sidebarTable.reloadData()
        // Auto-select first task row
        for row in 0..<sidebarItems.count {
            if let task = sidebarItems[row].task {
                selectedTaskID = task.id
                sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                break
            }
        }
        updateDetail()
    }

    @objc private func logSearchChanged() {
        userScrolledUp = false
        updateDetail(refreshLogsOnly: true)
    }

    @objc private func streamChanged() {
        logStreamMode = streamControl.selectedSegment
        userScrolledUp = false
        updateDetail(refreshLogsOnly: true)
    }

    @objc private func liveToggled() {
        if liveCheckbox.state == .on {
            userScrolledUp = false
        }
    }

    @objc private func clearLogView() {
        guard let task = selectedTask else { return }
        let store = app.store
        // Clear on-disk log files
        try? Data().write(to: store.stdoutURL(for: task))
        try? Data().write(to: store.stderrURL(for: task))
        // Clear in-memory ring buffers
        app.supervisor.clearLogs(id: task.id)
        setLogText("")
    }

    @objc private func reloadConfig() {
        app.reloadConfiguration(showAlert: true)
    }

    @objc private func openConfig() {
        app.openConfigFile()
    }

    @objc private func openLogs() {
        app.openLogsDirectory()
    }

    @objc private func startSelected() {
        guard let task = selectedTask else { return }
        if let optionals = task.optionalArguments, !optionals.isEmpty {
            showArgumentPicker(for: task)
        } else {
            app.start(task)
            reload()
        }
    }

    private func showArgumentPicker(for task: ScriptTask) {
        guard let optionals = task.optionalArguments else { return }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Start \(task.name)"
        panel.isReleasedWhenClosed = false

        guard let contentView = panel.contentView else { return }
        let pad: CGFloat = 20
        var yOffset: CGFloat = pad

        // Checkboxes for each optional argument
        var checkboxes: [(NSButton, OptionalArgument)] = []
        for opt in optionals {
            let check = NSButton(checkboxWithTitle: "\(opt.label) (\(opt.argument))", target: nil, action: nil)
            check.translatesAutoresizingMaskIntoConstraints = false
            if opt.requiresValue, let defVal = opt.defaultValue {
                check.title = "\(opt.label) (\(opt.argument)\(defVal))"
            }
            contentView.addSubview(check)
            check.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad).isActive = true
            check.topAnchor.constraint(equalTo: contentView.topAnchor, constant: yOffset).isActive = true
            checkboxes.append((check, opt))
            yOffset += 28
        }

        // Free input field
        let inputLabel = NSTextField(labelWithString: "Additional arguments:")
        inputLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(inputLabel)
        inputLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad).isActive = true
        inputLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: yOffset).isActive = true
        yOffset += 20

        let inputField = NSTextField()
        inputField.placeholderString = "e.g. --extra-flag value"
        inputField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(inputField)
        inputField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad).isActive = true
        inputField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad).isActive = true
        inputField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: yOffset).isActive = true
        yOffset += 40

        // Buttons
        let startBtn = NSButton(title: "Start", target: nil, action: nil)
        startBtn.bezelStyle = .rounded
        startBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        let btnStack = NSStackView(views: [cancelBtn, startBtn])
        btnStack.orientation = .horizontal
        btnStack.spacing = 12
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(btnStack)
        btnStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad).isActive = true
        btnStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: yOffset).isActive = true

        startBtn.onAction = { [weak self] _ in
            var extraArgs: [String] = []
            for (check, opt) in checkboxes {
                if check.state == .on {
                    extraArgs.append(opt.argument)
                    if opt.requiresValue, let val = opt.defaultValue, !val.isEmpty {
                        extraArgs.append(val)
                    }
                }
            }
            let freeInput = inputField.stringValue.trimmingCharacters(in: .whitespaces)
            if !freeInput.isEmpty {
                // Simple space split for free input (no quote handling needed for extra args)
                extraArgs.append(contentsOf: freeInput.split(separator: " ").map(String.init))
            }
            panel.close()
            self?.app.start(task, extraArgs: extraArgs.isEmpty ? nil : extraArgs)
            self?.reload()
        }

        cancelBtn.onAction = { _ in panel.close() }

        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func stopSelected() {
        guard let task = selectedTask else { return }
        app.stop(task)
        reload()
    }

    @objc private func restartSelected() {
        guard let task = selectedTask else { return }
        app.restart(task)
        reload()
    }

    @objc private func toggleSelectedTask() {
        let row = sidebarTable.clickedRow
        guard row >= 0, row < sidebarItems.count, let task = sidebarItems[row].task else { return }
        app.isRunning(task) ? app.stop(task) : app.start(task)
        reload()
    }

    @objc private func checkSelectedPorts() {
        guard let task = selectedTask else { return }
        portTextView.string = app.portReport(for: task)
    }

    @objc private func killSelectedBlockers() {
        guard let task = selectedTask else { return }
        _ = app.killBlockers(for: task, showResult: true, askFirst: true)
        updateDetail()
    }

    @objc private func openSelectedURL() {
        guard let task = selectedTask else { return }
        app.openURL(for: task)
    }

    @objc private func revealSelected() {
        guard let task = selectedTask else { return }
        app.revealExecutable(for: task)
    }

    @objc private func addTask() {
        currentEditor = TaskEditorWindowController(store: app.store, task: nil)
        currentEditor?.onSave = { [weak self] in
            self?.app.reloadConfiguration(showAlert: false)
            self?.reload()
        }
        NSApp.activate(ignoringOtherApps: true)
        currentEditor?.window?.center()
        currentEditor?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func editSelected() {
        guard let task = selectedTask else { return }
        editTask(task)
    }

    func editTask(_ task: ScriptTask) {
        currentEditor = TaskEditorWindowController(store: app.store, task: task)
        currentEditor?.onSave = { [weak self] in
            self?.app.reloadConfiguration(showAlert: false)
            self?.reload()
        }
        NSApp.activate(ignoringOtherApps: true)
        currentEditor?.window?.center()
        currentEditor?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func deleteSelected() {
        guard let task = selectedTask else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(task.name)?"
        alert.informativeText = "This will remove the task from your configuration."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        app.store.removeTask(id: task.id)
        selectedTaskID = nil
        app.reloadConfiguration(showAlert: false)
        reload()
    }
}

// MARK: - Quick Launch Panel

final class QuickLaunchPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private unowned let app: ScriptDockApp
    private var tasks: [ScriptTask] = []
    private var filteredTasks: [ScriptTask] = []

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    init(app: ScriptDockApp) {
        self.app = app
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quick Launch"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = true
        super.init(window: window)
        buildInterface()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        tasks = app.configuredTasks()
        applyFilter()
        tableView.reloadData()
        searchField.stringValue = ""
        showWindow(nil)
        window?.makeFirstResponder(searchField)
        if !filteredTasks.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        searchField.placeholderString = "Search tasks..."
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(executeSelected)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 32
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(executeSelected)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
        column.width = 460
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filteredTasks = tasks
            return
        }
        filteredTasks = tasks.filter { task in
            task.name.lowercased().contains(query)
                || task.id.lowercased().contains(query)
                || task.programArguments.joined(separator: " ").lowercased().contains(query)
                || (task.workingDirectory ?? "").lowercased().contains(query)
        }
    }

    // MARK: - TableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredTasks.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredTasks.count else { return nil }
        let task = filteredTasks[row]
        let identifier = NSUserInterfaceItemIdentifier("QLCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        if cell.textField == nil {
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            cell.addSubview(tf)
            cell.textField = tf

            let detail = NSTextField(labelWithString: "")
            detail.translatesAutoresizingMaskIntoConstraints = false
            detail.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            detail.textColor = .tertiaryLabelColor
            detail.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(detail)
            cell.textField = tf

            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                tf.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                detail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                detail.topAnchor.constraint(equalTo: tf.bottomAnchor, constant: 2)
            ])
        }

        let running = app.isRunning(task)
        cell.textField?.stringValue = "\(running ? "● " : "○ ")\(task.name)"
        cell.textField?.textColor = running ? .labelColor : .secondaryLabelColor

        // Set detail label
        for subview in cell.subviews {
            if let detail = subview as? NSTextField, detail !== cell.textField {
                detail.stringValue = task.programArguments.joined(separator: " ")
            }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Just track selection
    }

    // MARK: - Actions

    @objc private func executeSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredTasks.count else { return }
        let task = filteredTasks[row]
        let running = app.isRunning(task)

        if running {
            // Show action menu for running tasks
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Stop", action: #selector(stopFromQL), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Restart", action: #selector(restartFromQL), keyEquivalent: ""))
            if task.openURL != nil {
                menu.addItem(NSMenuItem(title: "Open URL", action: #selector(openURLFromQL), keyEquivalent: ""))
            }
            menu.addItem(NSMenuItem(title: "Open Logs", action: #selector(openLogsFromQL), keyEquivalent: ""))
            for item in menu.items {
                item.target = self
                item.representedObject = task.id
            }
            let rowRect = tableView.rect(ofRow: row)
            let menuPoint = NSPoint(x: rowRect.midX, y: rowRect.midY)
            close()
            menu.popUp(positioning: nil, at: menuPoint, in: tableView)
        } else {
            close()
            app.start(task)
        }
    }

    @objc private func stopFromQL(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let task = app.configuredTasks().first(where: { $0.id == id }) else { return }
        app.stop(task)
    }

    @objc private func restartFromQL(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let task = app.configuredTasks().first(where: { $0.id == id }) else { return }
        app.restart(task)
    }

    @objc private func openURLFromQL(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let task = app.configuredTasks().first(where: { $0.id == id }) else { return }
        app.openURL(for: task)
    }

    @objc private func openLogsFromQL(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              app.configuredTasks().contains(where: { $0.id == id }) else { return }
        app.openLogsDirectory()
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
        tableView.reloadData()
        if !filteredTasks.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            let current = tableView.selectedRow
            let next = min(current + 1, filteredTasks.count - 1)
            if next >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                tableView.scrollRowToVisible(next)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            let current = tableView.selectedRow
            let prev = max(current - 1, 0)
            tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            tableView.scrollRowToVisible(prev)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }
}

// MARK: - Task Editor

final class TaskEditorWindowController: NSWindowController {
    private let store: TaskStore
    private let existingTask: ScriptTask?
    var onSave: (() -> Void)?

    // Form fields
    private let idField = NSTextField()
    private let nameField = NSTextField()
    private let commandField = NSTextView()
    private let workDirField = NSTextField()
    private let envField = NSTextField()
    private let portsField = NSTextField()
    private let urlField = NSTextField()
    private let autoStartCheck = NSButton(checkboxWithTitle: "Auto Start", target: nil, action: nil)
    private let keepAliveCheck = NSButton(checkboxWithTitle: "Keep Alive", target: nil, action: nil)
    private let keepRunningOnQuitCheck = NSButton(checkboxWithTitle: "Keep Running on Quit", target: nil, action: nil)
    private let modeSegment = NSSegmentedControl(labels: ["Daemon", "One-shot"], trackingMode: .selectOne, target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let venvPopup = NSPopUpButton()
    private let optionalArgsField = NSTextField()
    private var detectedEnvironments: [(name: String, pythonPath: String)] = []

    init(store: TaskStore, task: ScriptTask?) {
        self.store = store
        self.existingTask = task
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = task == nil ? "Add Task" : "Edit Task"
        super.init(window: window)
        buildForm()
        if let task {
            populate(from: task)
            idField.isEnabled = false
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildForm() {
        guard let contentView = window?.contentView else { return }
        let pad: CGFloat = 20
        let rowHeight: CGFloat = 24
        let labelWidth: CGFloat = 110

        func addRow(_ label: String, _ field: NSView, yOffset: inout CGFloat) {
            let labelView = NSTextField(labelWithString: label)
            labelView.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            labelView.translatesAutoresizingMaskIntoConstraints = false
            field.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(labelView)
            contentView.addSubview(field)
            NSLayoutConstraint.activate([
                labelView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
                labelView.widthAnchor.constraint(equalToConstant: labelWidth),
                labelView.centerYAnchor.constraint(equalTo: field.centerYAnchor),
                field.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),
                field.topAnchor.constraint(equalTo: contentView.topAnchor, constant: yOffset),
                field.heightAnchor.constraint(equalToConstant: rowHeight)
            ])
            yOffset += rowHeight + 8
        }

        func addRowWithBrowse(_ label: String, _ field: NSView, browseAction: Selector, yOffset: inout CGFloat, height: CGFloat = rowHeight) {
            let labelView = NSTextField(labelWithString: label)
            labelView.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            labelView.translatesAutoresizingMaskIntoConstraints = false
            field.translatesAutoresizingMaskIntoConstraints = false

            let browseBtn = NSButton(title: "Browse…", target: self, action: browseAction)
            browseBtn.bezelStyle = .rounded
            browseBtn.controlSize = .small
            browseBtn.translatesAutoresizingMaskIntoConstraints = false

            contentView.addSubview(labelView)
            contentView.addSubview(field)
            contentView.addSubview(browseBtn)
            NSLayoutConstraint.activate([
                labelView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
                labelView.widthAnchor.constraint(equalToConstant: labelWidth),
                labelView.centerYAnchor.constraint(equalTo: field.centerYAnchor),
                browseBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),
                browseBtn.centerYAnchor.constraint(equalTo: field.centerYAnchor),
                field.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: browseBtn.leadingAnchor, constant: -8),
                field.topAnchor.constraint(equalTo: contentView.topAnchor, constant: yOffset),
                field.heightAnchor.constraint(equalToConstant: height)
            ])
            yOffset += height + 8
        }

        // Command field: multi-line text view
        commandField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        commandField.isEditable = true
        commandField.isSelectable = true
        commandField.isRichText = false
        commandField.drawsBackground = true
        commandField.backgroundColor = NSColor.controlBackgroundColor
        commandField.textContainerInset = NSSize(width: 4, height: 4)
        commandField.textContainer?.widthTracksTextView = true
        commandField.isHorizontallyResizable = false
        commandField.isVerticallyResizable = true
        commandField.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        var yOffset: CGFloat = pad
        idField.placeholderString = "e.g. my-web-server"
        addRow("ID", idField, yOffset: &yOffset)

        nameField.placeholderString = "e.g. My Web Server"
        addRow("Name", nameField, yOffset: &yOffset)

        // Virtual environment selector
        detectedEnvironments = detectPythonEnvironments()
        venvPopup.translatesAutoresizingMaskIntoConstraints = false
        venvPopup.addItem(withTitle: "None (use system Python)")
        venvPopup.menu?.addItem(NSMenuItem.separator())
        for env in detectedEnvironments {
            venvPopup.addItem(withTitle: "\(env.name) — \(env.pythonPath)")
        }
        if !detectedEnvironments.isEmpty {
            venvPopup.menu?.addItem(NSMenuItem.separator())
        }
        venvPopup.addItem(withTitle: "Browse…")
        venvPopup.target = self
        venvPopup.action = #selector(venvSelected)
        venvPopup.controlSize = .small
        addRow("Python Env", venvPopup, yOffset: &yOffset)

        // Command field wrapped in scroll view for multi-line support
        let commandScrollView = NSScrollView()
        commandScrollView.hasVerticalScroller = true
        commandScrollView.hasHorizontalScroller = false
        commandScrollView.borderType = .bezelBorder
        commandScrollView.drawsBackground = true
        commandScrollView.translatesAutoresizingMaskIntoConstraints = false
        commandScrollView.documentView = commandField
        commandField.translatesAutoresizingMaskIntoConstraints = false
        commandField.widthAnchor.constraint(equalTo: commandScrollView.widthAnchor).isActive = true
        commandField.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        let commandRowHeight: CGFloat = 56  // 2-line command input
        addRowWithBrowse("Command", commandScrollView, browseAction: #selector(browseCommand), yOffset: &yOffset, height: commandRowHeight)

        workDirField.placeholderString = "e.g. /Users/you/code/app"
        addRowWithBrowse("Working Dir", workDirField, browseAction: #selector(browseWorkDir), yOffset: &yOffset)

        envField.placeholderString = "e.g. PORT=5173,DEBUG=1"
        addRow("Environment", envField, yOffset: &yOffset)

        portsField.placeholderString = "e.g. 5173,3000"
        addRow("Ports", portsField, yOffset: &yOffset)

        urlField.placeholderString = "e.g. http://localhost:5173"
        addRow("Open URL", urlField, yOffset: &yOffset)

        // Optional arguments (one per line: label:arg or label:arg:default)
        optionalArgsField.placeholderString = "e.g. Verbose:--verbose, Port:--port:8080"
        addRow("Optional Args", optionalArgsField, yOffset: &yOffset)

        // Mode selector (Daemon / One-shot)
        modeSegment.translatesAutoresizingMaskIntoConstraints = false
        modeSegment.selectedSegment = 0
        modeSegment.target = self
        modeSegment.action = #selector(modeChanged)
        modeSegment.controlSize = .small
        addRow("Mode", modeSegment, yOffset: &yOffset)

        // Checkboxes
        keepRunningOnQuitCheck.toolTip = "Do not send a stop signal to this task when ScriptDock quits."
        let checkStack = NSStackView(views: [autoStartCheck, keepAliveCheck, keepRunningOnQuitCheck])
        checkStack.orientation = .horizontal
        checkStack.spacing = 14
        checkStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(checkStack)
        NSLayoutConstraint.activate([
            checkStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad + labelWidth + 8),
            checkStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: yOffset),
        ])
        yOffset += rowHeight + 16

        // Error label
        errorLabel.textColor = .systemRed
        errorLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            errorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),
            errorLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: yOffset),
        ])
        yOffset += rowHeight + 8

        // Buttons
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let buttonStack = NSStackView(views: [saveButton, cancelButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),
            buttonStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: yOffset),
        ])
    }

    private func populate(from task: ScriptTask) {
        idField.stringValue = task.id
        nameField.stringValue = task.name
        commandField.string = shellJoin(task.programArguments)
        workDirField.stringValue = task.workingDirectory ?? ""
        portsField.stringValue = (task.ports ?? []).map(String.init).joined(separator: ", ")
        urlField.stringValue = task.openURL ?? ""
        autoStartCheck.state = (task.runAtLoad ?? false) ? .on : .off
        keepAliveCheck.state = (task.keepAlive ?? false) ? .on : .off
        keepRunningOnQuitCheck.state = (task.keepRunningOnQuit ?? false) ? .on : .off
        modeSegment.selectedSegment = task.effectiveMode == .daemon ? 0 : 1
        updateCheckboxVisibility()
        if let env = task.environment {
            envField.stringValue = env.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        }
        // Populate optional arguments: one per line as "label:argument" or "label:argument:default"
        if let optArgs = task.optionalArguments, !optArgs.isEmpty {
            optionalArgsField.stringValue = optArgs.map { arg in
                if let defaultValue = arg.defaultValue, !defaultValue.isEmpty {
                    return "\(arg.label):\(arg.argument):\(defaultValue)"
                }
                return "\(arg.label):\(arg.argument)"
            }.joined(separator: ", ")
        }
    }

    @objc private func save() {
        NSApp.activate(ignoringOtherApps: true)
        let id = idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Validation
        if id.isEmpty {
            errorLabel.stringValue = "ID is required."
            return
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if id.rangeOfCharacter(from: allowed.inverted) != nil {
            errorLabel.stringValue = "ID can only contain letters, numbers, dots, dashes, underscores."
            return
        }
        if existingTask == nil, store.task(byID: id) != nil {
            errorLabel.stringValue = "A task with this ID already exists."
            return
        }
        if name.isEmpty {
            errorLabel.stringValue = "Name is required."
            return
        }

        // Parse arguments: shell-style word splitting (supports single quotes, double quotes, backslash escapes)
        let args = shellSplit(commandField.string)

        if args.isEmpty {
            errorLabel.stringValue = "At least one argument (the program) is required."
            return
        }

        // Validate executable exists
        let executable = args[0]
        if executable.contains("/") {
            if !FileManager.default.fileExists(atPath: executable) {
                errorLabel.stringValue = "Program does not exist: \(executable)"
                return
            }
            if !FileManager.default.isExecutableFile(atPath: executable) {
                errorLabel.stringValue = "File is not executable: \(executable)"
                return
            }
        } else {
            let which = ProcessRunner.run("/usr/bin/which", arguments: [executable])
            if which.status != 0 {
                errorLabel.stringValue = "Command not found on PATH: \(executable)"
                return
            }
        }

        // Validate argument shape (whitespace, pasted shell fragments, etc.)
        let tempTask = ScriptTask(id: id, name: name, programArguments: args)
        if let shapeError = store.argumentShapeProblem(for: tempTask) {
            // Extract just the first line of the error for display
            let firstLine = shapeError.components(separatedBy: "\n").first ?? shapeError
            errorLabel.stringValue = firstLine
            return
        }

        let workDir = workDirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate working directory exists if specified
        if !workDir.isEmpty && !FileManager.default.fileExists(atPath: workDir) {
            errorLabel.stringValue = "Working directory does not exist: \(workDir)"
            return
        }
        let env = parseEnv(envField.stringValue)
        let ports = portsField.stringValue.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let openURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse optional arguments: "label:argument" or "label:argument:default" per comma-separated entry
        let optArgsText = optionalArgsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var optionalArguments: [OptionalArgument]?
        if !optArgsText.isEmpty {
            var parsed: [OptionalArgument] = []
            for entry in optArgsText.components(separatedBy: ",") {
                let parts = entry.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: ":")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                    errorLabel.stringValue = "Invalid optional arg format: \"\(entry.trimmingCharacters(in: .whitespaces))\". Use Label:--flag or Label:--flag:default"
                    return
                }
                let hasDefault = parts.count >= 3 && !parts[2].isEmpty
                parsed.append(OptionalArgument(
                    label: parts[0],
                    argument: parts[1],
                    requiresValue: hasDefault,
                    defaultValue: hasDefault ? parts[2] : nil
                ))
            }
            if !parsed.isEmpty { optionalArguments = parsed }
        }

        var task = ScriptTask(
            id: id,
            name: name,
            programArguments: args,
            workingDirectory: workDir.isEmpty ? nil : workDir,
            runAtLoad: autoStartCheck.state == .on,
            keepAlive: keepAliveCheck.state == .on,
            openURL: openURL.isEmpty ? nil : openURL,
            ports: ports.isEmpty ? nil : ports,
            environment: env.isEmpty ? nil : env,
            optionalArguments: optionalArguments,
            keepRunningOnQuit: keepRunningOnQuitCheck.state == .on,
            mode: modeSegment.selectedSegment == 0 ? .daemon : .oneshot
        )
        // Preserve fields not in the editor
        if let existing = existingTask {
            if task.workingDirectory == nil { task.workingDirectory = existing.workingDirectory }
        }

        do {
            try store.addOrUpdateTask(task)
            close()
            onSave?()
        } catch {
            errorLabel.stringValue = "Failed to save: \(error.localizedDescription)"
        }
    }

    @objc private func cancel() {
        close()
    }

    @objc private func modeChanged() {
        updateCheckboxVisibility()
    }

    private func updateCheckboxVisibility() {
        let isDaemon = modeSegment.selectedSegment == 0
        autoStartCheck.isEnabled = isDaemon
        keepAliveCheck.isEnabled = isDaemon
        if !isDaemon {
            autoStartCheck.state = .off
            keepAliveCheck.state = .off
        }
    }

    @objc private func browseCommand() {
        let panel = NSOpenPanel()
        panel.title = "Select Executable"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        let currentText = commandField.string.trimmingCharacters(in: .whitespaces)
        if currentText.isEmpty {
            commandField.string = path
        } else {
            var args = shellSplit(currentText)
            if !args.isEmpty {
                args[0] = path
                commandField.string = shellJoin(args)
            } else {
                commandField.string = path
            }
        }
    }

    @objc private func browseWorkDir() {
        let panel = NSOpenPanel()
        panel.title = "Select Working Directory"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let currentPath = workDirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentPath.isEmpty, FileManager.default.fileExists(atPath: currentPath) {
            panel.directoryURL = URL(fileURLWithPath: currentPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workDirField.stringValue = url.path
    }

    @objc private func venvSelected() {
        let idx = venvPopup.indexOfSelectedItem
        // First item is "None" (index 0), separator is index 1
        // Detected envs start at index 2
        // Last item is "Browse…"
        let totalItems = venvPopup.numberOfItems
        let browseIndex = totalItems - 1

        if idx == browseIndex {
            // Browse for custom Python
            let panel = NSOpenPanel()
            panel.title = "Select Python Executable"
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            // Try to open /usr/local/bin or similar
            if (try? FileManager.default.contentsOfDirectory(atPath: "/usr/local/bin")) != nil {
                panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
            }
            guard panel.runModal() == .OK, let url = panel.url else {
                venvPopup.selectItem(at: 0)
                return
            }
            applyPythonPath(url.path)
            return
        }

        // Map popup index to detected env (account for "None" at 0, separator at 1)
        let envIndex = idx - 2  // skip "None" and separator
        if envIndex >= 0 && envIndex < detectedEnvironments.count {
            let env = detectedEnvironments[envIndex]
            applyPythonPath(env.pythonPath)
        } else {
            // "None" selected — don't change command
        }
    }

    private func applyPythonPath(_ pythonPath: String) {
        let currentText = commandField.string.trimmingCharacters(in: .whitespaces)
        if currentText.isEmpty {
            commandField.string = pythonPath
        } else {
            var args = shellSplit(currentText)
            if !args.isEmpty {
                // Replace first arg if it looks like a python command
                let first = args[0].lowercased()
                if first.hasSuffix("python") || first.hasSuffix("python3") || first.hasSuffix("python3.")
                        || first.contains("/python") || first.contains("/python3") {
                    args[0] = pythonPath
                } else {
                    // Prepend python path
                    args.insert(pythonPath, at: 0)
                }
                commandField.string = shellJoin(args)
            } else {
                commandField.string = pythonPath
            }
        }
    }

    private func detectPythonEnvironments() -> [(name: String, pythonPath: String)] {
        var envs: [(name: String, pythonPath: String)] = []
        let fm = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // 1. Conda environments — try common conda binary locations
        let condaCandidates = [
            home + "/anaconda3/bin/conda",
            home + "/miniconda3/bin/conda",
            home + "/miniforge3/bin/conda",
            home + "/mambaforge/bin/conda",
            "/opt/homebrew/Caskroom/miniconda/base/bin/conda",
            "/usr/local/Caskroom/miniconda/base/bin/conda",
        ]
        for condaPath in condaCandidates {
            guard fm.isExecutableFile(atPath: condaPath) else { continue }
            let condaResult = ProcessRunner.run(condaPath, arguments: ["env", "list", "--json"])
            if condaResult.status == 0, let data = condaResult.output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let envsList = json["envs"] as? [String] {
                for envPath in envsList {
                    let name = URL(fileURLWithPath: envPath).lastPathComponent
                    let pythonPath = envPath + "/bin/python"
                    if fm.isExecutableFile(atPath: pythonPath) {
                        envs.append((name: "conda: \(name)", pythonPath: pythonPath))
                    }
                }
            }
            break // found conda, stop searching
        }

        // 2. pyenv versions
        let pyenvRoot = ProcessRunner.run("/usr/bin/env", arguments: ["pyenv", "root"])
        if pyenvRoot.status == 0 {
            let root = pyenvRoot.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let versionsDir = root + "/versions"
            if let versions = try? fm.contentsOfDirectory(atPath: versionsDir) {
                for version in versions {
                    let pythonPath = versionsDir + "/" + version + "/bin/python"
                    if fm.isExecutableFile(atPath: pythonPath) {
                        envs.append((name: "pyenv: \(version)", pythonPath: pythonPath))
                    }
                }
            }
        }

        // 3. Common virtualenv locations
        let venvDirs = [
            home + "/.virtualenvs",
            home + "/.venvs",
            home + "/envs"
        ]
        for dir in venvDirs {
            if let contents = try? fm.contentsOfDirectory(atPath: dir) {
                for name in contents {
                    let pythonPath = dir + "/" + name + "/bin/python"
                    if fm.isExecutableFile(atPath: pythonPath) {
                        envs.append((name: "venv: \(name)", pythonPath: pythonPath))
                    }
                }
            }
        }

        // 4. Homebrew Python
        let brewPaths = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for path in brewPaths {
            if fm.isExecutableFile(atPath: path) {
                let version = ProcessRunner.run(path, arguments: ["--version"])
                let ver = version.output.trimmingCharacters(in: .whitespacesAndNewlines)
                envs.append((name: "Homebrew: \(ver)", pythonPath: path))
            }
        }

        // 5. System Python
        if fm.isExecutableFile(atPath: "/usr/bin/python3") {
            envs.append((name: "System Python", pythonPath: "/usr/bin/python3"))
        }

        return envs
    }

    private func parseEnv(_ envStr: String) -> [String: String] {
        var env: [String: String] = [:]
        for pair in envStr.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { env[key] = value }
        }
        return env
    }

    // Shell-style word splitting: supports single quotes, double quotes, backslash escapes
    private func shellSplit(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var i = s.startIndex
        let end = s.endIndex

        while i < end {
            let c = s[i]
            if c == " " || c == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                i = s.index(after: i)
            } else if c == "'" {
                i = s.index(after: i)
                while i < end && s[i] != "'" {
                    current.append(s[i])
                    i = s.index(after: i)
                }
                if i < end { i = s.index(after: i) } // skip closing quote
            } else if c == "\"" {
                i = s.index(after: i)
                while i < end && s[i] != "\"" {
                    if s[i] == "\\" {
                        i = s.index(after: i)
                        if i < end { current.append(s[i]) }
                    } else {
                        current.append(s[i])
                    }
                    i = s.index(after: i)
                }
                if i < end { i = s.index(after: i) } // skip closing quote
            } else if c == "\\" {
                i = s.index(after: i)
                if i < end { current.append(s[i]); i = s.index(after: i) }
            } else {
                current.append(c)
                i = s.index(after: i)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // Join arguments back into a shell-compatible string
    private func shellJoin(_ args: [String]) -> String {
        args.map { arg in
            if arg.isEmpty { return "''" }
            let needsQuote = arg.contains(" ") || arg.contains("'") || arg.contains("\"") ||
                             arg.contains("\\") || arg.contains("\t") || arg.contains("\n")
            if !needsQuote { return arg }
            // Use single quotes; escape embedded single quotes with '\''
            let escaped = arg.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }.joined(separator: " ")
    }
}

// MARK: - NSButton Action Helper

private var onActionAssociationKey: UInt8 = 0

extension NSButton {
    var onAction: ((NSButton) -> Void)? {
        get { objc_getAssociatedObject(self, &onActionAssociationKey) as? (NSButton) -> Void }
        set {
            if let newValue {
                objc_setAssociatedObject(self, &onActionAssociationKey, newValue, .OBJC_ASSOCIATION_RETAIN)
                self.action = #selector(invokeOnAction)
                self.target = self
            } else {
                self.action = nil
                self.target = nil
                objc_setAssociatedObject(self, &onActionAssociationKey, nil, .OBJC_ASSOCIATION_RETAIN)
            }
        }
    }

    @objc private func invokeOnAction(_ sender: NSButton) {
        onAction?(sender)
    }
}

// MARK: - Entry Point (@main on ScriptDockApp)
