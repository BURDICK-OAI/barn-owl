import BarnOwlOpenAI
import CryptoKit
import Foundation

enum BarnOwlFinalTranscriptionMode: String, CaseIterable, Identifiable {
    case speakerTurns = "speaker_turns"
    case transcriptOnly = "transcript_only"

    static let defaultsKey = "finalTranscriptionMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speakerTurns:
            "Speaker Turns"
        case .transcriptOnly:
            "Transcript Only"
        }
    }

    var detail: String {
        switch self {
        case .speakerTurns:
            "Use final speaker-turn labels for reviewable meeting transcripts."
        case .transcriptOnly:
            "Use context hints for final transcript spelling without speaker labels."
        }
    }

    var modelIdentifier: String {
        switch self {
        case .speakerTurns:
            OpenAIModelCatalog.finalDiarization
        case .transcriptOnly:
            OpenAIModelCatalog.finalTranscription
        }
    }

    func makeClient(
        configuration: OpenAIConfiguration,
        prompt: String? = nil
    ) -> OpenAITranscriptionClient {
        switch self {
        case .speakerTurns:
            OpenAITranscriptionClient(configuration: configuration)
        case .transcriptOnly:
            OpenAITranscriptionClient(
                configuration: configuration,
                model: modelIdentifier,
                responseFormat: "json",
                chunkingStrategy: nil,
                prompt: prompt
            )
        }
    }

    func cacheIdentifier(prompt: String?) -> String {
        guard self == .transcriptOnly,
              let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty
        else {
            return modelIdentifier
        }

        let digest = SHA256.hash(data: Data(prompt.utf8))
            .map { String(format: "%02x", Int($0)) }
            .joined()
        return "\(modelIdentifier)#prompt-sha256:\(digest)"
    }

    static func resolved(userDefaults: UserDefaults = .standard) -> BarnOwlFinalTranscriptionMode {
        guard let rawValue = userDefaults.string(forKey: defaultsKey),
              let stored = BarnOwlFinalTranscriptionMode(rawValue: rawValue)
        else {
            return .speakerTurns
        }
        return stored
    }
}
