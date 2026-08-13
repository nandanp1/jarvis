import AppKit

final class JarvisFlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class JarvisSettingsCardView: NSView {
    let contentStack = NSStackView()

    init(title: String, subtitle: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = JarvisTheme.panel.cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.075).cgColor

        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = JarvisTheme.accent
        titleLabel.setContentHuggingPriority(.required, for: .vertical)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 19, right: 20)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(titleLabel)

        if let subtitle = subtitle {
            let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
            subtitleLabel.font = NSFont.systemFont(ofSize: 12)
            subtitleLabel.textColor = JarvisTheme.secondaryText
            subtitleLabel.maximumNumberOfLines = 0
            contentStack.addArrangedSubview(subtitleLabel)
            subtitleLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -40).isActive = true
        }

        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func add(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -40).isActive = true
    }
}

enum JarvisSettingsUI {
    static func formRow(label: String, control: NSView, labelWidth: CGFloat = 160) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        labelView.textColor = JarvisTheme.primaryText
        labelView.alignment = .right
        labelView.setContentHuggingPriority(.required, for: .horizontal)
        labelView.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [labelView, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 14
        return stack
    }

    static func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    static func statusLabel(_ text: String = "") -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = JarvisTheme.secondaryText
        label.maximumNumberOfLines = 0
        return label
    }

    static func actionRow(_ views: [NSView]) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var arranged = views
        arranged.insert(spacer, at: 0)
        let row = NSStackView(views: arranged)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }
}

final class JarvisConnectedDevicesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let countLabel = NSTextField(labelWithString: "Not loaded")
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Test the Home Assistant connection or refresh to discover devices.")
    private var devices: [SmartDevice] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = JarvisTheme.secondaryText
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("JarvisDeviceColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.rowHeight = 27
        tableView.selectionHighlightStyle = .none
        tableView.delegate = self
        tableView.dataSource = self

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView

        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = JarvisTheme.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(countLabel)
        addSubview(scrollView)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 205),
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            countLabel.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 7),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -48)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(devices: [SmartDevice]) {
        self.devices = devices.sorted {
            let leftRoom = $0.room ?? ""
            let rightRoom = $1.room ?? ""
            if leftRoom.localizedCaseInsensitiveCompare(rightRoom) != .orderedSame {
                return leftRoom.localizedCaseInsensitiveCompare(rightRoom) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        countLabel.stringValue = devices.isEmpty ? "No compatible devices found" : "\(devices.count) device\(devices.count == 1 ? "" : "s") connected"
        emptyLabel.isHidden = !devices.isEmpty
        tableView.reloadData()
    }

    func showLoading() {
        countLabel.stringValue = "Discovering devices…"
        emptyLabel.isHidden = true
    }

    func showFailure() {
        countLabel.stringValue = devices.isEmpty ? "Devices unavailable" : "Showing \(devices.count) previously discovered device\(devices.count == 1 ? "" : "s")"
        emptyLabel.isHidden = !devices.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        devices.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard devices.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("JarvisDeviceCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = JarvisTheme.primaryText
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        let device = devices[row]
        let room = device.room?.nonEmpty ?? "Unassigned"
        cell.textField?.stringValue = "●  \(room)  ·  \(device.name)  —  \(device.type.displayName)"
        return cell
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
