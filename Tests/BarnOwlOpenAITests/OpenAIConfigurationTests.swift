import BarnOwlOpenAI
import Testing

@Test
func apiKeyLoadsFromInjectedEnvironment() throws {
    let configuration = try OpenAIConfiguration.fromEnvironment([
        "OPENAI_API_KEY": "test-key"
    ])

    #expect(configuration.apiKey == "test-key")
}

@Test
func missingAPIKeyThrows() {
    #expect(throws: OpenAIConfigurationError.missingAPIKey) {
        try OpenAIConfiguration.fromEnvironment([:])
    }
}

@Test
func modelCatalogKeepsPipelinesSeparate() {
    #expect(OpenAIModelCatalog.liveTranscription != OpenAIModelCatalog.finalDiarization)
    #expect(OpenAIModelCatalog.liveTranscription != OpenAIModelCatalog.realtimeVoice)
    #expect(OpenAIModelCatalog.liveTranscription == "gpt-4o-transcribe")
    #expect(OpenAIModelCatalog.realtimeVoice == "gpt-realtime-2")
    #expect(OpenAIModelCatalog.realtimeReasoning == "gpt-realtime-2")
    #expect(OpenAIModelCatalog.finalDiarization == "gpt-4o-transcribe-diarize")
    #expect(OpenAIModelCatalog.transcriptQA == "gpt-5.5")
    #expect(OpenAIModelCatalog.summaryAndActions == "gpt-5.5")
}
