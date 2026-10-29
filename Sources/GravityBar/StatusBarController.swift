import AppKit
import SwiftUI
import Combine

/// Controller managing NSStatusItem, tracking area hover events, and NSPopover presentation.
@MainActor
public final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var manager: UsageManager

    public init(manager: UsageManager) {
        self.manager = manager
        super.init()
        setupStatusItem()
        setupPopover()
        observeManager()
    }

    public convenience override init() {
        self.init(manager: .shared)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Add hover tracking overlay for hover-to-open feature
        let hoverView = HoverTrackingView(frame: button.bounds)
        hoverView.autoresizingMask = [.width, .height]
        hoverView.onHover = { [weak self] in
            guard let self = self, self.manager.hoverToOpen else { return }
            if !self.popover.isShown, let btn = self.statusItem.button {
                self.showPopover(btn)
            }
        }
        button.addSubview(hoverView)

        updateButtonUI()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        // Size the popover from the SwiftUI content so inline Settings and the readout can differ in height
        let hostingController = NSHostingController(rootView: PopoverView(manager: manager))
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
        popover.delegate = self
    }

    private func observeManager() {
        manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateButtonUI()
            }
            .store(in: &cancellables)
    }

    internal private(set) var currentTitle: String?
    internal private(set) var currentIconName: String?
    internal private(set) var updateCount: Int = 0

    func updateButtonUI() {
        guard let button = statusItem.button else { return }

        let titleString = StatusBarController.statusTitle(hasReadings: manager.hasReadings, usedPercent: manager.maxUrgencyPercent)

        // Configure SF Symbol gauge icon
        let iconName = manager.highestUrgency == .critical
            ? "gauge.with.needle.fill"
            : "chart.bar.fill"

        guard titleString != currentTitle || iconName != currentIconName else {
            return
        }
        currentTitle = titleString
        currentIconName = iconName
        updateCount += 1

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "GravityBar")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true

        button.image = image
        button.imagePosition = .imageLeft
        button.title = titleString
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    }

    /// "--%" only while loading or when nothing is detected; an idle provider at 0% is a real reading.
    nonisolated static func statusTitle(hasReadings: Bool, usedPercent: Double) -> String {
        hasReadings ? "\(Int(round(usedPercent)))%" : "--%"
    }

    // MARK: - Actions & Events

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover(sender)
        }
    }

    /// Right-click menu with quick actions. Assigned only while open so left-click keeps toggling the popover.
    private func showContextMenu() {
        if popover.isShown {
            closePopover(nil)
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit GravityBar", action: #selector(quitApp), keyEquivalent: "q").target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        Task { await manager.refreshAll() }
    }

    @objc private func openPreferences() {
        manager.showingSettings = true
        showPopover(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    public func showPopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        manager.isPopoverOpen = true
        startEventMonitor()
    }

    public func closePopover(_ sender: AnyObject?) {
        popover.performClose(sender)
        manager.isPopoverOpen = false
        stopEventMonitor()
    }

    private func startEventMonitor() {
        stopEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self, self.popover.isShown else { return }
            self.closePopover(event)
        }
    }

    private func stopEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - NSPopoverDelegate

    public func popoverWillShow(_ notification: Notification) {
        manager.isPopoverOpen = true
    }

    public func popoverDidClose(_ notification: Notification) {
        manager.isPopoverOpen = false
        stopEventMonitor()
        if manager.showingSettings {
            manager.dismissSettings()
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}

/// Helper view tracking mouse cursor entry for menu bar hover interactions.
final class HoverTrackingView: NSView {
    var onHover: (() -> Void)?
    /// The cursor must rest on the item this long, so passing through to Control Center doesn't open it.
    static let dwellDelay: TimeInterval = 0.2
    private var pendingHover: DispatchWorkItem?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pendingHover?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onHover?() }
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverTrackingView.dwellDelay, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pendingHover?.cancel()
        pendingHover = nil
    }
}

