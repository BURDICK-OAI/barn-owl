import BarnOwlOpenAI
import Foundation

enum BarnOwlErrorFormatter {
    static func message(for error: Error) -> String {
        switch error {
        case OpenAITranscriptionClientError.unsuccessfulStatusCode(let statusCode, _):
            return openAIStatusMessage(service: "transcription", statusCode: statusCode)
        case OpenAITranscriptionClientError.responseDecodingFailed:
            return "OpenAI transcription returned a response Barn Owl could not read. Try again; if it repeats, update Barn Owl."
        case OpenAIResponsesClientError.unsuccessfulStatusCode(let statusCode, _):
            return openAIStatusMessage(service: "summary", statusCode: statusCode)
        case OpenAIResponsesClientError.responseDecodingFailed:
            return "OpenAI summary returned a response Barn Owl could not read. Try again; if it repeats, update Barn Owl."
        case OpenAIResponsesClientError.summaryPayloadDecodingFailed:
            return "OpenAI returned notes in a format Barn Owl could not read. Try regenerating the notes."
        case OpenAIResponsesClientError.missingOutputText:
            return "OpenAI summary response did not include output text."
        case OpenAIResponsesClientError.refused:
            return "OpenAI refused to generate notes for this meeting."
        default:
            if let localizedError = error as? LocalizedError,
               let description = localizedError.errorDescription,
               !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return sanitizeForUserDisplay(description)
            }
            return sanitizeForUserDisplay(String(describing: error))
        }
    }

    static func sanitizeForUserDisplay(_ text: String) -> String {
        var sanitized = text
        let replacements: [(String, String)] = [
            (#"sk-[A-Za-z0-9_\-]{8,}"#, "[redacted API key]"),
            (#"/Users/[^\n\r\t]+/Library/Application Support/[^\n\r\t]+"#, "[redacted local path]"),
            (#"/Users/[^/\s]+/[^\n\r\t ]*"#, "[redacted local path]"),
            (#"/private/(tmp|var)/[^\n\r\t ]*"#, "[redacted local path]"),
            (#"/var/folders/[^\n\r\t ]*"#, "[redacted local path]")
        ]

        for (pattern, replacement) in replacements {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        if sanitized.count > 320 {
            sanitized = String(sanitized.prefix(320)) + "..."
        }

        return sanitized
    }

    private static func openAIStatusMessage(service: String, statusCode: Int) -> String {
        switch statusCode {
        case 401, 403:
            return "OpenAI \(service) was rejected. Check the saved API key in Settings."
        case 408, 409, 425, 429:
            return "OpenAI \(service) is temporarily unavailable or rate limited. Try again in a moment."
        case 500...599:
            return "OpenAI \(service) is temporarily unavailable. Try again in a moment."
        default:
            return "OpenAI \(service) failed with status \(statusCode). Check Settings, billing/quota, and network access."
        }
    }
}
