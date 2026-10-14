import Foundation
import PresenterCore
import Security

/// Reads sermon notes with Claude. The API key lives in the Keychain.
enum ClaudeClient {
    static let model = "claude-opus-5-5"

    enum ClaudeError: LocalizedError {
        case missingKey, http(Int, String), refused, empty

        var errorDescription: String? {
            switch self {
            case .missingKey: "Add your Anthropic API key in Settings › Bible › Sermon import."
            case .http(401, _): "Anthropic rejected the API key — check it in Settings › Bible."
            case .http(let code, let body): "Claude couldn't read the notes (\(code)). \(body.prefix(200))"
            case .refused: "Claude declined to read these notes."
            case .empty: "Claude didn't return any slides."
            }
        }
    }

    static var apiKey: String {
        get { Keychain.load() ?? "" }
        set { Keychain.save(newValue) }
    }

    /// Sends the notes (a PDF) and gets the slides back as a structured
    /// outline — the response is constrained to SermonOutline's schema.
    static func outline(fromPDF pdf: Data, fileName: String) async throws -> SermonOutline {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClaudeError.missingKey }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            // A rare safety decline is retried on Anthropic's recommended
            // fallback model instead of failing the import.
            "fallbacks": "default",
            "system": SermonOutline.instructions,
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": SermonOutline.schema],
            ],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "document", "title": fileName,
                     "source": ["type": "base64", "media_type": "application/pdf", "data": pdf.base64EncodedString()]],
                    ["type": "text", "text": "Make the slides for this sermon."],
                ],
            ]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClaudeError.http(status, String(decoding: data, as: UTF8.self))
        }
        struct Reply: Decodable {
            struct Block: Decodable { var type: String; var text: String? }
            var content: [Block]
            var stop_reason: String?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        if reply.stop_reason == "refusal" { throw ClaudeError.refused }
        guard let json = reply.content.first(where: { $0.type == "text" })?.text else { throw ClaudeError.empty }
        return try SermonOutline.decode(json)
    }

    private enum Keychain {
        static let service = "org.hopejc.screens.anthropic"
        static let account = "api-key"

        static func load() -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func save(_ secret: String) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var attributes = query
            attributes[kSecValueData as String] = Data(trimmed.utf8)
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
}
