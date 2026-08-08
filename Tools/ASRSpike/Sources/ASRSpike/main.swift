// Copyright 2026 The Vocca Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

@preconcurrency import AVFoundation
import Darwin
import Foundation
import FluidAudio

/// The F1 spike probe: answers the PRD F1 questions with numbers, on a macos-15 hosted runner
/// and on a developer's Mac. It is throwaway code — its findings land in
/// `docs/planning/local-asr/parakeet-engine/spike_20260809.md`, and nothing in the product
/// depends on it.
///
/// It deliberately exercises the SDK's OWN download path in `--mode sdk-download` — the
/// product will never do that (``ModelHub.offlineMode`` + the Vocca ``ModelDownloader`` are
/// the shipped path) — because the spike's question is what the SDK does and how long it
/// takes, before any of our machinery gets in the way.
///
/// Usage:
///   ASRSpike --audio <16k-mono-wav> [--mode sdk-download | --mode offline --model-dir <dir>]
///
/// Compiled with -strict-concurrency=complete on purpose: one of the spike's findings is
/// whether the SDK's types are holdable in a Swift 6 actor.

// MARK: - Environment

private func printEnvironment() {
    var chipName = String(decoding: hardwareValue("machdep.cpu.brand_string"), as: UTF8.self)
    if chipName.isEmpty {
        chipName = String(decoding: hardwareValue("hw.machine"), as: UTF8.self)
    }
    let processInfo = ProcessInfo.processInfo
    print("== environment ==")
    print("macOS \(processInfo.operatingSystemVersionString)")
    print("chip: \(chipName)")
    print("physical memory: \(processInfo.physicalMemory / 1_048_576) MiB")
    print("swift: \(swiftVersion)")
}

/// Reads a sysctl string value without the deprecated cString initializers.
private func hardwareValue(_ name: String) -> [UInt8] {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return [] }
    var bytes = [UInt8](repeating: 0, count: size)
    sysctlbyname(name, &bytes, &size, nil, 0)
    return bytes
}

private var swiftVersion: String {
    #if compiler(>=6.0)
    return "6.x"
    #else
    return "<6"
    #endif
}

// MARK: - Audio

/// Reads any WAV the fixture suite ships into 16 kHz mono Float32 samples — the interchange
/// format — via AVFoundation. The probe is not the product; convenience wins here.
private func readSamples16kMono(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw SpikeError.cannotAllocateBuffer
    }
    try file.read(into: buffer)

    let converter = AVAudioConverter(
        from: file.processingFormat,
        to: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!)
    guard let converter else { throw SpikeError.cannotCreateConverter }
    let outputFormat = converter.outputFormat
    let ratio = outputFormat.sampleRate / file.processingFormat.sampleRate
    let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
        throw SpikeError.cannotAllocateBuffer
    }
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
    }
    guard status != .error else { throw SpikeError.conversionFailed(error?.localizedDescription ?? "unknown") }
    guard let channels = output.floatChannelData else { throw SpikeError.conversionFailed("no float data") }
    return Array(UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
}

private enum SpikeError: Error, CustomStringConvertible {
    case cannotAllocateBuffer
    case cannotCreateConverter
    case conversionFailed(String)
    case noAudioPath
    case modelMissing

    var description: String {
        switch self {
        case .cannotAllocateBuffer: return "could not allocate PCM buffer"
        case .cannotCreateConverter: return "could not create AVAudioConverter"
        case .conversionFailed(let detail): return "conversion failed: \(detail)"
        case .noAudioPath: return "missing --audio <path>"
        case .modelMissing: return "offline mode: model directory has no loadable model"
        }
    }
}

// MARK: - Timing

private struct Stopwatch {
    private let start = ContinuousClock.now
    private let name: String
    init(_ name: String) { self.name = name }
    func report() {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("⏱  \(name): \(String(format: "%.3f", seconds)) s")
    }
    func elapsedSeconds() -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

private func peakRSSMiB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

// MARK: - Main

@main
struct ASRSpikeMain {
    static func main() async throws {
        printEnvironment()

        let arguments = ProcessInfo.processInfo.arguments
        guard let audioIndex = arguments.firstIndex(of: "--audio"), arguments.count > audioIndex + 1 else {
            throw SpikeError.noAudioPath
        }
        let audioURL = URL(fileURLWithPath: arguments[audioIndex + 1])
        let samples = try readSamples16kMono(from: audioURL)
        print("audio: \(audioURL.lastPathComponent), \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / 16_000)) s at 16 kHz)")

        let mode: String
        if let modeIndex = arguments.firstIndex(of: "--mode"), arguments.count > modeIndex + 1 {
            mode = arguments[modeIndex + 1]
        } else {
            mode = "sdk-download"
        }

        let offlineReadableBefore = ModelHub.offlineMode
        print("ModelHub.offlineMode readable: initial value == \(offlineReadableBefore)")

        // The Sendability finding, compiled under -strict-concurrency=complete: can the SDK's
        // manager be held by a Swift 6 actor? The probe holds it exactly the way the adapter
        // would — as a stored property — and the compiler answers.
        var manager: AsrManager? = nil

        switch mode {
        case "sdk-download":
            let downloadWatch = Stopwatch("model downloadAndLoad(.v3)")
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            downloadWatch.report()
            print("model download+load complete; peak RSS \(String(format: "%.0f", peakRSSMiB())) MiB")

            let managerWatch = Stopwatch("AsrManager + loadModels")
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            manager = asr
            managerWatch.report()

        case "offline":
            ModelHub.offlineMode = true
            let after = ModelHub.offlineMode
            print("ModelHub.offlineMode after setting true == \(after)")
            guard let dirIndex = arguments.firstIndex(of: "--model-dir"), arguments.count > dirIndex + 1 else {
                throw SpikeError.modelMissing
            }
            let modelDir = URL(fileURLWithPath: arguments[dirIndex + 1])
            let loadWatch = Stopwatch("AsrModels.load(from: manual dir)")
            let models = try await AsrModels.load(from: modelDir, configuration: nil)
            loadWatch.report()

            let managerWatch = Stopwatch("AsrManager + loadModels")
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            manager = asr
            managerWatch.report()

        default:
            print("unknown mode \(mode); using sdk-download")
        }

        guard let asr = manager else { throw SpikeError.modelMissing }

        var decoderState = try TdtDecoderState()
        let transcribeWatch = Stopwatch("transcribe(\(samples.count) samples)")
        let result = try await asr.transcribe(samples, decoderState: &decoderState, language: nil)
        transcribeWatch.report()

        print("transcript: \(result.text)")
        let audioSeconds = Double(samples.count) / 16_000
        print("audio: \(String(format: "%.2f", audioSeconds)) s · transcribe: \(String(format: "%.3f", transcribeWatch.elapsedSeconds())) s · RTF \(String(format: "%.4f", transcribeWatch.elapsedSeconds() / audioSeconds))")
        print("peak RSS \(String(format: "%.0f", peakRSSMiB())) MiB")
        print("== spike probe done ==")
    }
}
