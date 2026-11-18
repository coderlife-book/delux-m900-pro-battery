// MouseBattery — 菜单栏显示 Delux M900 Pro 无线鼠标电量
//
// 只读：IOHIDManager 以非独占方式打开厂商 collection，只监听 report ID 3，
// 从不写设备、不打开鼠标/指针 collection。
//
// 帧格式（5 字节，含 report ID）:  03 30 40 <flags> <level>
//   flags bit0 = 链路   bit1 = 充电中
//   level      = 电量百分比（放电时可信；充电时会被电压顶成 100 的假值）
//
// 编译：
//   ./build.sh

import Cocoa
import IOKit
import IOKit.hid
import SwiftUI

let kVID = 0x1D57
let kPID = 0xFA65
let kUsagePage: Int = 0xFF00
let kOfflineAfter: TimeInterval = 15

// MARK: - 状态

final class BatteryModel: ObservableObject {
    @Published var online = false
    @Published var charging = false
    @Published var level: Int? = nil          // 可信电量（充电时保持上一次的值）
    @Published var lastUpdate: Date? = nil
    @Published var refreshing = false
}

// MARK: - 电量显示

private enum BatteryStatus {
    case inUse, charging, full, low, offline

    var title: String {
        switch self {
        case .inUse: return "正在使用"
        case .charging: return "正在充电"
        case .full: return "已充满"
        case .low: return "低电量"
        case .offline: return "未连接"
        }
    }

    var symbol: String {
        switch self {
        case .inUse, .low: return "circle.fill"
        case .charging: return "bolt.fill"
        case .full: return "checkmark"
        case .offline: return "circle"
        }
    }
}

private extension BatteryModel {
    var displayLevel: Int? {
        // 没有历史读数时，现有模型也可能保留充电帧里的 100% 占位值。
        guard let level, (0...100).contains(level), !(charging && level == 100) else { return nil }
        return level
    }

    var status: BatteryStatus {
        guard online else { return .offline }
        if charging { return .charging }
        if displayLevel == 100 { return .full }
        if let displayLevel, displayLevel <= 10 { return .low }
        return .inUse
    }

    var batteryTint: Color {
        switch status {
        case .offline: return .secondary
        case .charging, .full: return .green
        case .low: return .red
        case .inUse: return (displayLevel ?? 100) <= 20 ? .orange : .primary
        }
    }

    var percentage: String {
        displayLevel.map { "\($0)%" } ?? "—"
    }

    var levelDescription: String {
        guard displayLevel != nil else { return "电量未知" }
        return online && !charging ? "电量 \(percentage)" : "上次已知电量 \(percentage)"
    }
}

// MARK: - 浮层内容

private struct BatteryPopover: View {
    @ObservedObject var model: BatteryModel

