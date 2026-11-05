import AppKit
import FalaCore

@MainActor
final class ConsumptionView: NSStackView {
    var onRefresh: (() -> Void)?
    private let local = NSTextField(labelWithString: "—")
    private let localDetail = NSTextField(wrappingLabelWithString: "")
    private let remote = NSTextField(labelWithString: "—")
    private let remoteDetail = NSTextField(wrappingLabelWithString: "Open this tab to check usage.")
    private let quota = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    private var lastSuccess: Date?

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = 12
        edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        refresh.target = self; refresh.action = #selector(refreshClicked)
        let header = NSStackView(views: [title("This month"), spacer, refresh])
        header.alignment = .centerY; addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: widthAnchor, constant: -40).isActive = true
        addArrangedSubview(title("This Mac · estimate"))
        local.font = .monospacedDigitSystemFont(ofSize: 25, weight: .medium)
        addArrangedSubview(local); addArrangedSubview(localDetail)
        let separator = NSBox(); separator.boxType = .separator; addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: widthAnchor, constant: -40).isActive = true
        addArrangedSubview(title("OpenRouter · reported"))
        remote.font = .monospacedDigitSystemFont(ofSize: 25, weight: .medium)
        addArrangedSubview(remote); addArrangedSubview(remoteDetail); addArrangedSubview(quota)
        addArrangedSubview(status)
        for label in [localDetail, remoteDetail, quota, status] {
            label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalTo: widthAnchor, constant: -40).isActive = true
        }
        remoteDetail.toolTip = "Usage covers this API key across all apps. Day and month boundaries use UTC."
        quota.toolTip = "Remaining key allowance is not your account credit balance."
        localDetail.toolTip = "Includes estimated Groq transcription and text cleanup. Free-tier usage may not be billed. This local limit does not replace provider spending limits."
        let links = NSStackView(views: [
            NSButton(title: "OpenRouter billing", target: self, action: #selector(openCredits)),
            NSButton(title: "Groq dashboard", target: self, action: #selector(openGroq))
        ])
        links.spacing = 10; addArrangedSubview(links)
        let note = NSTextField(labelWithString: "All amounts in USD. Manage billing limits with each provider.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; addArrangedSubview(note)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showLocal(_ usage: MonthUsage, budget: Double) {
        local.stringValue = Self.money(usage.dollars)
        localDetail.stringValue = "\(usage.recordings) recordings · \(String(format: "%.1f", usage.seconds / 60)) min · \(Self.money(budget, digits: 2)) monthly limit"
    }

    func show(_ usage: ProviderUsage, date: Date) {
        lastSuccess = date
        remote.stringValue = Self.money(usage.usageMonthly)
        remoteDetail.stringValue = "Today (UTC): \(Self.money(usage.usageDaily)) · Key total: \(Self.money(usage.usage))"
        quota.stringValue = "Key limit: \(Self.money(usage.limit, fallback: "not available", digits: 2)) · Remaining allowance: \(Self.money(usage.limitRemaining, fallback: "not available"))"
        status.stringValue = "Updated \(Self.date(date))"
        refresh.isEnabled = true
    }

    func loading() { refresh.isEnabled = false; status.stringValue = "Checking OpenRouter…" }
    func failed(_ message: String) {
        let previous = lastSuccess.map { " Last checked: \(Self.date($0))." } ?? ""
        status.stringValue = "Could not refresh: \(message)\(previous)"; refresh.isEnabled = true
    }
    func reset(authorized: Bool = false) {
        lastSuccess = nil; remote.stringValue = "—"; quota.stringValue = ""
        remoteDetail.stringValue = authorized ? "Click Refresh to check usage."
            : "Unlock your OpenRouter key in Settings to check usage."
        status.stringValue = ""; refresh.isEnabled = true
    }

    private func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 13, weight: .semibold); return label
    }
    private static func date(_ value: Date) -> String {
        value.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(Locale(identifier: "en_US")))
    }
    private static func money(_ value: Double?, fallback: String = "not available", digits: Int = 4) -> String {
        guard let value else { return fallback }
        return String(format: "$%.*f", locale: Locale(identifier: "en_US"), digits, value)
    }
    @objc private func refreshClicked() { onRefresh?() }
    @objc private func openCredits() { NSWorkspace.shared.open(URL(string: "https://openrouter.ai/settings/credits")!) }
    @objc private func openGroq() { NSWorkspace.shared.open(URL(string: "https://console.groq.com/dashboard")!) }
}
