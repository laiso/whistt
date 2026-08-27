public enum TranscriptionProvider: String {
    case openAI
    case gemini

    public var apiKeyAccount: String {
        switch self {
        case .openAI: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        }
    }
}
