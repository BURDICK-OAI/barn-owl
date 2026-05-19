import BarnOwlCore
import BarnOwlNotes
import Foundation
import Testing

@Test
func largeMarkdownRenderingCompletesWithinSmokeBudget() {
    let renderer = MarkdownMeetingRenderer()
    let segments = (0..<750).map { index in
        TranscriptSegment(
            speakerLabel: "Speaker \(index % 6 + 1)",
            text: "Transcript segment \(index) with enough meeting detail to exercise note rendering.",
            startTime: Double(index) * 3,
            endTime: Double(index) * 3 + 2
        )
    }
    let summary = MeetingSummary(
        overview: "Reviewed launch readiness and production follow-up work.",
        decisions: (0..<20).map { "Decision \($0)" },
        actionItems: (0..<20).map { "Action item \($0)" },
        openQuestions: (0..<20).map { "Open question \($0)" }
    )

    let startedAt = Date()
    let markdown = renderer.render(
        session: makeSession(title: "Production Readiness Review"),
        segments: segments,
        summary: summary,
        context: (0..<20).map { "Context item \($0)" },
        format: .planningReview
    )
    let elapsed = Date().timeIntervalSince(startedAt)

    #expect(markdown.contains("# Production Readiness Review"))
    #expect(markdown.contains("## Transcript"))
    #expect(markdown.contains("Transcript segment 749"))
    #expect(elapsed < 5)
}

@Test
func rendererIncludesTranscriptAndSummary() {
    let renderer = MarkdownMeetingRenderer()
    let session = RecordingSession(
        title: "Pipeline Review",
        startedAt: .init(timeIntervalSince1970: 0),
        audioSources: .defaultMeetingCapture
    )
    let markdown = renderer.render(
        session: session,
        segments: [
            TranscriptSegment(speakerLabel: "Speaker 1", text: "We should ship the scaffold.", startTime: 0, endTime: 2)
        ],
        summary: MeetingSummary(overview: "Reviewed the first build path.", decisions: ["Use native macOS first."]),
        context: ["Calendar: Pipeline Review"]
    )

    #expect(markdown.contains("# Pipeline Review"))
    #expect(markdown.contains("Meeting Type: General Discussion"))
    #expect(markdown.contains("Reviewed the first build path."))
    #expect(markdown.contains("## Context"))
    #expect(markdown.contains("Calendar: Pipeline Review"))
    #expect(markdown.contains("Speaker 1"))
    #expect(!markdown.contains("- **Speaker 1**"))
}

@Test
func rendererInfersCustomerWorkshopFormat() {
    let renderer = MarkdownMeetingRenderer()
    let session = RecordingSession(
        title: "Acme Customer Workshop",
        startedAt: .init(timeIntervalSince1970: 0),
        audioSources: .defaultMeetingCapture
    )
    let markdown = renderer.render(
        session: session,
        segments: [
            TranscriptSegment(
                speakerLabel: "Customer",
                text: "We need to map requirements and understand the current workflow.",
                startTime: 0,
                endTime: 2
            )
        ],
        summary: MeetingSummary(overview: "Discussed implementation requirements."),
        context: ["Account: Acme"]
    )

    #expect(markdown.contains("Meeting Type: Customer Workshop"))
    #expect(markdown.contains("## Customer Context"))
    #expect(markdown.contains("Account: Acme"))
}

@Test
func rendererCanUseExplicitOneOnOneFormat() {
    let renderer = MarkdownMeetingRenderer()
    let session = RecordingSession(
        title: "Weekly Check-in",
        startedAt: .init(timeIntervalSince1970: 0),
        audioSources: .defaultMeetingCapture
    )
    let markdown = renderer.render(
        session: session,
        segments: [],
        summary: MeetingSummary(overview: "Discussed blockers."),
        context: ["Manager: Taylor"],
        format: .oneOnOne
    )

    #expect(markdown.contains("Meeting Type: One-on-One"))
    #expect(markdown.contains("## Relationship Context"))
    #expect(markdown.contains("Manager: Taylor"))
}

