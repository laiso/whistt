public enum TranscriptionProvider: String {
    case openAI
    case gemini
    case meta

    public var apiKeyAccount: String {
        switch self {
        case .openAI: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        case .meta: return "META_API_KEY"
        }
    }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .meta: return "Meta"
        }
    }
}
