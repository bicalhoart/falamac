import AppKit
import FalaCore

@MainActor
final class ConsumptionView: NSStackView {
    var onRefresh: (() -> Void)?
    private let local = NSTextField(wrappingLabelWithString: "")
    private let remote = NSTextField(wrappingLabelWithString: "Abra esta aba para consultar o consumo da chave.")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let refresh = NSButton(title: "Atualizar consumo", target: nil, action: nil)
    private var lastSuccess: Date?

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = 18
        edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        addArrangedSubview(title("FalaMac neste mês"))
        local.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular); addArrangedSubview(local)
        addArrangedSubview(title("OpenRouter — consumo informado pela API"))
        remote.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular); addArrangedSubview(remote)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; addArrangedSubview(status)
        refresh.target = self; refresh.action = #selector(refreshClicked); addArrangedSubview(refresh)
        let note = NSTextField(wrappingLabelWithString: "Os valores estão em dólares (US$). O OpenRouter informa o gasto de toda esta chave, incluindo outros apps que a utilizem, com dias e meses em UTC. O limite restante da chave não é o saldo da conta.\n\nO total local é estimado e inclui transcrição Groq e organização do texto. Na Groq, a cobrança real depende do plano da conta; confira no painel oficial. A estimativa usa a tarifa paga e não confirma cobrança no plano gratuito.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; addArrangedSubview(note)
        let links = NSStackView(views: [
            NSButton(title: "Saldo / créditos OpenRouter", target: self, action: #selector(openCredits)),
            NSButton(title: "Uso e cobrança Groq", target: self, action: #selector(openGroq))
        ])
        links.spacing = 12; addArrangedSubview(links)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .vertical); addArrangedSubview(spacer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showLocal(_ usage: MonthUsage, budget: Double) {
        local.stringValue = "\(usage.recordings) gravações · \(String(format: "%.1f", usage.seconds / 60)) minutos\nConsumo estimado: \(Self.money(usage.dollars))  ·  teto local: \(Self.money(budget))"
    }

    func show(_ usage: ProviderUsage, date: Date) {
        lastSuccess = date
        remote.stringValue = "Hoje (UTC): \(Self.money(usage.usageDaily))\nNeste mês (UTC): \(Self.money(usage.usageMonthly))\nTotal da chave: \(Self.money(usage.usage))\nTeto da chave: \(Self.money(usage.limit, fallback: "não informado / sem limite"))\nRestante no teto da chave: \(Self.money(usage.limitRemaining, fallback: "não informado / sem limite"))"
        status.stringValue = "Atualizado em \(date.formatted(date: .abbreviated, time: .standard))."
        refresh.isEnabled = true
    }

    func loading() { refresh.isEnabled = false; status.stringValue = "Consultando o OpenRouter…" }
    func failed(_ message: String) {
        let previous = lastSuccess.map { " Última leitura: \($0.formatted(date: .abbreviated, time: .standard))." } ?? ""
        status.stringValue = "Não foi possível atualizar: \(message)\(previous)"; refresh.isEnabled = true
    }
    func reset(authorized: Bool = false) {
        lastSuccess = nil
        remote.stringValue = authorized ? "Clique em Atualizar consumo para consultar esta chave."
            : "Autorize a chave OpenRouter em Configuração para consultar o consumo."
        status.stringValue = ""; refresh.isEnabled = true
    }

    private func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 15, weight: .semibold); return label
    }
    private static func money(_ value: Double?, fallback: String = "não informado") -> String {
        guard let value else { return fallback }
        return String(format: "US$ %.4f", locale: Locale(identifier: "pt_BR"), value)
    }
    @objc private func refreshClicked() { onRefresh?() }
    @objc private func openCredits() { NSWorkspace.shared.open(URL(string: "https://openrouter.ai/settings/credits")!) }
    @objc private func openGroq() { NSWorkspace.shared.open(URL(string: "https://console.groq.com/dashboard")!) }
}