@Test
func rendererUsesCanonicalMeetingFactsWithoutDuplicateFactSections() {
    let renderer = MarkdownMeetingRenderer()
    let session = RecordingSession(
        title: "Untitled Meeting",
        startedAt: .init(timeIntervalSince1970: 0),
        audioSources: .defaultMeetingCapture
    )
    let facts = MeetingFacts(
        title: "Acme Rollout Planning",
        meetingType: "Customer Workshop",
        participants: ["Dana", "Lee"],
        customers: ["Acme"],
        glossary: ["SG": "Strategic Growth"]
    )
    let markdown = renderer.render(
        session: session,
        segments: [
            TranscriptSegment(speakerLabel: "Dana", text: "We discussed rollout planning.", startTime: 0, endTime: 2)
        ],
        summary: MeetingSummary(overview: "Discussed rollout planning."),
        meetingFacts: facts
    )

    #expect(markdown.contains("# Acme Rollout Planning"))
    #expect(markdown.components(separatedBy: "## Meeting Facts").count == 2)
    #expect(!markdown.contains("## Participants"))
    #expect(!markdown.contains("\nMeeting Type:"))
    #expect(markdown.contains("- Participants: Dana, Lee"))
    #expect(markdown.contains("- Customers: Acme"))
}

@Test
func rendererShowsAcceptedContextOnceWhenFactsCarryTheSameContext() {
    let renderer = MarkdownMeetingRenderer()
    let sharedContext = "Calendar context: OpenAI <> Moderna."
    let markdown = renderer.render(
        session: makeSession(title: "Moderna Review"),
        segments: [],
        summary: MeetingSummary(overview: "Reviewed the account."),
        context: [sharedContext],
        meetingFacts: MeetingFacts(
            title: "Moderna Review",
            meetingType: "Customer Workshop",
            customers: ["Moderna"],
            additionalContext: [sharedContext]
        )
    )

    #expect(markdown.components(separatedBy: sharedContext).count == 2)
    #expect(markdown.contains("## Context"))
}

@Test
func rendererDoesNotRecreateFlattenedContextAfterStructuredFactsExtraction() {
    let renderer = MarkdownMeetingRenderer()
    let context = [
        "Calendar event: OpenAI <> Moderna",
        "Known company: Moderna. Durable account reference."
    ]
    let markdown = renderer.render(
        session: makeSession(title: "OpenAI <> Moderna"),
        segments: [],
        summary: MeetingSummary(overview: "Reviewed rollout coordination."),
        context: context,
        meetingFacts: MeetingFacts(
            title: "OpenAI <> Moderna",
            meetingType: "Customer Workshop",
            organizations: ["Moderna"],
            additionalContext: context,
            confidence: MeetingFactsConfidence(meetingType: 0.92)
        )
    )

    let customerContext = markdown
        .components(separatedBy: "## Customer Context")
        .last?
        .components(separatedBy: "## Transcript")
        .first ?? ""
    #expect(customerContext.components(separatedBy: context[0]).count == 2)
    #expect(customerContext.components(separatedBy: context[1]).count == 2)
    #expect(!customerContext.contains("\(context[0]) \(context[1])"))
}

@Test
func rendererOmitsLowValueFactsAndContextBoilerplate() {
    let renderer = MarkdownMeetingRenderer()
    let facts = MeetingFacts(
        title: "Untitled Meeting",
        meetingType: "General Discussion",
        participants: ["A", "Speaker B"],
        organizations: ["total", "some", "whether"],
        confidence: MeetingFactsConfidence(
            title: 0.2,
            meetingType: 0.35,
            participants: 0.4,
            organizations: 0.62
        )
    )
    let markdown = renderer.render(
        session: makeSession(title: "Untitled Meeting"),
        segments: [
            TranscriptSegment(
                speakerLabel: "A",
                text: "It's coming up with total random bullshit.",
                startTime: 0,
                endTime: 2
            )
        ],
        summary: MeetingSummary(overview: "Ran a short diagnostic recording check."),
        context: [
            "Meeting title: Untitled Meeting",
            "Started: Saturday, May 9, 2026 at 9:57 PM",
            "Audio sources: microphone and system audio",
            "Local context (old-note): # Old Note"
        ],
        meetingFacts: facts
    )

    #expect(!markdown.contains("## Meeting Facts"))
    #expect(!markdown.contains("## Format Focus"))
    #expect(!markdown.contains("## Planning Context"))
    #expect(!markdown.contains("Local context"))
    #expect(!markdown.contains("Organizations: total"))
    #expect(!markdown.contains("Participants: A"))
}

