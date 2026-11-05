import AppKit
import FalaCore

@MainActor
final class ConsumptionView: NSStackView {
    var onRefresh: (() -> Void)?
    private let local = NSTextField(labelWithString: "—")
    private let localDetail = NSTextField(wrappingLabelWithString: "")
    private let forecastValue = NSTextField(labelWithString: "—")
    private let forecastDetail = NSTextField(wrappingLabelWithString: "Refresh usage to estimate the rest of this month.")
    private var budget: Double = 5
    private let remote = NSTextField(labelWithString: "—")
    private let remoteDetail = NSTextField(wrappingLabelWithString: "Open this tab to check usage.")
    private let quota = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    private var lastSuccess: Date?

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = 8
        edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        refresh.target = self; refresh.action = #selector(refreshClicked)
        let header = NSStackView(views: [title("OpenRouter · reported spend this month"), spacer, refresh])
        header.alignment = .centerY; addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: widthAnchor, constant: -40).isActive = true
        remote.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        addArrangedSubview(remote); addArrangedSubview(remoteDetail); addArrangedSubview(quota)
        addArrangedSubview(status)
        let separator = NSBox(); separator.boxType = .separator; addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: widthAnchor, constant: -40).isActive = true
        addArrangedSubview(title("Month-end forecast · OpenRouter only"))
        forecastValue.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        addArrangedSubview(forecastValue); addArrangedSubview(forecastDetail)
        addArrangedSubview(localDetail)
        let legacy = NSButton(title: "Show old local estimate", target: self, action: #selector(toggleLegacy))
        legacy.bezelStyle = .inline; addArrangedSubview(legacy)
        local.font = .systemFont(ofSize: 11); local.textColor = .secondaryLabelColor
        local.isHidden = true; addArrangedSubview(local)
        for label in [localDetail, remoteDetail, quota, status, forecastDetail] {
            label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalTo: widthAnchor, constant: -40).isActive = true
        }
        remoteDetail.toolTip = "Reported by OpenRouter for this API key across all apps, not just FalaMac. UTC day and month boundaries. Not a monthly subscription."
        quota.toolTip = "Remaining key allowance is not your account credit balance."
        forecastDetail.toolTip = "Reported month-to-date spend divided by UTC days since first use, multiplied by the remaining days, plus spend so far. Today is a partial day. If earlier usage dates are unknown, the average starts at the beginning of the UTC month. No Groq costs or local reservations."
        local.toolTip = "Legacy safety estimate includes assumed paid Groq pricing and unreconciled reservations. It is not actual billing and is not used by the forecast or spending check."
        let links = NSStackView(views: [
            NSButton(title: "OpenRouter billing", target: self, action: #selector(openCredits)),
            NSButton(title: "Groq dashboard", target: self, action: #selector(openGroq))
        ])
        links.spacing = 10; addArrangedSubview(links)
        let note = NSTextField(labelWithString: "USD · Groq is excluded from reported spend and forecast.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; addArrangedSubview(note)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showLocal(_ usage: MonthUsage, budget: Double) {
        self.budget = budget
        local.stringValue = "Old local estimate: \(Self.money(usage.dollars)) · not actual billing"
        localDetail.stringValue = "\(usage.recordings) recordings · \(String(format: "%.1f", usage.seconds / 60)) min · \(Self.money(budget, digits: 2)) monthly target"
    }

    func show(_ usage: ProviderUsage, date: Date, forecast: SpendForecast?) {
        lastSuccess = date
        remote.stringValue = Self.money(usage.usageMonthly)
        remoteDetail.stringValue = "Today (UTC): \(Self.money(usage.usageDaily)) · Key total: \(Self.money(usage.usage))"
        quota.stringValue = "Key limit: \(Self.money(usage.limit, fallback: "not available", digits: 2)) · Remaining allowance: \(Self.money(usage.limitRemaining, fallback: "not available"))"
        status.stringValue = "Updated \(Self.date(date)) · provider data may be delayed"
        if let forecast {
            forecastValue.stringValue = Self.money(forecast.projectedTotal)
            let sample = forecast.sampledDays == 1 ? "1 day · early estimate" : "\(forecast.sampledDays) calendar days"
            forecastDetail.stringValue = "\(Self.money(forecast.dailyAverage))/day average · \(sample)\n\(Self.money(forecast.projectedAdditional)) more over \(forecast.remainingDays) remaining days · UTC"
            forecastValue.textColor = forecast.projectedTotal > budget ? .systemOrange : .labelColor
        } else {
            forecastValue.stringValue = "—"
            forecastDetail.stringValue = "No reliable forecast yet. Try Refresh."
        }
        refresh.isEnabled = true
    }

    func loading() { refresh.isEnabled = false; status.stringValue = "Checking OpenRouter…" }
    func failed(_ message: String) {
        let previous = lastSuccess.map { " Last checked: \(Self.date($0))." } ?? ""
        status.stringValue = "Could not refresh: \(message)\(previous)"; refresh.isEnabled = true
    }
    func reset(authorized: Bool = false) {
        lastSuccess = nil; remote.stringValue = "—"; quota.stringValue = ""
        forecastValue.stringValue = "—"; forecastDetail.stringValue = "Refresh usage to estimate this month."
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
    @objc private func toggleLegacy(_ sender: NSButton) {
        local.isHidden.toggle()
        sender.title = local.isHidden ? "Show old local estimate" : "Hide old local estimate"
    }
    @objc private func refreshClicked() { onRefresh?() }
    @objc private func openCredits() { NSWorkspace.shared.open(URL(string: "https://openrouter.ai/settings/credits")!) }
    @objc private func openGroq() { NSWorkspace.shared.open(URL(string: "https://console.groq.com/dashboard")!) }
}
