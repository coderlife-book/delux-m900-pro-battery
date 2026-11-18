// MouseBattery — 菜单栏显示 Delux M900 Pro 无线鼠标电量
// 视觉与交互按 ~/Desktop/mouse-battery.html 的设计稿实现。
//
// 只读：IOHIDManager 以非独占方式打开厂商 collection，只监听 report ID 3，
// 从不写设备、不打开鼠标/指针 collection。
//
// 帧格式（5 字节，含 report ID）:  03 30 40 <flags> <level>
//   flags bit0 = 链路   bit1 = 充电中
//   level      = 电量百分比（放电时可信；充电时会被电压顶成 100 的假值）
//
// 编译：
//   swiftc -O -swift-version 5 -framework Cocoa -framework IOKit \
//          -o MouseBattery.app/Contents/MacOS/MouseBattery MouseBattery.swift

import Cocoa
import IOKit
import IOKit.hid
import SwiftUI

let kVID = 0x1D57
let kPID = 0xFA65
let kUsagePage: Int = 0xFF00
let kOfflineAfter: TimeInterval = 15
let kCardWidth: CGFloat = 324

// MARK: - 设计 token（对应 mouse-battery.html 的 CSS 变量）

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum T {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { app in
            app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    static let ink   = dyn(NSColor(hex: 0x222825), NSColor(hex: 0xF2F4F0))
    static let sub   = dyn(NSColor(hex: 0x58615D), NSColor(hex: 0xC1C9C2))
    static let muted = dyn(NSColor(hex: 0x65706B), NSColor(hex: 0xAFB9B1))
    static let line  = dyn(NSColor(hex: 0x46534D, alpha: 0.145), NSColor(hex: 0xFFFFFF, alpha: 0.133))
    static let panel = dyn(NSColor(hex: 0xF9FAF7, alpha: 0.93), NSColor(hex: 0x262C29, alpha: 0.94))
    static let panelEdge = dyn(NSColor(hex: 0xFFFFFF, alpha: 0.66), NSColor(hex: 0xFFFFFF, alpha: 0.133))
    static let accent = dyn(NSColor(hex: 0x27795C), NSColor(hex: 0x70BC98))
    static let track  = dyn(NSColor(hex: 0xD5DFD7), NSColor(hex: 0x465249))
    static let hover  = dyn(NSColor(hex: 0x505B54, alpha: 0.063), NSColor(hex: 0xFFFFFF, alpha: 0.063))
    static let amber  = Color(red: 0.94, green: 0.62, blue: 0.20)
}

// MARK: - 状态

final class BatteryModel: ObservableObject {
    @Published var online = false
    @Published var charging = false
    @Published var level: Int? = nil          // 可信电量（充电时保持上一次的值）
    @Published var lastUpdate: Date? = nil
    @Published var refreshing = false
}

// MARK: - 卡片

struct CardView: View {
    @ObservedObject var model: BatteryModel
    var onRefresh: () -> Void
    var onQuit: () -> Void

    @State private var appeared = false
    @State private var refreshSpin: Double = 0

    private var fraction: CGFloat {
        guard model.online, let lv = model.level else { return 0 }
        return CGFloat(max(0, min(100, lv))) / 100
    }

    private var accent: Color { model.charging ? T.amber : T.accent }

    private var statusText: String {
        if !model.online { return "已离线" }
        return model.charging ? "充电中" : "放电中"
    }

    private var updatedText: String {
        guard model.online, let d = model.lastUpdate else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    var body: some View {
        VStack(spacing: 0) {
            info
            actions
        }
        .padding(6)
        .frame(width: kCardWidth)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(T.panelEdge, lineWidth: 1)
        )
        .shadow(color: Color(hex: 0x253B34).opacity(0.18), radius: 18, x: 0, y: 14)
        .shadow(color: Color(hex: 0x1D332B).opacity(0.11), radius: 2.5, x: 0, y: 2)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -3)
        .onAppear {
            withAnimation(.easeOut(duration: 0.16)) { appeared = true }
        }
        .animation(.smooth(duration: 0.3), value: model.online)
        .animation(.smooth(duration: 0.3), value: model.charging)
    }

    // MARK: 信息区

    private var info: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            track.padding(.top, 12).padding(.bottom, 10)
            meta
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("M900 Pro")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.45)
                    .foregroundStyle(T.ink)
                Text("无线鼠标")
                    .font(.system(size: 11))
                    .foregroundStyle(T.sub)
                    .padding(.top, 2)
                readout.padding(.top, 4)
            }
            Spacer(minLength: 0)
            DeviceArt(charging: model.charging, isOffline: !model.online)
                .frame(width: 87, height: 108)
                .padding(.trailing, 7)
                .offset(y: 0)
        }
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(model.level.map(String.init) ?? "—")
                .font(.system(size: 52, weight: .medium))
                .tracking(-3.4)
                .monospacedDigit()
                .foregroundStyle(model.online ? T.ink : T.muted)
                .contentTransition(.numericText(countsDown: true))
            Text("%")
                .font(.system(size: 24))
                .tracking(-1)
                .foregroundStyle(T.sub)
        }
        .animation(.smooth(duration: 0.45), value: model.level)
        .animation(.smooth(duration: 0.45), value: model.online)
    }

    private var track: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(T.track)
                Capsule()
                    .fill(accent)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 5)
        .animation(.smooth(duration: 0.5), value: fraction)
        .animation(.smooth(duration: 0.3), value: model.charging)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.online ? accent : T.muted.opacity(0.45))
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(T.sub)
            if !model.online {
                Text("鼠标关机或超出范围")
                    .font(.system(size: 11))
                    .foregroundStyle(T.muted)
                    .padding(.leading, 2)
                    .transition(.opacity)
            } else if model.charging {
                Text("显示充电前电量")
                    .font(.system(size: 11))
                    .foregroundStyle(T.muted)
                    .padding(.leading, 2)
                    .transition(.opacity)
            }
            Spacer(minLength: 8)
            Text(updatedText.isEmpty ? "" : "更新于 \(updatedText)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(T.muted)
        }
        .animation(.smooth(duration: 0.25), value: model.charging)
        .animation(.smooth(duration: 0.25), value: model.online)
    }

    // MARK: 动作区

    private var actions: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(T.line)
                .padding(.bottom, 5)
            ActionRow(icon: "arrow.clockwise",
                      title: "刷新电量",
                      shortcut: "⌘R",
                      spin: refreshSpin,
                      action: {
                          refreshSpin += 360
                          onRefresh()
                      })
            ActionRow(icon: "rectangle.portrait.and.arrow.right",
                      title: "退出",
                      shortcut: "⌘Q",
                      spin: nil,
                      action: onQuit)
        }
    }

    private var background: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(T.panel)
        }
    }
}

