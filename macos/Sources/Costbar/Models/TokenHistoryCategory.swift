import SwiftUI

/// The five token classes the core counts, in the order they are stacked and
/// listed everywhere they are shown.
enum TokenHistoryCategory: String, CaseIterable, Identifiable {
    case input
    case output
    case cacheRead
    case cacheCreation
    case reasoning

    var id: Self { self }

    var title: String {
        switch self {
        case .input: "Input"
        case .output: "Output"
        case .cacheRead: "Cache read"
        case .cacheCreation: "Cache write"
        case .reasoning: "Reasoning"
        }
    }

    var color: Color {
        switch self {
        case .input: WindowPalette.blue
        case .output: Color(red: 0.61, green: 0.42, blue: 0.94)
        case .cacheRead: Color(red: 0.26, green: 0.68, blue: 0.52)
        case .cacheCreation: Color(red: 0.94, green: 0.58, blue: 0.26)
        case .reasoning: Color(red: 0.91, green: 0.39, blue: 0.59)
        }
    }

    func tokens(in counted: some TokenCounted) -> UInt64 {
        switch self {
        case .input: counted.inputTokens
        case .output: counted.outputTokens
        case .cacheRead: counted.cacheReadTokens
        case .cacheCreation: counted.cacheCreationTokens
        case .reasoning: counted.reasoningTokens
        }
    }
}
