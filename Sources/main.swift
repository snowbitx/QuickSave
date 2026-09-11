import Cocoa
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications
import Darwin

/// libnotify 的 `notify_register_dispatch` 未暴露给 Swift，这里桥一下；
/// token 参数与 C 接口一致是 int32_t，自动桥接失败所以手动声明。
@_silgen_name("notify_register_dispatch")
func notify_register_dispatch_shim(_ name: UnsafePointer<CChar>,
                                   _ token: UnsafeMutablePointer<Int32>,
                                   _ queue: DispatchQueue,
                                   _ block: @convention(block) () -> Void) -> UInt32

// MARK: - 基础配置

/// 存储目录名，可通过 `defaults write com.wangxiaoyu.quicksave saveDirName <名字>` 覆盖
let directoryName = UserDefaults.standard.string(forKey: "saveDirName") ?? "docs"
let saveDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(directoryName, isDirectory: true)

/// 全局快捷键：⌘⌥S
let hotKeyID: UInt32 = 1
let hotKeyCode: UInt32 = UInt32(kVK_ANSI_S)
let hotKeyModifiers: UInt32 = UInt32(cmdKey) | UInt32(optionKey)

/// 调试用：`notifyutil -p com.wangxiaoyu.quicksave.capture` 可触发一次捕捉
let captureNotificationName = "com.wangxiaoyu.quicksave.capture"

// MARK: - 文件名与目录

func ensureDocsDirectory() -> Bool {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: saveDirectory.path, isDirectory: &isDir) {
        return isDir.boolValue
    }
    do {
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        return true
    } catch {
        NSLog("QuickSave: 创建目录失败 \(error)")
        return false
    }
}

func sanitizeFilename(_ raw: String) -> String {
    let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    var cleaned = raw.components(separatedBy: illegal).joined(separator: " ")
    cleaned = cleaned.components(separatedBy: .controlCharacters).joined()
    cleaned = cleaned.trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? "未命名" : cleaned
}

/// 生成不冲突的目标文件 URL：时间戳_首行片段.txt
func makeFileURL(for text: String) -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    let stamp = formatter.string(from: Date())

    let firstLine = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .newlines).first ?? ""
    let snippet = sanitizeFilename(String(firstLine.prefix(20)))

    var url = saveDirectory.appendingPathComponent("\(stamp)_\(snippet).txt")
    var counter = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = saveDirectory.appendingPathComponent("\(stamp)_\(snippet)_\(counter).txt")
        counter += 1
    }
    return url
}

// MARK: - 选中文本抓取

enum Capture {
    /// 走辅助功能 API 直接读取选中文本（无需动剪贴板）
    static func selectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return text
    }

    /// 回退方案：模拟 ⌘C，从剪贴板读取，随后恢复原剪贴板文本
    static func selectedTextViaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        let originalString = pasteboard.string(forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        var newText: String?
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            if pasteboard.changeCount != originalChangeCount {
                newText = pasteboard.string(forType: .string)
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if let original = originalString, !original.isEmpty {
            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)
        }
        return newText
    }

    static func captureSelectedText() -> (text: String, viaClipboard: Bool)? {
        if let text = selectedTextViaAccessibility(),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (text, false)
        }
        if let text = selectedTextViaClipboard(),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (text, true)
        }
        return nil
    }
}

// MARK: - 保存结果 HUD（不依赖通知权限，屏幕右上角浮现 2 秒）

final class SaveHUD {
    static let shared = SaveHUD()

    private let panel: NSPanel
    private let label: NSTextField
    private var hideItem: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12

        label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 14, y: 13, width: 272, height: 18)
        container.addSubview(label)
        panel.contentView = container
    }

    /// 必须在主线程调用
    func show(_ text: String, success: Bool) {
        label.stringValue = text
        label.textColor = success ? .labelColor : .systemRed
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 12, y: vf.maxY - size.height - 8))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideItem?.cancel()
        let item = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
        hideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: item)
    }
}

