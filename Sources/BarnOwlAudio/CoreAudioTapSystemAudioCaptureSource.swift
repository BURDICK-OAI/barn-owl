import AVFoundation
import AudioToolbox
import BarnOwlCore
import Foundation

public protocol SystemAudioPCMBufferWriter: AnyObject {
    func writeSystemAudioBuffer(_ buffer: AVAudioPCMBuffer) throws
}

public final class CoreAudioTapSystemAudioCaptureSource: SystemAudioSource, @unchecked Sendable {
    private let writer: any SystemAudioPCMBufferWriter
    private let sampleQueue: DispatchQueue
    private let excludesCurrentProcessAudio: Bool
    private let stateLock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var isRunning = false

    public init(
        writer: any SystemAudioPCMBufferWriter,
        sampleQueue: DispatchQueue = DispatchQueue(label: "com.barnowl.core-audio-tap.samples", qos: .userInitiated),
        excludesCurrentProcessAudio: Bool = true
    ) {
        self.writer = writer
        self.sampleQueue = sampleQueue
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
    }

    public func requestSystemAudioPermission() async throws {
        guard #available(macOS 14.2, *) else {
            throw AudioCaptureError.sourceUnavailable
        }
    }

    public func startSystemAudioCapture(configuration: AudioSourceConfiguration) async throws {
        guard configuration.capturesSystemAudio else {
            return
        }

        guard #available(macOS 14.2, *) else {
            throw AudioCaptureError.sourceUnavailable
        }

        try markStarting()

        do {
            try startCoreAudioTap()
            stateLock.withLock {
                isRunning = true
            }
        } catch {
            await stopSystemAudioCapture()
            throw mapCoreAudioError(error)
        }
    }

    public func stopSystemAudioCapture() async {
        let resources = stateLock.withLock {
            let current = (aggregateDeviceID, deviceProcID, tapID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            deviceProcID = nil
            tapID = AudioObjectID(kAudioObjectUnknown)
            tapFormat = nil
            isRunning = false
            return current
        }

        let aggregate = resources.0
        let procID = resources.1
        let tap = resources.2

        if aggregate != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                _ = AudioDeviceStop(aggregate, procID)
                _ = AudioDeviceDestroyIOProcID(aggregate, procID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregate)
        }

        if tap != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tap)
        }
    }

    @available(macOS 14.2, *)
    private func startCoreAudioTap() throws {
        let excludedProcesses = excludesCurrentProcessAudio
            ? (try? [Self.currentProcessAudioObjectID()]) ?? []
            : []

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        tapDescription.uuid = UUID()
        tapDescription.name = "Barn Owl System Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr else {
            throw CoreAudioTapError.operationFailed("create process tap", status)
        }

        let outputDeviceID = try Self.defaultSystemOutputDeviceID()
        let outputDeviceUID = try Self.deviceUID(for: outputDeviceID)
        let aggregateUID = UUID().uuidString

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Barn Owl System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputDeviceUID
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        var streamDescription = try Self.audioTapStreamDescription(for: newTapID)
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CoreAudioTapError.invalidFormat
        }

        var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateDeviceID)
        guard status == noErr else {
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw CoreAudioTapError.operationFailed("create aggregate device", status)
        }

        var newProcID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
            else {
                return
            }

            try? writer.writeSystemAudioBuffer(buffer)
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggregateDeviceID, sampleQueue, ioBlock)
        guard status == noErr else {
            _ = AudioHardwareDestroyAggregateDevice(newAggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw CoreAudioTapError.operationFailed("create device IO proc", status)
        }

        status = AudioDeviceStart(newAggregateDeviceID, newProcID)
        guard status == noErr else {
            if let newProcID {
                _ = AudioDeviceDestroyIOProcID(newAggregateDeviceID, newProcID)
            }
            _ = AudioHardwareDestroyAggregateDevice(newAggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw CoreAudioTapError.operationFailed("start aggregate device", status)
        }

        stateLock.withLock {
            tapID = newTapID
            aggregateDeviceID = newAggregateDeviceID
            deviceProcID = newProcID
            tapFormat = format
        }
    }

    private func markStarting() throws {
        try stateLock.withLock {
            guard !isRunning else {
                throw AudioCaptureError.alreadyRunning
            }
            isRunning = true
        }
    }

    private func mapCoreAudioError(_ error: Error) -> AudioCaptureError {
        if let audioCaptureError = error as? AudioCaptureError {
            return audioCaptureError
        }

        guard let tapError = error as? CoreAudioTapError else {
            return .sourceUnavailable
        }

        switch tapError {
        case .invalidFormat:
            return .sourceUnavailable
        case .operationFailed(_, let status):
            return Self.permissionDeniedStatuses.contains(status) ? .permissionDenied : .sourceUnavailable
        }
    }

    private static let permissionDeniedStatuses: Set<OSStatus> = [
        OSStatus(kAudioHardwareIllegalOperationError),
        OSStatus(kAudioComponentErr_NotPermitted)
    ]

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func currentProcessAudioObjectID() throws -> AudioObjectID {
        var pid = getpid()
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = withUnsafeMutablePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &size,
                &processObjectID
            )
        }

        guard status == noErr, processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioTapError.operationFailed("translate current process", status)
        }

        return processObjectID
    }

    private static func defaultSystemOutputDeviceID() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = propertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw CoreAudioTapError.operationFailed("read default output device", status)
        }

        return deviceID
    }

    private static func deviceUID(for deviceID: AudioDeviceID) throws -> String {
        var uid = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = propertyAddress(kAudioDevicePropertyDeviceUID)
        let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, uidPointer)
        }

        guard status == noErr else {
            throw CoreAudioTapError.operationFailed("read output device uid", status)
        }

        return uid as String
    }

    private static func audioTapStreamDescription(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = propertyAddress(kAudioTapPropertyFormat)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription)
        guard status == noErr else {
            throw CoreAudioTapError.operationFailed("read tap format", status)
        }

        return streamDescription
    }
}

private enum CoreAudioTapError: Error, Equatable {
    case invalidFormat
    case operationFailed(String, OSStatus)
}
