import BarnOwlCore
import BarnOwlNotes
import Testing

@Test
func meetingArtifactMarkdownIncludesTranscriptSummaryAndActions() {
    let renderer = MarkdownMeetingRenderer()
    let session = RecordingSession(
        title: "V1 Transcript Pass",
        startedAt: .init(timeIntervalSince1970: 0),
        audioSources: .defaultMeetingCapture
    )

    let markdown = renderer.render(
        session: session,
        segments: [
            TranscriptSegment(
                speakerLabel: "Speaker 1",
                text: "We need the transcript pass to save Markdown.",
                startTime: 0,
                endTime: 4
            ),
            TranscriptSegment(
                speakerLabel: "Speaker 2",
                text: "I will verify action item rendering.",
                startTime: 4,
                endTime: 8
            )
        ],
        summary: MeetingSummary(
            overview: "Reviewed the V1 transcript artifact path.",
            decisions: ["Render the local meeting artifact as Markdown."],
            actionItems: ["Verify transcript, summary, and actions render together."],
            openQuestions: ["How strict should diarization quality gates be?"]
        )
    )

    #expect(markdown.contains("# V1 Transcript Pass"))
    #expect(markdown.contains("## Summary\nReviewed the V1 transcript artifact path."))
    #expect(markdown.contains("## Action Items\n- Verify transcript, summary, and actions render together."))
    #expect(markdown.contains("## Transcript"))
    #expect(markdown.contains("**Speaker 1**\nWe need the transcript pass to save Markdown."))
    #expect(markdown.contains("**Speaker 2**\nI will verify action item rendering."))
}
