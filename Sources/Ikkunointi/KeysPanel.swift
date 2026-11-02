import AppKit

/// Omarchy's SUPER+K: a cheat sheet of the configured bindings. A non-activating panel, so
/// the window you were in keeps focus; Esc or clicking elsewhere closes it.
final class KeysPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

    func toggle(rows: [(keys: String, description: String)], around screenFrame: CGRect) {
        if panel != nil { return close() }
        show(rows: rows, screenFrame: screenFrame)
    }

    func close() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func show(rows: [(keys: String, description: String)], screenFrame: CGRect) {
        let maxRows = max(8, Int((screenFrame.height - 140) / 21))
        let columns = max(1, Int(ceil(Double(rows.count) / Double(maxRows))))
        let perColumn = Int(ceil(Double(rows.count) / Double(columns)))

        let grid = NSGridView()
        grid.rowSpacing = 5
        grid.columnSpacing = 14
        let keyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let textFont = NSFont.systemFont(ofSize: 12)
        for r in 0..<perColumn {
            var cells: [NSView] = []
            for c in 0..<columns {
                let i = c * perColumn + r
                let keys = i < rows.count ? rows[i].keys : ""
                let desc = i < rows.count ? rows[i].description : ""
                let k = NSTextField(labelWithString: keys)
                k.font = keyFont
                k.textColor = .controlAccentColor
                k.alignment = .right
                let d = NSTextField(labelWithString: desc)
                d.font = textFont
                d.textColor = .labelColor
                d.lineBreakMode = .byTruncatingTail
                cells.append(k)
                cells.append(d)
                if c < columns - 1 { cells.append(NSView()) }
            }
            grid.addRow(with: cells)
        }
        for c in 0..<grid.numberOfColumns where (c + 1) % 3 == 0 {
            grid.column(at: c).width = 18
        }

        let title = NSTextField(labelWithString: "Key bindings")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        let hint = NSTextField(labelWithString: "Esc to close · edit ~/.config/ikkunointi/ikkunointi.conf")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, grid, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 18, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = effect
        let size = effect.fittingSize
        panel.setFrame(NSRect(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }
}

private final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}
