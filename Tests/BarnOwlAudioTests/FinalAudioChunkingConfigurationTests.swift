import BarnOwlAudio
import Testing

@Test
func finalChunkingUsesSixtySecondChunksWithFiveSecondOverlap() {
    let configuration = FinalAudioChunkingConfiguration.barnOwlFinalTranscription

    #expect(configuration.chunkDuration == 60)
    #expect(configuration.overlapDuration == 5)
    #expect(configuration.strideDuration == 55)
    #expect((0...3).map(configuration.startTimeOffset(forSequenceNumber:)) == [0, 55, 110, 165])
}
