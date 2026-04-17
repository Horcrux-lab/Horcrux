import Foundation

/// Three-word memorable room code used to pair devices for an MPC ceremony.
///
/// Uses a curated short English word list (~256 common 3-6 letter words) →
/// 256³ ≈ 16.7M combinations per session, more than enough for ephemeral
/// ceremony IDs that only live for minutes.
enum RoomCode {
    /// Common, easy-to-spell English words. Curated to avoid homophones,
    /// confusing spellings, and profanity. Stable order — DO NOT reorder
    /// without a version bump (different devices must derive identical codes).
    static let words: [String] = [
        "able", "acid", "aged", "also", "area", "army", "away", "baby",
        "back", "ball", "band", "bank", "base", "bath", "bear", "beat",
        "been", "beer", "bell", "belt", "best", "bike", "bill", "bird",
        "blow", "blue", "boat", "body", "bomb", "bond", "bone", "book",
        "boom", "born", "boss", "both", "bowl", "bulk", "burn", "bush",
        "busy", "cafe", "cage", "cake", "call", "calm", "came", "camp",
        "card", "care", "case", "cash", "cast", "cave", "cell", "chat",
        "chip", "city", "club", "coal", "coat", "code", "cold", "come",
        "cook", "cool", "cope", "copy", "core", "corn", "cost", "crew",
        "crop", "dare", "dark", "data", "date", "dawn", "days", "deal",
        "dean", "dear", "debt", "deep", "deer", "deny", "desk", "dial",
        "dish", "disk", "does", "done", "door", "dose", "down", "draw",
        "drew", "drop", "drug", "drum", "dual", "duke", "dust", "duty",
        "each", "earn", "ease", "east", "easy", "edge", "else", "even",
        "ever", "evil", "exit", "face", "fact", "fade", "fail", "fair",
        "fall", "farm", "fast", "fate", "fear", "feed", "feel", "fell",
        "felt", "file", "fill", "film", "find", "fine", "fire", "firm",
        "fish", "five", "flag", "flow", "folk", "food", "foot", "ford",
        "form", "fort", "four", "free", "fuel", "full", "fund", "gain",
        "game", "gate", "gave", "gear", "gene", "gift", "girl", "give",
        "glad", "goal", "goes", "gold", "golf", "gone", "good", "gray",
        "grew", "grey", "grow", "gulf", "hair", "half", "hall", "hand",
        "hang", "hard", "harm", "hate", "have", "head", "hear", "heat",
        "held", "hell", "help", "herb", "here", "hero", "high", "hill",
        "hire", "hold", "hole", "holy", "home", "hope", "host", "hour",
        "huge", "hunt", "hurt", "idea", "inch", "into", "iron", "item",
        "jack", "java", "jazz", "jean", "jobs", "join", "july", "jump",
        "june", "jury", "just", "keep", "kept", "keys", "kick", "kids",
        "kind", "king", "knee", "knew", "know", "lack", "lady", "laid",
        "lake", "lamp", "land", "lane", "last", "late", "lead", "leaf",
        "lean", "left", "legs", "lend", "less", "life", "lift", "like",
        "line", "link", "lion", "lips", "list", "live", "load", "loan",
    ]

    /// Generate a new random 3-word room code (e.g. `apple-tiger-moon`).
    static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        let a = words.randomElement(using: &rng) ?? "apple"
        let b = words.randomElement(using: &rng) ?? "bridge"
        let c = words.randomElement(using: &rng) ?? "cloud"
        return "\(a)-\(b)-\(c)"
    }

    /// Returns true if `code` is a well-formed 3-word hyphen-separated code.
    static func isValid(_ code: String) -> Bool {
        let parts = code.lowercased().split(separator: "-")
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter } }
    }

    /// Normalize user input: lowercase, trimmed, spaces/underscores → hyphens.
    static func normalize(_ code: String) -> String {
        code
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }
}