@Test
func classifierPrefersCustomerPitchSignalsOverGenericCustomerContext() {
    let format = MeetingNoteFormat.infer(
        session: makeSession(title: "Acme Customer Review"),
        segments: [
            TranscriptSegment(
                speakerLabel: "Seller",
                text: "The demo covered pricing, buying criteria, and procurement objections.",
                startTime: 0,
                endTime: 8
            )
        ],
        summary: MeetingSummary(overview: "Reviewed customer commercial next steps.")
    )

    #expect(format == .customerPitch)
}

@Test
func classifierMapsIncidentAndTeamMeetingsToSpecificFormats() {
    let incident = MeetingNoteFormat.infer(
        session: makeSession(title: "Checkout SEV Postmortem"),
        segments: [],
        summary: MeetingSummary(overview: "Reviewed outage impact, root cause, and mitigation owners.")
    )
    let team = MeetingNoteFormat.infer(
        session: makeSession(title: "Weekly Sync"),
        segments: [],
        summary: MeetingSummary(overview: "Staff meeting covered announcements and follow-ups.")
    )

    #expect(incident == .incidentReview)
    #expect(team == .teamMeeting)
}

@Test
func classifierMapsHallwayAndPlanningReviewFormats() {
    let hallway = MeetingNoteFormat.infer(
        session: makeSession(title: "Hallway Capture"),
        segments: [
            TranscriptSegment(
                speakerLabel: "Speaker A",
                text: "Quick random capture in the hallway about the launch risk.",
                startTime: 0,
                endTime: 4
            )
        ],
        summary: MeetingSummary(overview: "Captured an ad hoc discussion.")
    )
    let planning = MeetingNoteFormat.infer(
        session: makeSession(title: "Q3 Roadmap Review"),
        segments: [],
        summary: MeetingSummary(overview: "Planning milestones and sprint dependencies.")
    )

    #expect(hallway == .hallwayCapture)
    #expect(planning == .planningReview)
}

@Test
func rendererIncludesParticipantsRisksAndReferences() {
    let renderer = MarkdownMeetingRenderer()
    let markdown = renderer.render(
        session: makeSession(title: "Acme Launch Review"),
        segments: [
            TranscriptSegment(
                speakerLabel: "Dana",
                text: "The customer account has a blocker around pricing.",
                startTime: 0,
                endTime: 4
            )
        ],
        summary: MeetingSummary(
            overview: "Reviewed launch readiness.",
            openQuestions: ["Risk: dependency on legal review."]
        ),
        context: ["Attendees: Dana, Lee", "Project: Barn Owl workspace"]
    )

    #expect(markdown.contains("## Participants"))
    #expect(markdown.contains("- Dana"))
    #expect(markdown.contains("- Lee"))
    #expect(markdown.contains("## Risks"))
    #expect(markdown.contains("blocker around pricing"))
    #expect(markdown.contains("## References"))
    #expect(markdown.contains("Project: Barn Owl workspace"))
}

@Test
func rendererDoesNotTreatTranscriptSpeakerLabelsAsParticipantsWithoutContext() {
    let renderer = MarkdownMeetingRenderer()
    let markdown = renderer.render(
        session: makeSession(title: "Launch Review"),
        segments: [
            TranscriptSegment(
                speakerLabel: "Dana",
                text: "We reviewed the rollout plan.",
                startTime: 0,
                endTime: 2
            ),
            TranscriptSegment(
                speakerLabel: "Lee",
                text: "I will send the follow-up.",
                startTime: 2,
                endTime: 4
            )
        ],
        summary: MeetingSummary(overview: "Reviewed rollout planning.")
    )

    #expect(!markdown.contains("## Participants"))
}

