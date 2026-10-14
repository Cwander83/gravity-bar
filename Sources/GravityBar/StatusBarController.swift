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
        popover.contentSize = NSSize(width: GravityBarTokens.popoverWidth, height: 420)
        popover.contentViewController = NSHostingController(rootView: PopoverView(manager: manager))
        popover.delegate = self
    }

    private func observeManager() {
        manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateButtonUI()
                }
            }
            .store(in: &cancellables)
    }

    private func updateButtonUI() {
        guard let button = statusItem.button else { return }

        let percent = Int(round(manager.maxUrgencyPercent))
        let titleString = percent > 0 ? "\(percent)%" : "--%"

        // Configure SF Symbol gauge icon
        let iconName = manager.highestUrgency == .critical
            ? "gauge.with.needle.fill"
            : "chart.bar.fill"

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "GravityBar")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true

        button.image = image
        button.imagePosition = .imageLeft
        button.title = titleString
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    }

    // MARK: - Actions & Events

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover(sender)
        }
    }

    public func showPopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startEventMonitor()
    }

    public func closePopover(_ sender: AnyObject?) {
        popover.performClose(sender)
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

    public func popoverDidClose(_ notification: Notification) {
        stopEventMonitor()
    }
}

/// Helper view tracking mouse cursor entry for menu bar hover interactions.
final class HoverTrackingView: NSView {
    var onHover: (() -> Void)?

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
        onHover?()
    }
}

