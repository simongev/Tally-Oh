//
//  DebugConsoleView.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  On-device debug console for viewing logs on physical devices
//

import UIKit

/// Singleton debug console for displaying logs on device
class DebugConsole {
    static let shared = DebugConsole()

    private var logs: [String] = []
    private var logViews: [DebugConsoleView] = []

    private init() {}

    /// Add a log message
    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"

        DispatchQueue.main.async { [weak self] in
            self?.logs.append(logEntry)

            // Keep only last 100 entries
            if let count = self?.logs.count, count > 100 {
                self?.logs.removeFirst(count - 100)
            }

            // Update all registered views
            self?.logViews.forEach { $0.updateLogs() }
        }

        // Also print to console for Xcode debugging
        print(message)
    }

    /// Register a view to receive log updates
    func registerView(_ view: DebugConsoleView) {
        logViews.append(view)
    }

    /// Unregister a view
    func unregisterView(_ view: DebugConsoleView) {
        logViews.removeAll { $0 === view }
    }

    /// Get all logs as a single string
    func getAllLogs() -> String {
        return logs.joined(separator: "\n")
    }

    /// Clear all logs
    func clearLogs() {
        logs.removeAll()
        logViews.forEach { $0.updateLogs() }
    }
}

/// UI view for displaying debug console
class DebugConsoleView: UIView {

    private let textView: UITextView = {
        let tv = UITextView()
        tv.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        tv.textColor = .green
        tv.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.isEditable = false
        tv.isSelectable = true
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    private let headerView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.darkGray.withAlphaComponent(0.9)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Debug Console"
        label.textColor = .white
        label.font = UIFont.boldSystemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("✕", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 20)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let copyButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Copy", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 12)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let clearButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Clear", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 12)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        DebugConsole.shared.registerView(self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        DebugConsole.shared.registerView(self)
    }

    deinit {
        DebugConsole.shared.unregisterView(self)
    }

    private func setupUI() {
        backgroundColor = .clear

        // Add header
        addSubview(headerView)
        headerView.addSubview(titleLabel)
        headerView.addSubview(closeButton)
        headerView.addSubview(copyButton)
        headerView.addSubview(clearButton)

        // Add text view
        addSubview(textView)

        NSLayoutConstraint.activate([
            // Header
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 36),

            // Title
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),

            // Clear button
            clearButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),

            // Copy button
            copyButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -12),

            // Close button
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 30),

            // Text view
            textView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)

        updateLogs()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func copyTapped() {
        let logs = DebugConsole.shared.getAllLogs()
        UIPasteboard.general.string = logs

        // Show feedback
        let originalTitle = copyButton.titleLabel?.text
        copyButton.setTitle("✓ Copied!", for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.copyButton.setTitle(originalTitle, for: .normal)
        }
    }

    @objc private func clearTapped() {
        DebugConsole.shared.clearLogs()
    }

    func updateLogs() {
        textView.text = DebugConsole.shared.getAllLogs()

        // Auto-scroll to bottom
        if textView.text.count > 0 {
            let bottom = NSRange(location: textView.text.count - 1, length: 1)
            textView.scrollRangeToVisible(bottom)
        }
    }
}