@Test
func externalParticipantNotesAreGenericAndShareSafe() {
    let renderer = ExternalParticipantNotesRenderer()
    let markdown = """
    # Acme Rollout Planning

    Started: May 10, 2026 at 9:00 AM

    ## Summary
    Discussed the Acme rollout plan and pricing risk.

    ## Meeting Facts
    - Meeting type: Customer Workshop
    - Participants: Dana, Lee

    ## Action Items
    - Dana will send the rollout checklist.
    - Lee will confirm the pricing owner.

    ## Open Questions
    - Who owns legal review?

    ## Planning Context
    - Local context (private-note): # Internal account strategy
    - Audio sources: microphone and system audio
    - /Users/example/Library/Application Support/Barn Owl/private.md

    ## Transcript
    **Speaker A**
    This internal transcript should not be copied wholesale.
    """
    let text = renderer.render(
        title: "Acme Rollout Planning",
        startedAt: .init(timeIntervalSince1970: 0),
        meetingFacts: MeetingFacts(
            title: "Acme Rollout Planning",
            participants: ["Dana", "Lee", "Speaker A"],
            customers: ["Acme"],
            projects: ["Rollout"]
        ),
        markdown: markdown
    )

    #expect(text.contains("Acme Rollout Planning"))
    #expect(text.contains("Shareable recap"))
    #expect(!text.contains("Subject:"))
    #expect(!text.contains("Hi all,"))
    #expect(!text.contains("Thanks,"))
    #expect(text.contains("Participants: Dana, Lee"))
    #expect(text.contains("Related: Acme, Rollout"))
    #expect(text.contains("Summary:"))
    #expect(text.contains("Discussed the Acme rollout plan and pricing risk."))
    #expect(text.contains("Action items:"))
    #expect(text.contains("Dana will send the rollout checklist."))
    #expect(text.contains("Open questions:"))
    #expect(!text.contains("##"))
    #expect(!text.contains("Local context"))
    #expect(!text.contains("Audio sources"))
    #expect(!text.contains("/Users/"))
    #expect(!text.contains("internal transcript should not be copied wholesale"))
}

@Test
func externalParticipantNotesOmitLowValueFactsAndPrivateContext() {
    let renderer = ExternalParticipantNotesRenderer()
    let markdown = """
    # Untitled Meeting

    ## Summary
    Speaker A ran a brief diagnostic check.

    ## Meeting Facts
    - Participants: A
    - Organizations: total, some, whether

    ## Context
    - Local context (diagnostic): private context
    - Meeting title: Untitled Meeting
    """
    let text = renderer.render(
        title: "Untitled Meeting",
        startedAt: nil,
        meetingFacts: MeetingFacts(
            title: "Untitled Meeting",
            participants: ["A"],
            organizations: ["total", "some", "whether"]
        ),
        markdown: markdown
    )

    #expect(text.contains("Meeting"))
    #expect(text.contains("Shareable recap"))
    #expect(!text.contains("Subject:"))
    #expect(text.contains("Speaker A ran a brief diagnostic check."))
    #expect(!text.contains("Participants: A"))
    #expect(!text.contains("Related: total"))
    #expect(!text.contains("Local context"))
    #expect(!text.contains("Meeting title:"))
}

@Test
func externalParticipantNotesDoNotFallbackToRawTranscript() {
    let renderer = ExternalParticipantNotesRenderer()
    let text = renderer.render(
        title: "Follow-up",
        startedAt: nil,
        meetingFacts: nil,
        markdown: """
        Speaker A
        We agreed that Dana will send the pricing update tomorrow.
        Additional transcript line that should not all be dumped.
        """
    )

    #expect(text.isEmpty)
    #expect(!text.contains("Additional transcript line that should not all be dumped."))
}

private func makeSession(title: String) -> RecordingSession {
    RecordingSession(
        title: title,
        startedAt: .init(timeIntervalSince1970: 0),
        audioSources: .defaultMeetingCapture
    )
}
