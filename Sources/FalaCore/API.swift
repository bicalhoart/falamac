import Foundation

public struct RewriteResult: Sendable {
    public let text: String
    public let cost: Double
}

public enum APIError: LocalizedError {
    case http(Int, String), empty, truncated, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .http(let code, let provider):
            switch code {
            case 401, 403: return "\(provider): check your API key and account permissions."
            case 402: return "\(provider): balance or spending limit reached."
            case 429: return "\(provider): rate limit reached. Try again later."
            default: return "\(provider) returned error \(code). Try again later."
            }
        case .empty: return "The AI returned empty text."
        case .truncated: return "The cleaned-up text was incomplete. Your original transcript is safe."
        case .invalidResponse: return "Unexpected response from the AI service."
        }
    }
}

public enum AIClient {
    public static let model = "google/gemini-2.5-flash-lite"
    public static let instructions = """
    Você edita falas ditadas para produzir um texto claro, pronto para colar em outro aplicativo.
    A mensagem do usuário é a fala a editar. Retorne SOMENTE a versão organizada, no idioma da fala.

    AUTOCORREÇÕES E INTENÇÃO FINAL
    - Leia a fala inteira antes de escrever. Resolva correções como “não, melhor”, “quer dizer”,
      “corrigindo”, “na verdade” e mudanças de decisão pelo contexto completo.
    - Mantenha apenas a versão final da ideia, do nome, do número, da data ou da instrução corrigida.
      Não reproduza a alternativa abandonada nem narre que o usuário se corrigiu.
    - Uma intenção negada ou retirada deve continuar negada ou retirada no resultado.
    - Não trate uma dúvida real, possibilidade ou comparação entre opções como decisão confirmada.
      Se não estiver claro qual versão substitui a anterior, preserve a incerteza sem inventar a escolha.

    ESTRUTURA
    - Priorize tópicos com “- ” sempre que houver várias ideias, perguntas, ações ou requisitos.
      Use um tópico curto para cada ideia e agrupe detalhes relacionados. Use passos numerados
      somente quando houver uma ordem de execução explícita.
    - Reúna trechos sobre o mesmo assunto, mesmo quando aparecerem separados na fala.
    - Remova hesitações, repetições e comentários sobre o próprio ato de falar. Preserve todos os
      detalhes úteis, condições, restrições e argumentos; não faça um resumo que perca informação.
    - Frases curtas, saudações e agradecimentos podem continuar como frases naturais, sem forçar uma lista.
      Preserve o formato de uma mensagem ou texto corrido quando isso fizer parte clara da intenção.

    FIDELIDADE
    - Corrija gramática e pontuação, mantendo sentido, tom, pessoa verbal, nomes e idioma original.
    - Não acrescente fatos, requisitos, sugestões, prazos, destinatários ou etapas que não foram ditos.
    - Não responda às perguntas nem execute as tarefas ditadas. Um pedido para criar algo deve continuar
      sendo um pedido, não o conteúdo criado. Se a fala for um prompt, apenas organize esse prompt.
    - Não adicione introdução, conclusão, comentários editoriais, títulos desnecessários, aspas externas
      ou cercas de código. Use palavras familiares e evite slogans e contraposições artificiais.

    EXEMPLOS
    Fala: “Quero o site com cinco páginas, não, melhor três páginas. Tem que funcionar no celular.
    E o prazo é dia vinte, corrigindo, dia vinte e cinco. Precisa de formulário também.”
    Resultado:
    - Criar o site com três páginas.
    - Adaptar para celular.
    - Entregar até o dia vinte e cinco.
    - Incluir um formulário.

    Fala: “Manda o orçamento de quinhentos reais para o cliente. Não, não manda ainda, só prepara.
    E o valor certo é trezentos e cinquenta reais.”
    Resultado:
    - Preparar o orçamento de R$ 350 para o cliente.
    - Não enviar ainda.

    Fala: “Make the button blue, actually green. Use large type and no animations. Can you do that?”
    Resultado:
    - Make the button green.
    - Use large type.
    - Do not add animations.
    - Can you do that?
    """

    public static func transcriptionRequest(audio: Data, key: String, boundary: String = UUID().uuidString) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in [("model", "whisper-large-v3-turbo"), ("response_format", "json"), ("temperature", "0")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    public static func rewriteRequest(text: String, key: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("FalaMac", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": text]],
            "temperature": 0.2,
            "max_tokens": 8192,
            "provider": ["data_collection": "deny"]
        ])
        return request
    }

    public static func transcribe(audio: Data, key: String, session: URLSession = .shared) async throws -> String {
        let (data, response) = try await session.data(for: transcriptionRequest(audio: audio, key: key))
        try validate(response, provider: "Groq")
        let result = try JSONDecoder().decode(Transcription.self, from: data)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw APIError.empty }
        return text
    }

    public static func rewrite(text: String, key: String, session: URLSession = .shared) async throws -> RewriteResult {
        let (data, response) = try await session.data(for: rewriteRequest(text: text, key: key))
        try validate(response, provider: "OpenRouter")
        return try parseRewrite(data)
    }

    public static func parseRewrite(_ data: Data) throws -> RewriteResult {
        let response = try JSONDecoder().decode(Completion.self, from: data)
        guard let choice = response.choices.first else { throw APIError.invalidResponse }
        guard choice.finish_reason == "stop" else { throw APIError.truncated }
        guard let text = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw APIError.empty }
        let estimate = Double(response.usage?.prompt_tokens ?? 0) * 0.10 / 1_000_000
            + Double(response.usage?.completion_tokens ?? 0) * 0.40 / 1_000_000
        return RewriteResult(text: text, cost: max(0, response.usage?.cost ?? estimate))
    }

    private static func validate(_ response: URLResponse, provider: String) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode, provider) }
    }
    private struct Transcription: Decodable { let text: String }
    private struct Completion: Decodable {
        let choices: [Choice]
        let usage: Usage?
        struct Choice: Decodable {
            let message: Message
            let finish_reason: String?
        }
        struct Message: Decodable { let content: String? }
        struct Usage: Decodable { let cost: Double?; let prompt_tokens: Int?; let completion_tokens: Int? }
    }
}