// MARK: - 产品图形（复刻设计稿里的鼠标 SVG）

struct DeviceArt: View {
    var charging: Bool
    var isOffline: Bool = false

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let sx = size.width / 95
                let sy = size.height / 120
                ctx.scaleBy(x: sx, y: sy)
                ctx.translateBy(x: 48, y: 60)
                ctx.rotate(by: .degrees(17))
                ctx.translateBy(x: -48, y: -60)

                // 投影
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 3.2))
                    layer.fill(Path(ellipseIn: CGRect(x: 21, y: 22, width: 58, height: 90)),
                               with: .color(Color(hex: 0x19251E).opacity(0.16)))
                }

                // 外圈
                let rim = Path { p in
                    p.move(to: CGPoint(x: 48, y: 6))
                    p.addCurve(to: CGPoint(x: 78, y: 42), control1: CGPoint(x: 67, y: 6), control2: CGPoint(x: 77, y: 18))
                    p.addLine(to: CGPoint(x: 79, y: 68))
                    p.addCurve(to: CGPoint(x: 48, y: 114), control1: CGPoint(x: 80, y: 97), control2: CGPoint(x: 68, y: 114))
                    // SVG 的 S 命令：第一控制点 = 上一段第二控制点关于当前点的镜像 (28,114)
                    p.addCurve(to: CGPoint(x: 17, y: 72), control1: CGPoint(x: 28, y: 114), control2: CGPoint(x: 16, y: 98))
                    p.addLine(to: CGPoint(x: 18, y: 40))
                    p.addCurve(to: CGPoint(x: 48, y: 6), control1: CGPoint(x: 19, y: 17), control2: CGPoint(x: 29, y: 6))
                    p.closeSubpath()
                }
                ctx.fill(rim, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(hex: 0x7C817E), location: 0),
                        .init(color: Color(hex: 0x444847), location: 0.17),
                        .init(color: Color(hex: 0x303433), location: 0.75),
                        .init(color: Color(hex: 0x1A1E1C), location: 1),
                    ]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 95, y: 26)))

                // 上壳
                let shell = Path { p in
                    p.move(to: CGPoint(x: 48, y: 7))
                    p.addCurve(to: CGPoint(x: 75, y: 39), control1: CGPoint(x: 65, y: 7), control2: CGPoint(x: 74, y: 17))
                    p.addLine(to: CGPoint(x: 76, y: 70))
                    p.addCurve(to: CGPoint(x: 48, y: 111), control1: CGPoint(x: 76, y: 95), control2: CGPoint(x: 66, y: 110))
                    p.addCurve(to: CGPoint(x: 20, y: 73), control1: CGPoint(x: 29, y: 111), control2: CGPoint(x: 20, y: 96))
                    p.addLine(to: CGPoint(x: 21, y: 39))
                    p.addCurve(to: CGPoint(x: 48, y: 7), control1: CGPoint(x: 22, y: 17), control2: CGPoint(x: 31, y: 7))
                    p.closeSubpath()
                }
                ctx.fill(shell, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(hex: 0x828784), location: 0),
                        .init(color: Color(hex: 0x565B59), location: 0.46),
                        .init(color: Color(hex: 0x383D3A), location: 1),
                    ]),
                    startPoint: CGPoint(x: 9.5, y: 0),
                    endPoint: CGPoint(x: 78, y: 120)))
                ctx.stroke(shell, with: .color(Color(hex: 0xB0B4AE).opacity(0.45)), lineWidth: 0.8)

                // 中缝
                var seam = Path()
                seam.move(to: CGPoint(x: 48, y: 7))
                seam.addLine(to: CGPoint(x: 48, y: 50))
                seam.move(to: CGPoint(x: 21, y: 49))
                seam.addQuadCurve(to: CGPoint(x: 42, y: 51), control: CGPoint(x: 34, y: 48))
                seam.move(to: CGPoint(x: 54, y: 51))
                seam.addQuadCurve(to: CGPoint(x: 75, y: 49), control: CGPoint(x: 66, y: 49))
                ctx.stroke(seam, with: .color(Color(hex: 0x222725)), lineWidth: 1.25)

                // 滚轮
                ctx.fill(Path(roundedRect: CGRect(x: 43.5, y: 20, width: 9, height: 20), cornerRadius: 4.5),
                         with: .color(Color(hex: 0x222624)))
                ctx.fill(Path(roundedRect: CGRect(x: 45, y: 21.5, width: 6, height: 16.5), cornerRadius: 3),
                         with: .color(Color(hex: 0x767B77)))
                var grip = Path()
                for i in 0..<4 {
                    let y = 25 + CGFloat(i) * 3
                    grip.move(to: CGPoint(x: 46, y: y))
                    grip.addLine(to: CGPoint(x: 50, y: y))
                }
                ctx.stroke(grip, with: .color(Color(hex: 0x464B47)), lineWidth: 0.6)

                // 侧键
                ctx.fill(Path(roundedRect: CGRect(x: 46.4, y: 44, width: 3.2, height: 7), cornerRadius: 1.6),
                         with: .color(Color(hex: 0x252A27)))

                // 左侧接缝
                var side = Path()
                side.move(to: CGPoint(x: 18, y: 51))
                side.addLine(to: CGPoint(x: 18, y: 59))
                side.move(to: CGPoint(x: 17.6, y: 63))
                side.addLine(to: CGPoint(x: 17.6, y: 71))
                ctx.stroke(side, with: .color(Color(hex: 0x181D1A)), lineWidth: 2.6)
            }

            if charging && !isOffline {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(T.amber))
                    .offset(x: 30, y: -38)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.28), value: charging)
    }
}