// MARK: - 应用主体

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate!

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var lastSavedName: String?
    private var iconResetWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例：若已有 QuickSave 在运行，结束旧的，自己接管菜单栏
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.wangxiaoyu.quicksave")
            .filter { $0 != NSRunningApplication.current }
        others.forEach { $0.terminate() }

        AppDelegate.shared = self
        NSApplication.shared.setActivationPolicy(.accessory)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        _ = ensureDocsDirectory()
        setupStatusItem()
        registerHotKey()
        registerDebugNotification()

        if !AXIsProcessTrusted() {
            promptForAccessibility()
        }
    }

    // MARK: 菜单

    private func setupStatusItem() {
        statusItem.button?.title = "📄"
        statusItem.button?.toolTip = "QuickSave 运行中 · 选中文字按 ⌘⌥S 保存"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let dirItem = NSMenuItem(title: "保存目录：~/\(directoryName)", action: nil, keyEquivalent: "")
        dirItem.isEnabled = false
        menu.addItem(dirItem)

        let capture = NSMenuItem(title: "立即捕捉选中文本", action: #selector(captureFromMenu), keyEquivalent: "s")
        capture.keyEquivalentModifierMask = [.command, .option]
        capture.target = self
        menu.addItem(capture)

        let clipboard = NSMenuItem(title: "将剪贴板文本存为文档", action: #selector(saveClipboardFromMenu), keyEquivalent: "")
        clipboard.target = self
        menu.addItem(clipboard)

        if let name = lastSavedName {
            let last = NSMenuItem(title: "最近保存：\(name)", action: nil, keyEquivalent: "")
            last.isEnabled = false
            menu.addItem(last)
        }

        menu.addItem(.separator())

        let openDir = NSMenuItem(title: "打开存储目录", action: #selector(openDirectory), keyEquivalent: "")
        openDir.target = self
        menu.addItem(openDir)

        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let ax = NSMenuItem(title: "授权辅助功能权限…", action: #selector(promptAccessibilityFromMenu), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)

        let notif = NSMenuItem(title: "通知设置…", action: #selector(openNotificationSettings), keyEquivalent: "")
        notif.target = self
        menu.addItem(notif)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 QuickSave", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    // MARK: 动作

    @objc private func captureFromMenu() {
        captureAndSave()
    }

    @objc private func saveClipboardFromMenu() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let text = NSPasteboard.general.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.notify(title: "剪贴板没有文本", body: "复制一段文字后再试")
                return
            }
            self.persist(text: text, source: "剪贴板", viaClipboard: false)
        }
    }

    @objc private func openDirectory() {
        _ = ensureDocsDirectory()
        NSWorkspace.shared.open(saveDirectory)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            notify(title: "设置开机自启失败", body: error.localizedDescription)
        }
        rebuildMenu()
    }

    @objc private func promptAccessibilityFromMenu() {
        promptForAccessibility()
    }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 捕捉与保存

    func captureAndSave() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard AXIsProcessTrusted() else {
                DispatchQueue.main.async {
                    self.promptForAccessibility()
                    SaveHUD.shared.show("⚠️ 请先在系统设置中授权辅助功能", success: false)
                    NSSound(named: "Basso")?.play()
                }
                return
            }
            let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知应用"
            guard let captured = Capture.captureSelectedText() else {
                DispatchQueue.main.async {
                    SaveHUD.shared.show("未捕获到选中文本，请先选中文字再按 ⌘⌥S", success: false)
                    NSSound(named: "Basso")?.play()
                }
                self.notify(title: "未捕获到选中文本", body: "请先选中文字，再按 ⌘⌥S（部分应用不支持抓取）")
                return
            }
            self.persist(text: captured.text, source: sourceApp, viaClipboard: captured.viaClipboard)
        }
    }

    private func persist(text: String, source: String, viaClipboard: Bool) {
        guard ensureDocsDirectory() else {
            notify(title: "保存失败", body: "无法创建目录 \(saveDirectory.path)")
            return
        }
        let url = makeFileURL(for: text)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            notify(title: "保存失败", body: error.localizedDescription)
            return
        }
        DispatchQueue.main.async {
            self.lastSavedName = url.lastPathComponent
            self.rebuildMenu()
            self.flashIcon("✅")
            SaveHUD.shared.show("✅ 已保存：\(url.lastPathComponent)", success: true)
            NSSound(named: "Pop")?.play()
        }
        let via = viaClipboard ? "（经剪贴板抓取）" : ""
        notify(title: "已保存到 ~/\(directoryName)", body: "\(url.lastPathComponent)\(via) 来自 \(source)")
    }

    // MARK: 反馈

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func flashIcon(_ symbol: String) {
        statusItem.button?.title = symbol
        iconResetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.statusItem.button?.title = "📄"
        }
        iconResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: 权限

    func promptForAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        notify(title: "需要辅助功能权限",
               body: "请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 QuickSave")
    }

    // MARK: 全局快捷键

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                AppDelegate.shared?.captureAndSave()
            }
            return noErr
        }, 1, &eventType, nil, nil)

        var hotKeyRef: EventHotKeyRef?
        let hotKeyIDStruct = EventHotKeyID(signature: OSType(0x51535645), id: hotKeyID) // 'QSVE'
        RegisterEventHotKey(hotKeyCode, hotKeyModifiers, hotKeyIDStruct, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// 调试/自动化入口：无需键盘也能触发一次捕捉
    private func registerDebugNotification() {
        var token: Int32 = 0
        _ = notify_register_dispatch_shim(captureNotificationName, &token, DispatchQueue.main) {
            AppDelegate.shared?.captureAndSave()
        }
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
