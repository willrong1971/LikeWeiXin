import AppKit
import AVFoundation
import CoreMediaIO
import QuartzCore

// The app deliberately has no media writer, database, network client or persistent preferences.
enum PhoneDiscovery {
    static func enableWiredScreens() -> OSStatus {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var enabled: UInt32 = 1
        return CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address,
                                        0, nil, UInt32(MemoryLayout.size(ofValue: enabled)), &enabled)
    }

    static func screens() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.externalUnknown]
        if #available(macOS 14, *) { types = [.external, .continuityCamera] }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                         mediaType: nil, position: .unspecified)
        // A Continuity Camera is an iPhone webcam, not its screen. Never select it as a fallback.
        return discovery.devices.filter {
            $0.hasMediaType(.muxed) && !$0.isContinuityCamera &&
            ($0.modelID.lowercased().contains("ios") ||
             $0.modelID.lowercased().contains("iphone") ||
             $0.modelID.lowercased().contains("ipad"))
        }.sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }
}

final class FrameObserver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onDimensions: ((Int32, Int32) -> Void)?
    private var previous: CMVideoDimensions?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        guard size.width > 0, size.height > 0,
              previous?.width != size.width || previous?.height != size.height else { return }
        previous = size
        onDimensions?(size.width, size.height)
        // sampleBuffer is never copied, stored, serialized or retained by this object.
    }
}