    private static let relativeTime: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        VStack(spacing: 16) {
            header
            batteryBar
            statusRow
        }
        .padding(16)
        .frame(width: 310)
        .frame(minHeight: 150)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "computermouse")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("M900 Pro")
                    .font(.headline)
                Text(model.online ? "2.4G · 已连接" : "2.4G · 未连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(model.percentage)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(model.online ? Color.primary : Color.secondary)

                if model.displayLevel != nil && (model.charging || !model.online) {
                    Text("上次已知电量")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.levelDescription)
            .accessibilityAddTraits(.isStaticText)
        }
    }

    private var batteryBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let level = model.displayLevel, level > 0 {
                    Capsule()
                        .fill(model.batteryTint)
                        .frame(width: geometry.size.width * CGFloat(level) / 100)
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: model.status.symbol)
                .font(model.status == .charging || model.status == .full ? .caption : .system(size: 6))
                .foregroundStyle(model.status == .inUse ? Color.secondary : model.batteryTint)
                .frame(width: 12)
                .accessibilityHidden(true)

            Text(model.status.title)
                .font(.subheadline)
                .foregroundStyle(model.online ? Color.primary : Color.secondary)

            Spacer(minLength: 8)

            if let lastUpdate = model.lastUpdate {
                Group {
                    if model.online {
                        Text("刚刚更新")
                    } else {
                        TimelineView(.periodic(from: lastUpdate, by: 60)) { context in
                            let age = context.date.timeIntervalSince(lastUpdate)
                            let updated = age < 60 ? "不到 1 分钟前" : Self.relativeTime.localizedString(for: lastUpdate, relativeTo: context.date)
                            Text(updated)
                                .accessibilityLabel("最近更新")
                                .accessibilityValue(updated)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = BatteryModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var keyMonitor: Any?
    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        let refreshItem = menu.addItem(withTitle: "刷新电量", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "退出 MouseBattery", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        return menu
    }()

    // HID
    private var manager: IOHIDManager?
    private var current: IOHIDDevice?
    private var reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var ticker: Timer?
    private var lastSeen = Date.distantPast
    private var lastAttempt = Date.distantPast
    private let debugMode = ProcessInfo.processInfo.environment["MB_DEBUG"] != nil
    private var fakeActive = false

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItem()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: BatteryPopover(model: model))
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.keyCode == 53 {
                self.popover.performClose(nil)
                return nil
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            switch event.charactersIgnoringModifiers {
            case "r": self.refresh()
            case "q": self.quit()
            default: return event
            }
            return nil
        }

        startHID()

        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker!, forMode: .common)

        if let secs = Double(ProcessInfo.processInfo.environment["MB_SHOWCARD"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
                self?.togglePopover()
            }
        }
        // 调试：注入假状态，便于检查充电/离线两种外观（不碰设备）
        if let fake = ProcessInfo.processInfo.environment["MB_FAKE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self else { return }
                self.fakeActive = true
                switch fake {
                case "charging":
                    self.model.online = true
                    self.model.charging = true
                    self.model.level = 82
                    self.model.lastUpdate = Date()
                case "offline":
                    self.model.online = false
                case "empty":
                    self.model.online = false
                    self.model.level = nil
                default: break
                }
                self.updateStatusItem()
            }
        }
        if let ap = ProcessInfo.processInfo.environment["MB_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: ap == "dark" ? .darkAqua : .aqua)
        }
        if debugMode { print("started"); fflush(stdout) }
    }

    private func tick() {
        guard !fakeActive else { return }
        let online = Date().timeIntervalSince(lastSeen) < kOfflineAfter
        if online != model.online {
            model.online = online
            updateStatusItem()
        }
        if !online && Date().timeIntervalSince(lastAttempt) > 6 {
            lastAttempt = Date()
            if debugMode { print("rescan"); fflush(stdout) }
            scan()
        }
    }

    // MARK: HID

    private func startHID() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: kVID,
            kIOHIDProductIDKey as String: kPID,
        ]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m

        // 等 manager 完成初始匹配后再自己挑设备、开设备、挂回调。
        // 不在 matched 回调里做这些：实测那样注册的回调只能收到第一帧。
        lastAttempt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.scan()
        }
    }

    /// 接收器的厂商 collection（0xFF00）不是独立的 IOHIDDevice，
    /// 它是 System Control 那个 device 的 usage pair 之一。
    private func hasVendorCollection(_ device: IOHIDDevice) -> Bool {
        guard let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] else {
            return false
        }
        return pairs.contains { ($0[kIOHIDDeviceUsagePageKey as String] as? Int) == kUsagePage }
    }

    private func scan() {
        if let dev = current {
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            current = nil
        }
        guard let m = manager,
              let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>,
              let device = set.first(where: hasVendorCollection) else { return }
        attach(device)
    }

    private func attach(_ device: IOHIDDevice) {
        // 非独占：不会抢走设备，鼠标照常工作
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            if debugMode { print(String(format: "open failed 0x%X", r)); fflush(stdout) }
            return
        }
        current = device
        lastAttempt = Date()

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        reportBuffer.initialize(repeating: 0, count: 64)
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, { context, _, _, _, reportID, report, length in
            guard let context = context else { return }
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            app.ingest(reportID: Int(reportID), bytes: report, length: Int(length))
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        if debugMode { print("attached"); fflush(stdout) }
    }

    /// 回调拿到的 buffer 含 report ID：03 30 40 <flags> <level>
    private func ingest(reportID: Int, bytes: UnsafePointer<UInt8>, length: Int) {
        guard !fakeActive, reportID == 3, length >= 5 else { return }
        let flags = bytes[3]
        let raw = Int(bytes[4])

        lastSeen = Date()
        let charging = (flags & 0x02) != 0

        // 充电期间读到 100 是充电电压造成的假值，不予采信
        if !(charging && raw == 100) {
            model.level = raw
        }
        if model.level == nil { model.level = raw }
        model.charging = charging
        model.online = true
        model.lastUpdate = lastSeen
        updateStatusItem()

        if debugMode {
            print("frame flags=0x\(String(flags, radix: 16)) level=\(raw) charging=\(charging)")
            fflush(stdout)
        }
    }

    // MARK: 状态栏与浮层

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        button.title = " " + (model.online ? model.percentage : "—")
        button.setAccessibilityLabel("M900 Pro")
        button.setAccessibilityValue("\(model.status.title)，\(model.levelDescription)")
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp, let button = statusItem.button {
            popover.performClose(nil)
            NSMenu.popUpContextMenu(statusMenu, with: event, for: button)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button, button.window != nil,
                  let content = popover.contentViewController?.view {
            // 先完成内容测量，让系统按最终尺寸定位浮层。
            popover.contentSize = content.fittingSize
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            content.window?.makeKey()
        }
    }

    @objc private func refresh() {
        lastAttempt = .distantPast
        scan()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
