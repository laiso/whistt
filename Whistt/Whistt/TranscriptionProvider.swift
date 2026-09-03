public enum TranscriptionProvider: String {
    case openAI
    case gemini
    case meta
    case xAI

    public var apiKeyAccount: String {
        switch self {
        case .openAI: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        case .meta: return "META_API_KEY"
        case .xAI: return "XAI_API_KEY"
        }
    }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .meta: return "Meta"
        case .xAI: return "xAI"
        }
    }
}