// MARK: - 动作行

struct ActionRow: View {
    let icon: String
    let title: String
    let shortcut: String
    let spin: Double?
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 15, height: 15)
                    .rotationEffect(.degrees(spin ?? 0))
                    .animation(.easeInOut(duration: 0.65), value: spin)
                    .foregroundStyle(hovering ? T.ink : T.sub)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(T.ink)
                Spacer(minLength: 8)
                Text(shortcut)
                    .font(.system(size: 12))
                    .tracking(1)
                    .foregroundStyle(T.muted)
            }
            .padding(.horizontal, 13)
            .frame(height: 33)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? T.hover : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressStyle(pressed: $pressed))
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
    }
}

/// 按压反馈：轻微缩放 + 透明度，避免夸张弹跳
struct PressStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, v in pressed = v }
    }
}

// MARK: - 无边框浮层

final class CardPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: kCardWidth, height: 280),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 菜单栏图标（复刻设计稿的 16×20 鼠标轮廓）

enum StatusGlyph {
    static func mouse(filled: Bool) -> NSImage {
        let size = NSSize(width: 14, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            let p = NSBezierPath()
            // 左上
            p.move(to: NSPoint(x: 7.2 * 14 / 16, y: 18 - 1 * 18 / 20))
            p.curve(to: NSPoint(x: 2 * 14 / 16, y: 18 - 7 * 18 / 20),
                    controlPoint1: NSPoint(x: 3.7 * 14 / 16, y: 18 - 1.3 * 18 / 20),
                    controlPoint2: NSPoint(x: 2 * 14 / 16, y: 18 - 3.7 * 18 / 20))
            p.line(to: NSPoint(x: 2 * 14 / 16, y: 18 - 7.8 * 18 / 20))
            p.line(to: NSPoint(x: 7.2 * 14 / 16, y: 18 - 7.8 * 18 / 20))
            p.close()
            // 右上
            p.move(to: NSPoint(x: 8.8 * 14 / 16, y: 18 - 1 * 18 / 20))
            p.line(to: NSPoint(x: 8.8 * 14 / 16, y: 18 - 7.8 * 18 / 20))
            p.line(to: NSPoint(x: 14 * 14 / 16, y: 18 - 7.8 * 18 / 20))
            p.line(to: NSPoint(x: 14 * 14 / 16, y: 18 - 7 * 18 / 20))
            p.curve(to: NSPoint(x: 8.8 * 14 / 16, y: 18 - 1 * 18 / 20),
                    controlPoint1: NSPoint(x: 14 * 14 / 16, y: 18 - 3.7 * 18 / 20),
                    controlPoint2: NSPoint(x: 12.3 * 14 / 16, y: 18 - 1.3 * 18 / 20))
            p.close()
            // 下半
            p.move(to: NSPoint(x: 2 * 14 / 16, y: 18 - 9.4 * 18 / 20))
            p.line(to: NSPoint(x: 14 * 14 / 16, y: 18 - 9.4 * 18 / 20))
            p.line(to: NSPoint(x: 14 * 14 / 16, y: 18 - 13 * 18 / 20))
            p.curve(to: NSPoint(x: 8 * 14 / 16, y: 18 - 19 * 18 / 20),
                    controlPoint1: NSPoint(x: 14 * 14 / 16, y: 18 - 16.5 * 18 / 20),
                    controlPoint2: NSPoint(x: 11.6 * 14 / 16, y: 18 - 19 * 18 / 20))
            p.curve(to: NSPoint(x: 2 * 14 / 16, y: 18 - 13 * 18 / 20),
                    controlPoint1: NSPoint(x: 4.4 * 14 / 16, y: 18 - 19 * 18 / 20),
                    controlPoint2: NSPoint(x: 2 * 14 / 16, y: 18 - 16.5 * 18 / 20))
            p.close()
            if filled {
                p.fill()
            } else {
                p.lineWidth = 1.4
                p.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    static func bolt() -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()
        img.isTemplate = true
        return img
    }

    static func offline() -> NSImage {
        let img = mouse(filled: true)
        img.isTemplate = true
        return img
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = BatteryModel()
    private var statusItem: NSStatusItem!
    private var panel: CardPanel?
    private var hosting: NSHostingView<AnyView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?

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
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.imagePosition = .imageLeading
        updateStatusItem()

        startHID()

        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker!, forMode: .common)

        if let secs = Double(ProcessInfo.processInfo.environment["MB_SHOWCARD"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
                self?.togglePanel()
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
        relayoutPanel()

        if debugMode {
            print("frame flags=0x\(String(flags, radix: 16)) level=\(raw) charging=\(charging)")
            fflush(stdout)
        }
    }

    // MARK: 状态栏

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        if !model.online {
            button.image = StatusGlyph.offline()
            button.title = model.level == nil ? " …" : " —"
        } else if model.charging {
            button.image = StatusGlyph.bolt()
            button.title = " " + (model.level.map { "\($0)%" } ?? "")
        } else {
            button.image = StatusGlyph.mouse(filled: true)
            button.title = " " + (model.level.map { "\($0)%" } ?? "")
        }
        button.font = .systemFont(ofSize: 13, weight: .semibold)
    }

    // MARK: 浮层

    private func makePanel() -> CardPanel {
        let p = CardPanel()
        let view = CardView(model: model,
                            onRefresh: { [weak self] in self?.refresh() },
                            onQuit: { NSApp.terminate(nil) })
        let host = NSHostingView(rootView: AnyView(view.fixedSize(horizontal: false, vertical: true)))
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        p.contentView = host
        p.setContentSize(NSSize(width: kCardWidth, height: ceil(fit.height)))
        hosting = host
        panel = p
        return p
    }

    private func relayoutPanel() {
        guard let p = panel, p.isVisible, let host = hosting else { return }
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        let newHeight = ceil(fit.height)
        guard abs(newHeight - p.frame.height) > 0.5 else { return }
        var frame = p.frame
        let top = frame.maxY
        frame.size.height = newHeight
        frame.origin.y = top - newHeight
        p.setFrame(frame, display: true, animate: false)
    }

    private func refresh() {
        lastAttempt = .distantPast
        scan()
    }

    @objc private func togglePanel() {
        if let p = panel, p.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let p = panel ?? makePanel()
        guard let button = statusItem.button, let win = button.window else {
            if debugMode { print("no button window"); fflush(stdout) }
            return
        }
        let rectOnScreen = win.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = win.screen ?? NSScreen.main

        let size = p.frame.size
        var x = rectOnScreen.midX - size.width / 2
        var y = rectOnScreen.minY - size.height - 8
        if let sf = screen?.visibleFrame {
            x = min(max(x, sf.minX + 8), sf.maxX - size.width - 8)
            y = max(y, sf.minY + 8)
        }
        p.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)

        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
        statusItem.button?.highlight(true)
        installDismissMonitors()
    }

    private func closePanel() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            p.alphaValue = 1
        })
        removeDismissMonitors()
        statusItem.button?.highlight(false)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self = self, let p = self.panel, p.isVisible else { return event }
            if event.type == .keyDown {
                if event.modifierFlags.contains(.command) {
                    if event.charactersIgnoringModifiers == "r" { self.refresh(); return nil }
                    if event.charactersIgnoringModifiers == "q" { NSApp.terminate(nil); return nil }
                }
                if event.keyCode == 53 { self.closePanel(); return nil }   // esc
                return event
            }
            // 点状态栏按钮时不在这里关：交给按钮 action 处理，避免关了又开
            if let w = event.window, w === self.statusItem.button?.window { return event }
            if let w = event.window, w !== p { self.closePanel() }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