final class PhoneView: NSView {
    private(set) var preview = AVCaptureVideoPreviewLayer()
    var onHoverChanged: ((Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var hoverArea: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspect
        layer?.insertSublayer(preview, at: 0)
        setAccessibilityElement(true)
        setAccessibilityLabel("手机实时画面")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
    override func mouseDown(with event: NSEvent) {
        onHoverChanged?(true)
        if event.clickCount == 2 { onDoubleClick?() }
        else { window?.performDrag(with: event) }
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
    }
    func clear() {
        preview.session = nil
        // Replacing the preview layer also drops the last rendered surface.
        preview.removeFromSuperlayer()
        preview.contents = nil
        preview = AVCaptureVideoPreviewLayer()
        preview.videoGravity = .resizeAspect
        preview.frame = bounds
        layer?.insertSublayer(preview, at: 0)
    }
}

// Keep keyboard focus with the separate input app, even when this panel is clicked.
final class DisplayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let phoneView = PhoneView(frame: .zero)
    private let devicesMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let connectButton = NSButton(title: "连接画面", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let pinButton = NSButton(checkboxWithTitle: "置顶", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "连接 iPhone，开始查看画面")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let toolsButton = NSButton()
    private let fitHeightButton = NSButton()
    private let toolbar = NSView()
    private let toolsCard = NSView()
    private var toolsExpanded = false
    private var pointerInside = false
    private var hideToolbarWork: DispatchWorkItem?
    private var sourceDimensions = NSSize(width: 1284, height: 2778)
    private var isHeightFitted = false
    private var normalWindowFrame: NSRect?
    private var adjustingWindowFrame = false
    private let placeholder = NSStackView()
    private let placeholderTitle = NSTextField(labelWithString: "把手机画面，放到 Mac 上")
    private let placeholderBody = NSTextField(wrappingLabelWithString:
        "① 用数据线连接 iPhone\n② 解锁手机，选择“信任”这台电脑\n③ 连接画面，在手机打开要展示的 App")
    private let sessionQueue = DispatchQueue(label: "local.will.LikeWeiXin.capture", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "local.will.LikeWeiXin.frames", qos: .utility)
    private var screens: [AVCaptureDevice] = []
    // Session lifecycle is confined to sessionQueue. UI state is confined to the main thread.
    private var activeSession: AVCaptureSession?
    private var frameObserver: FrameObserver?
    private var observers: [NSObjectProtocol] = []
    private var activeSessionObservers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var frameTimeout: DispatchWorkItem?
    private var generation = 0
    private var activeDeviceID: String?
    private var isConnecting = false
    private var isDisplaying = false
    private var isPaused = false
    private var shuttingDown = false
    private var cmioStatus: OSStatus = noErr
    private var initialConnectionPending = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.disableRelaunchOnLogin()
        buildMenu()
        buildWindow()
        cmioStatus = PhoneDiscovery.enableWiredScreens()
        refreshDevices()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.refreshDevices()
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.stopPreview(title: "Mac 即将休眠", body: "画面已清空。唤醒后可以重新连接。")
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isHeightFitted else { return }
                self.applyHeightFit()
            })
        // Bounded discovery retries handle delayed publication after USB trust/CMIO activation.
        var remaining = 8
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            self?.refreshDevices()
            remaining -= 1
            if remaining == 0 { timer.invalidate() }
        }
        window.orderFrontRegardless()
        setHeightFitted(true)
        scheduleToolbarHide()
        connectInitialDeviceIfAvailable()
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        appMenu.addItem(withTitle: "关于手机视窗", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏手机视窗", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出手机视窗", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let viewMenu = NSMenu(title: "窗口")
        let viewItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        viewMenu.addItem(withTitle: "连接 / 暂停画面", action: #selector(toggleConnection), keyEquivalent: " ")
        viewMenu.addItem(withTitle: "刷新设备", action: #selector(refreshClicked), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "切换置顶", action: #selector(togglePinFromMenu), keyEquivalent: "t")
        viewMenu.addItem(withTitle: "展开 / 收起工具", action: #selector(toggleTools), keyEquivalent: "i")
        viewMenu.addItem(withTitle: "撑满高度 / 恢复大小", action: #selector(toggleHeightFit), keyEquivalent: "f")
        viewMenu.addItem(withTitle: "打开手机键盘", action: #selector(openKeyboard), keyEquivalent: "k")
        NSApp.mainMenu = menu
    }

    private func buildWindow() {
        let panel = DisplayPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 779),
                                 styleMask: [.borderless, .resizable, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .black
        window = panel
        window.title = "手机视窗"
        window.contentMinSize = NSSize(width: 170, height: 300)
        window.contentAspectRatio = sourceDimensions
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.level = .floating
        window.center()
        window.contentView = phoneView
        phoneView.onHoverChanged = { [weak self] inside in self?.setPointerInside(inside) }
        phoneView.onDoubleClick = { [weak self] in self?.toggleHeightFit() }

        let symbol = NSImageView(image: NSImage(systemSymbolName: "iphone.and.arrow.forward",
                                               accessibilityDescription: "连接 iPhone") ?? NSImage())
        symbol.contentTintColor = NSColor(white: 0.65, alpha: 1)
        symbol.symbolConfiguration = .init(pointSize: 36, weight: .light)
        placeholderTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        placeholderTitle.textColor = .white
        placeholderTitle.alignment = .center
        placeholderBody.font = .systemFont(ofSize: 11)
        placeholderBody.textColor = NSColor(white: 0.72, alpha: 1)
        placeholderBody.alignment = .center
        placeholderBody.maximumNumberOfLines = 0
        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 14
        for view in [symbol, placeholderTitle, placeholderBody] { placeholder.addArrangedSubview(view) }
        phoneView.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: phoneView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: phoneView.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: phoneView.widthAnchor, constant: -28)
        ])

        configureOverlay(toolbar)
        configureOverlay(toolsCard)
        configureToolButton(toolsButton, title: "展开工具", symbol: "slider.horizontal.3", action: #selector(toggleTools))
        configureToolButton(fitHeightButton, title: "撑满高度", symbol: "arrow.up.and.down", action: #selector(toggleHeightFit))
        let closeButton = NSButton()
        configureToolButton(closeButton, title: "退出手机视窗", symbol: "xmark", action: #selector(closeViewer))
        let toolbarRow = NSStackView(views: [toolsButton, fitHeightButton, closeButton])
        toolbarRow.orientation = .horizontal
        toolbarRow.alignment = .centerY
        toolbarRow.spacing = 2
        toolbar.addSubview(toolbarRow)
        toolbarRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbarRow.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 5),
            toolbarRow.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -5),
            toolbarRow.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 3),
            toolbarRow.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -3)
        ])

        devicesMenu.setAccessibilityLabel("iPhone 屏幕设备")
        devicesMenu.target = self
        devicesMenu.action = #selector(deviceChanged)
        devicesMenu.controlSize = .small
        devicesMenu.setContentHuggingPriority(.defaultLow, for: .horizontal)
        devicesMenu.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        let deviceRow = NSStackView(views: [devicesMenu, refreshButton])
        deviceRow.orientation = .horizontal
        deviceRow.spacing = 6
        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .small
        connectButton.target = self
        connectButton.action = #selector(toggleConnection)
        connectButton.setAccessibilityIdentifier("connect-preview")
        pinButton.controlSize = .small
        pinButton.target = self
        pinButton.action = #selector(pinChanged)
        pinButton.state = .on
        let actionRow = NSStackView(views: [connectButton, NSView(), pinButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 6
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setAccessibilityIdentifier("preview-status")
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = NSColor(white: 0.78, alpha: 1)
        detailLabel.maximumNumberOfLines = 3
        detailLabel.stringValue = "拖动画面移动窗口；双击画面撑满高度或恢复。"
        let keyboardButton = NSButton(title: "打开手机键盘 ↗", target: self, action: #selector(openKeyboard))
        keyboardButton.bezelStyle = .inline
        keyboardButton.font = .systemFont(ofSize: 11)
        let toolsStack = NSStackView(views: [deviceRow, actionRow, statusLabel, detailLabel, keyboardButton])
        toolsStack.orientation = .vertical
        toolsStack.alignment = .leading
        toolsStack.spacing = 9
        toolsCard.addSubview(toolsStack)
        toolsStack.translatesAutoresizingMaskIntoConstraints = false
        for row in [deviceRow, actionRow] {
            row.widthAnchor.constraint(equalTo: toolsStack.widthAnchor).isActive = true
        }
        let preferredCardWidth = toolsCard.widthAnchor.constraint(equalToConstant: 300)
        preferredCardWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            toolsStack.leadingAnchor.constraint(equalTo: toolsCard.leadingAnchor, constant: 12),
            toolsStack.trailingAnchor.constraint(equalTo: toolsCard.trailingAnchor, constant: -12),
            toolsStack.topAnchor.constraint(equalTo: toolsCard.topAnchor, constant: 12),
            toolsStack.bottomAnchor.constraint(equalTo: toolsCard.bottomAnchor, constant: -12),
            detailLabel.widthAnchor.constraint(equalTo: toolsStack.widthAnchor),
            toolbar.topAnchor.constraint(equalTo: phoneView.topAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: phoneView.trailingAnchor, constant: -8),
            toolsCard.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            toolsCard.trailingAnchor.constraint(equalTo: phoneView.trailingAnchor, constant: -8),
            toolsCard.leadingAnchor.constraint(greaterThanOrEqualTo: phoneView.leadingAnchor, constant: 8),
            toolsCard.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            preferredCardWidth
        ])
        toolsCard.isHidden = true
    }

    private func configureOverlay(_ view: NSView) {
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        phoneView.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureToolButton(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func setPointerInside(_ inside: Bool) {
        pointerInside = inside
        hideToolbarWork?.cancel()
        if inside { toolbar.isHidden = false }
        else { scheduleToolbarHide() }
    }

    private func scheduleToolbarHide() {
        hideToolbarWork?.cancel()
        guard !pointerInside, !toolsExpanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerInside, !self.toolsExpanded else { return }
            self.toolbar.isHidden = true
        }
        hideToolbarWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    @objc private func toggleTools() { setToolsExpanded(!toolsExpanded) }
    private func setToolsExpanded(_ expanded: Bool) {
        toolsExpanded = expanded
        toolsCard.isHidden = !expanded
        toolsButton.toolTip = expanded ? "收起工具" : "展开工具"
        toolsButton.setAccessibilityLabel(expanded ? "收起工具" : "展开工具")
        toolbar.isHidden = false
        if expanded { hideToolbarWork?.cancel() }
        else { scheduleToolbarHide() }
    }

    @objc private func closeViewer() { NSApp.terminate(nil) }
    @objc private func toggleHeightFit() { setHeightFitted(!isHeightFitted) }
    private func setHeightFitted(_ fitted: Bool) {
        if fitted {
            if !isHeightFitted { normalWindowFrame = window.frame }
            isHeightFitted = true
            applyHeightFit()
        } else {
            isHeightFitted = false
            if var frame = normalWindowFrame {
                if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }),
                   let available = (window.screen ?? NSScreen.main)?.visibleFrame {
                    frame = ViewerGeometry.heightFittedFrame(available: available, source: sourceDimensions,
                                                             centerX: available.midX)
                }
                window.setFrame(frame, display: true)
            }
        }
        fitHeightButton.toolTip = fitted ? "恢复原大小" : "撑满高度"
        fitHeightButton.setAccessibilityLabel(fitted ? "恢复原大小" : "撑满高度")
        fitHeightButton.image = NSImage(systemSymbolName: fitted ? "arrow.down.right.and.arrow.up.left" : "arrow.up.and.down",
                                        accessibilityDescription: fitHeightButton.toolTip)
    }

    private func applyHeightFit() {
        guard !adjustingWindowFrame, let screen = window.screen ?? NSScreen.main else { return }
        adjustingWindowFrame = true
        let frame = ViewerGeometry.heightFittedFrame(available: screen.visibleFrame,
                                                     source: sourceDimensions, centerX: window.frame.midX)
        window.setFrame(frame, display: true)
        adjustingWindowFrame = false
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        isHeightFitted = false
        fitHeightButton.toolTip = "撑满高度"
        fitHeightButton.setAccessibilityLabel("撑满高度")
        fitHeightButton.image = NSImage(systemSymbolName: "arrow.up.and.down", accessibilityDescription: "撑满高度")
    }
    func windowDidChangeScreen(_ notification: Notification) {
        if isHeightFitted { applyHeightFit() }
    }
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        toggleHeightFit()
        return false
    }

    private func refreshDevices() {
        guard !shuttingDown else { return }
        let previousID = devicesMenu.selectedItem?.representedObject as? String
        screens = PhoneDiscovery.screens()
        devicesMenu.removeAllItems()
        if screens.isEmpty {
            devicesMenu.addItem(withTitle: "未发现 USB iPhone 屏幕")
            devicesMenu.isEnabled = false
        } else {
            for device in screens {
                devicesMenu.addItem(withTitle: device.localizedName)
                devicesMenu.lastItem?.representedObject = device.uniqueID
            }
            if let previousID,
               let item = devicesMenu.itemArray.first(where: { $0.representedObject as? String == previousID }) {
                devicesMenu.select(item)
            }
            devicesMenu.isEnabled = !isConnecting && !isDisplaying
        }
        let needsPermission = AVCaptureDevice.authorizationStatus(for: .video) != .authorized
        connectButton.isEnabled = needsPermission || isConnecting || isDisplaying || !screens.isEmpty
        if let activeDeviceID, !screens.contains(where: { $0.uniqueID == activeDeviceID }) {
            stopPreview(title: "iPhone 已断开", body: "画面已清空。重新插线、解锁并信任后，点“刷新”。")
        } else if !isConnecting && !isDisplaying && !isPaused {
            statusLabel.stringValue = screens.isEmpty ? "等待 USB iPhone" : "已发现 iPhone，可以连接画面"
            if cmioStatus != noErr {
                detailLabel.stringValue = "系统暂未开放手机画面（\(cmioStatus)）。请解锁、信任后刷新。"
            }
        }
        connectInitialDeviceIfAvailable()
    }

    private func connectInitialDeviceIfAvailable() {
        guard initialConnectionPending, screens.count == 1, !isConnecting, !isDisplaying else { return }
        initialConnectionPending = false
        // Launching this single-purpose viewer is the request to show the connected phone.
        // A system privacy prompt is still respected by toggleConnection when needed.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.shuttingDown, !self.isPaused else { return }
            self.toggleConnection()
        }
    }

    @objc private func refreshClicked() {
        cmioStatus = PhoneDiscovery.enableWiredScreens()
        refreshDevices()
    }
    @objc private func deviceChanged() { isPaused = false }
    @objc private func pinChanged() { window.level = pinButton.state == .on ? .floating : .normal }
    @objc private func togglePinFromMenu() {
        pinButton.state = pinButton.state == .on ? .off : .on
        pinChanged()
    }
    @objc private func openKeyboard() {
        let url = URL(fileURLWithPath: "/Applications/手机键盘.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        } else {
            let alert = NSAlert()
            alert.messageText = "没有找到“手机键盘”"
            alert.informativeText = "请从你原来的位置打开手机键盘，投屏窗口可以独立使用。"
            alert.beginSheetModal(for: window)
        }
    }

    @objc private func toggleConnection() {
        if isConnecting || isDisplaying {
            stopPreview(title: "已暂停，画面已清空", body: "点“连接画面”继续。手机上的 App 照常运行。")
            return
        }
        let permission = AVCaptureDevice.authorizationStatus(for: .video)
        if permission == .notDetermined {
            isConnecting = true
            generation += 1
            let token = generation
            connectButton.title = "取消连接"
            statusLabel.stringValue = "等待画面访问权限"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.generation == token, !self.shuttingDown else { return }
                    self.isConnecting = false
                    self.connectButton.title = "连接画面"
                    if granted {
                        self.refreshDevices()
                        self.toggleConnection()
                    } else { self.showPermissionHelp() }
                }
            }
            return
        }
        guard permission == .authorized else { showPermissionHelp(); return }
        guard let id = devicesMenu.selectedItem?.representedObject as? String,
              let device = screens.first(where: { $0.uniqueID == id }) else { refreshDevices(); return }
        generation += 1
        let token = generation
        activeDeviceID = id
        isConnecting = true
        isPaused = false
        connectButton.title = "取消连接"
        devicesMenu.isEnabled = false
        placeholderTitle.stringValue = "正在连接手机画面…"
        placeholderBody.stringValue = "请保持 iPhone 解锁。\n首次使用请允许系统的“摄像头”权限。"
        statusLabel.stringValue = "等待画面权限和手机连接"
        beginPreview(device, token: token)
    }

    private func showPermissionHelp() {
        stopPreview(title: "需要允许画面访问", body: "前往“系统设置 → 隐私与安全性 → 摄像头”，允许“手机视窗”后重新连接。")
        let alert = NSAlert()
        alert.messageText = "允许“手机视窗”访问画面"
        alert.informativeText = "macOS 将 USB 手机画面归在“摄像头”权限中。本程序仅选择 iPhone 屏幕，不使用 Mac 摄像头，也不录音。"
        alert.addButton(withTitle: "打开权限设置")
        alert.addButton(withTitle: "稍后")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func beginPreview(_ device: AVCaptureDevice, token: Int) {
        statusLabel.stringValue = "正在读取手机画面…"
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.isConnecting else { return }
            self.stopPreview(title: "还没有收到画面", body: "请解锁 iPhone 并信任电脑；关闭占用手机画面的其他程序，然后重试。")
        }
        frameTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let session = AVCaptureSession()
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            let observer = FrameObserver()
            observer.onDimensions = { [weak self, weak session] width, height in
                DispatchQueue.main.async {
                    guard let self, let session, self.generation == token, !self.shuttingDown else { return }
                    self.frameTimeout?.cancel()
                    self.isConnecting = false
                    self.isDisplaying = true
                    self.placeholder.isHidden = true
                    self.connectButton.title = "暂停并清屏"
                    self.statusLabel.stringValue = "正在显示手机画面"
                    self.detailLabel.stringValue = "拖动画面移动窗口；双击画面撑满高度或恢复。"
                    self.sourceDimensions = NSSize(width: CGFloat(width), height: CGFloat(height))
                    self.window.contentAspectRatio = self.sourceDimensions
                    if self.isHeightFitted { self.applyHeightFit() }
                    self.phoneView.setAccessibilityValue("实时画面，\(width) × \(height)")
                    if self.phoneView.preview.session !== session { self.phoneView.preview.session = session }
                    // Keep video output attached for the lifetime of the iPhone screen stream.
                    // Removing it after the first frame can leave this muxed source's preview frozen.
                }
            }
            output.setSampleBufferDelegate(observer, queue: self.sampleQueue)
            session.beginConfiguration()
            do {
                let input = try AVCaptureDeviceInput(device: device)
                for port in input.ports where port.mediaType == .audio { port.isEnabled = false }
                guard session.canAddInput(input) else { throw CaptureFailure.unavailable }
                session.addInput(input)
                guard session.canAddOutput(output) else { throw CaptureFailure.unavailable }
                session.addOutput(output)
                // The preview layer keeps the source aspect; no fixed landscape size is requested.
                session.commitConfiguration()
                self.activeSession = session
                self.frameObserver = observer
                self.activeSessionObservers = [
                    NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError,
                                                           object: session, queue: .main) { [weak self] note in
                        guard let self, self.generation == token else { return }
                        let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "手机画面暂时不可用"
                        self.stopPreview(title: "连接已停止", body: message)
                    },
                    NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted,
                                                           object: session, queue: .main) { [weak self] _ in
                        guard let self, self.generation == token else { return }
                        self.stopPreview(title: "手机画面已中断", body: "画面已清空。请检查手机状态，然后重新连接。")
                    }
                ]
                DispatchQueue.main.async {
                    guard self.generation == token, !self.shuttingDown else { return }
                    self.phoneView.preview.session = session
                    if let connection = self.phoneView.preview.connection, connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                }
                session.startRunning()
            } catch {
                session.commitConfiguration()
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    self.stopPreview(title: "无法打开手机画面", body: error.localizedDescription)
                }
            }
        }
    }

    private func stopPreview(title: String, body: String) {
        generation += 1
        frameTimeout?.cancel()
        frameTimeout = nil
        isConnecting = false
        isDisplaying = false
        isPaused = true
        activeDeviceID = nil
        phoneView.clear()
        phoneView.setAccessibilityValue("画面已清空")
        placeholder.isHidden = false
        placeholderTitle.stringValue = title
        placeholderBody.stringValue = body
        connectButton.title = "连接画面"
        connectButton.isEnabled = !screens.isEmpty || AVCaptureDevice.authorizationStatus(for: .video) != .authorized
        devicesMenu.isEnabled = !screens.isEmpty
        statusLabel.stringValue = title
        detailLabel.stringValue = "仅展示，不保存画面。可重新连接或退出。"
        if !shuttingDown { setToolsExpanded(true) }
        sessionQueue.async { [weak self] in self?.tearDownSession() }
    }

    private func tearDownSession() {
        activeSessionObservers.forEach(NotificationCenter.default.removeObserver)
        activeSessionObservers.removeAll()
        guard let session = activeSession else { return }
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for output in session.outputs {
            (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
        activeSession = nil
        frameObserver = nil
    }

    func windowWillMiniaturize(_ notification: Notification) {
        if isConnecting || isDisplaying {
            stopPreview(title: "窗口已最小化，画面已清空", body: "恢复窗口后，点“连接画面”继续。")
        }
    }
    func applicationDidHide(_ notification: Notification) {
        if isConnecting || isDisplaying {
            stopPreview(title: "窗口已隐藏，画面已清空", body: "显示窗口后，点“连接画面”继续。")
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return true }
    // NSApplication excludes NSPanel when counting remaining ordinary windows. A system
    // sharing/permission window closing must not terminate our still-visible display panel.
    // Closing the actual panel already explicitly terminates in windowShouldClose.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if sender.isHidden { sender.unhideWithoutActivation() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shuttingDown else { return .terminateNow }
        shuttingDown = true
        stopPreview(title: "已停止", body: "")
        refreshTimer?.invalidate()
        sessionQueue.async { [weak self] in
            self?.tearDownSession()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
    @objc private func showAbout() {
        let alert = NSAlert()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        alert.messageText = "手机视窗 \(version)"
        alert.informativeText = "通过 USB 实时展示 iPhone 当前屏幕，适合演示、教学。\n\n窗口不接管键盘；可配合独立的“手机键盘”输入。本程序不保存画面、不录音、不读取手机 App 的数据库。\n\n退出即停止画面连接。"
        alert.beginSheetModal(for: window)
    }
}

enum CaptureFailure: LocalizedError {
    case unavailable
    var errorDescription: String? { "系统无法建立手机画面预览。请解锁、信任电脑，并关闭占用该画面的其他程序后重试。" }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
