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

// THE ENGINE-START MEASUREMENT, WHICH THE PRD HAS REQUIRED SINCE C1 WAS PLANNED
//
// `prd.md:280` — *"the engine-start cost M23 introduces must be measured in C1 so C7 optimizes
// against data"* — and `spec.md` A7, *"Engine-start latency, measured and recorded ... ❌ manual,
// but REQUIRED"*. Two aspects shipped on top of the assumption that the cost is "milliseconds"
// (`HotkeyEventSource.receive(_:)`'s doc says so in as many words, and so does
// `SessionMachine.isOpeningTheMicrophone`'s). Nobody had taken the number.
//
// It is not a package target, for the reason `Tools/TimerProbe` is not: everything under `Sources/`
// is inside the zero-network coverage guard, and — more to the point here — this opens the
// microphone. Nothing in `swift test` may do that. `Scripts/test-with-floor.sh` compiles it so it
// cannot bit-rot, which is the lesson the timer harness paid for.
//
// WHAT IT MEASURES, AND WHAT IT REFUSES TO REPORT
//
// It measures `AVAudioEngine.start()` on a graph shaped like the one Phase 4 will ship: the input
// node feeding an `AVAudioSinkNode`, at the input node's own output format. It does NOT measure
// Vocca's adapter, because at the time this was written there was no adapter — Phase 4 builds it.
// When it exists, this harness is where it should be measured, and the number below is its baseline.
//
// **Every row verifies the state it claims to have measured, and an unverified row is excluded from
// the summary and fails the run.** That rule is here because `hotkey-source` paid for it: a
// measurement of a state that was never entered is worse than no measurement, because it closes an
// open question with a number that means nothing. The failure is not hypothetical here — an engine
// with an enabled input node and *nothing attached to it* starts happily, reports `isRunning ==
// true`, takes the same ~110 ms, and delivers not one sample. A harness that timed `start()` and
// stopped there would have reported that configuration's latency as though audio had been captured.
//
// So a row counts only if all four hold:
//
//   1. `AVCaptureDevice.authorizationStatus(for: .audio) == .authorized` — checked once, before any
//      measurement. Without the grant the engine still starts and the sink still fires; the samples
//      are just silence. That is a no-op wearing a measurement's clothes.
//   2. `engine.isRunning` after `start()` returned.
//   3. The input node's output format reports a non-zero sample rate and channel count — a disabled
//      or absent input reports 0 Hz, and every downstream claim about the format would be a claim
//      about nothing.
//   4. The realtime sink block actually ran, with frames, and delivered at least half the samples
//      the hold duration implies. "At least one callback" is too weak: a device that fires once and
//      stalls satisfies it.

import AVFoundation
import Darwin
import Foundation
import Synchronization

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Realtime-side counters

// Global and atomic, for the same reason `AudioRingBuffer` is: the sink block is the realtime thread,
// and a lock, an allocation or an ARC retain in it is the defect this project spends a lint pass
// preventing. `Atomic` is the only mechanism permitted on that side, so the harness uses it too —
// a probe that measured a realtime path while violating its discipline would be measuring something
// Vocca will never run.
let framesDelivered = Atomic<Int>(0)
let sinkCallbacks = Atomic<Int>(0)
let firstAudioAt = Atomic<UInt64>(0)

@inline(__always) func monotonicNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

@inline(__always) func milliseconds(_ from: UInt64, _ to: UInt64) -> Double {
    to >= from ? Double(to - from) / 1_000_000 : -1
}

// MARK: - Statistics

struct Summary {
    let count: Int
    let median: Double
    let p90: Double
    let p99: Double
    let worst: Double
    let best: Double

    /// Nearest-rank percentiles over the sorted sample, which is what a reader of "p99" expects and
    /// is the only definition that never interpolates a value no run produced.
    ///
    /// **p99 over fewer than 100 samples is the maximum wearing a percentile's name**, so the caller
    /// is told the count beside it and every printed table says how many rows it rests on.
    init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func rank(_ quantile: Double) -> Double {
            let index = Int((quantile * Double(sorted.count)).rounded(.up)) - 1
            return sorted[min(max(index, 0), sorted.count - 1)]
        }
        count = sorted.count
        median = rank(0.5)
        p90 = rank(0.9)
        p99 = rank(0.99)
        worst = sorted[sorted.count - 1]
        best = sorted[0]
    }

    func line(_ label: String) -> String {
        String(
            format: "%-34@ n=%-4d median %8.2f  p90 %8.2f  p99 %8.2f  worst %8.2f  best %8.2f",
            label as NSString, count, median, p90, p99, worst, best)
    }
}

// MARK: - Devices

/// One CoreAudio input device, as much of it as is worth printing beside a latency number.
struct InputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: String
    let sampleRate: Double
    let channels: UInt32
}

func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString? = nil
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return "?" }
    return value as String
}

func transportName(_ device: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var raw: UInt32 = 0
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &raw) == noErr else {
        return "?"
    }
    switch raw {
    case kAudioDeviceTransportTypeBuiltIn: return "built-in"
    case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    case kAudioDeviceTransportTypeDisplayPort: return "displayport"
    case kAudioDeviceTransportTypeHDMI: return "hdmi"
    case kAudioDeviceTransportTypeAirPlay: return "airplay"
    case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
    default: return "other(\(raw))"
    }
}

func inputChannelCount(_ device: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
        return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(
        raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + $1.mNumberChannels }
}

func nominalSampleRate(_ device: AudioDeviceID) -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Double>.size)
    var rate: Double = 0
    _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
    return rate
}

func allInputDevices() -> [InputDevice] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
    else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
    else { return [] }
    return
        ids
        .filter { inputChannelCount($0) > 0 }
        .map {
            InputDevice(
                id: $0, uid: stringProperty($0, kAudioDevicePropertyDeviceUID),
                name: stringProperty($0, kAudioObjectPropertyName), transport: transportName($0),
                sampleRate: nominalSampleRate($0), channels: inputChannelCount($0))
        }
}

func defaultInputDevice() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var device: AudioDeviceID = 0
    _ = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return device
}

/// Binds the engine's input unit to `device` **for this engine only**.
///
/// Deliberately not `kAudioHardwarePropertyDefaultInputDevice`: that would change the input device
/// for every application on the machine, and a measurement harness must not leave the operator's
/// system rearranged. The read-back is not decoration — a set that silently does not take would
/// otherwise be reported as a measurement of the device that was asked for.
func bindInput(_ engine: AVAudioEngine, to device: AudioDeviceID) -> AudioDeviceID? {
    guard let unit = engine.inputNode.audioUnit else { return nil }
    var requested = device
    let status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &requested,
        UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else { return nil }
    var bound: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard
        AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &bound, &size)
            == noErr
    else { return nil }
    return bound
}

// MARK: - The measurement

/// When `prepare()` is called, which is the whole of `prd.md` M23's stated mitigation and
/// `spec.md` open question 3.
enum PreparePlacement: String {
    /// Never. The control.
    case none
    /// Immediately after `stop()`, at idle, with nobody waiting — M23's own words.
    case after
    /// Immediately before `start()`, on the press path, where its cost is the user's to pay.
    case before
}

struct Row {
    let start: Double
    let stop: Double
    let prepare: Double
    let firstAudioAfterStart: Double
    let frames: Int
    let callbacks: Int
    let valid: Bool
    let invalidBecause: String
}

/// One press-and-release, timed and verified.
///
/// The graph is built once by the caller and reused across every row, because that is what M23
/// mandates — *"keeping engine/sink/converter/buffer allocated for the app lifetime; only
/// `start()`/`stop()` per press, never a graph rebuild"* — and measuring a rebuild would measure a
/// shape Vocca has already decided not to ship.
func measureOneCycle(
    engine: AVAudioEngine, format: AVAudioFormat, prepare: PreparePlacement, hold: Double
) -> Row {
    var prepareCost = 0.0
    if prepare == .before {
        let mark = monotonicNanoseconds()
        engine.prepare()
        prepareCost = milliseconds(mark, monotonicNanoseconds())
    }

    framesDelivered.store(0, ordering: .releasing)
    sinkCallbacks.store(0, ordering: .releasing)
    firstAudioAt.store(0, ordering: .releasing)

    let startedAt = monotonicNanoseconds()
    do {
        try engine.start()
    } catch {
        return Row(
            start: -1, stop: -1, prepare: prepareCost, firstAudioAfterStart: -1, frames: 0,
            callbacks: 0, valid: false, invalidBecause: "start() threw: \(error)")
    }
    let returnedAt = monotonicNanoseconds()

    let running = engine.isRunning
    let liveFormat = engine.inputNode.outputFormat(forBus: 0)

    Thread.sleep(forTimeInterval: hold)

    let frames = framesDelivered.load(ordering: .acquiring)
    let callbacks = sinkCallbacks.load(ordering: .acquiring)
    let firstAudio = firstAudioAt.load(ordering: .acquiring)

    let stoppedAt = monotonicNanoseconds()
    engine.stop()
    let stopCost = milliseconds(stoppedAt, monotonicNanoseconds())

    if prepare == .after {
        let mark = monotonicNanoseconds()
        engine.prepare()
        prepareCost = milliseconds(mark, monotonicNanoseconds())
    }

    // Half of what the hold implies. A stricter bound would fail on the genuine start-up gap the
    // measurement is partly about; a weaker one ("at least one callback") passes for a device that
    // fires once and stalls, which is a state worth failing on.
    let expected = Int(hold * format.sampleRate) / 2
    var reason = ""
    if !running {
        reason = "engine.isRunning == false after start() returned"
    } else if liveFormat.sampleRate <= 0 || liveFormat.channelCount == 0 {
        reason = "input node reports \(liveFormat.sampleRate) Hz / \(liveFormat.channelCount) ch"
    } else if callbacks == 0 {
        reason = "the realtime sink block never ran"
    } else if frames < expected {
        reason = "only \(frames) frames in \(hold)s, expected at least \(expected)"
    }

    return Row(
        start: milliseconds(startedAt, returnedAt), stop: stopCost, prepare: prepareCost,
        firstAudioAfterStart: firstAudio == 0 ? -1 : milliseconds(returnedAt, firstAudio),
        frames: frames, callbacks: callbacks, valid: reason.isEmpty, invalidBecause: reason)
}

// MARK: - Process state

/// Whether this process is under darwin-background task suppression, printed beside every run.
///
/// The precedent is `Tools/TimerProbe`, whose first version measured an unsuppressed process and
/// concluded something about a suppressed one. A latency measured while throttled and one measured
/// while not are different numbers, and which of the two was taken must not be a guess.
func suppressionState() -> String {
    errno = 0
    let priority = getpriority(PRIO_DARWIN_PROCESS, 0)
    if priority == -1 && errno != 0 { return "unknown (getpriority: \(errno))" }
    return priority == 0 ? "not suppressed" : "SUPPRESSED (priority \(priority))"
}

func authorizationDescription(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

// MARK: - Command line

var arguments = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

if flag("--build-only") {
    print("Tools/EngineStartProbe compiles.")
    exit(0)
}

let listDevices = flag("--devices")
let iterations = Int(option("--iterations") ?? "") ?? 120
let idle = Double(option("--idle") ?? "") ?? 1.0
let hold = Double(option("--hold") ?? "") ?? 0.15
let deviceQuery = option("--device")
let preparePlacement = PreparePlacement(rawValue: option("--prepare") ?? "after") ?? .after
let emitCSV = flag("--csv")
let label = option("--label") ?? "start()"

guard arguments.isEmpty else {
    FileHandle.standardError.write(Data("error: unrecognised arguments: \(arguments)\n".utf8))
    exit(2)
}

// MARK: - Run

let devices = allInputDevices()

if listDevices {
    print("Input devices (\(devices.count)):")
    let defaultDevice = defaultInputDevice()
    for device in devices {
        print(
            String(
                format: "  %@ %-28@ %-12@ %8.0f Hz  %d ch   uid=%@",
                device.id == defaultDevice ? "*" : " ", device.name as NSString,
                device.transport as NSString, device.sampleRate, device.channels,
                device.uid as NSString))
    }
    print("  (* = system default input)")
    exit(0)
}

// Checked before anything is timed, and fatal. Without the grant the engine starts, the sink fires,
// and every sample is zero — a measurement of a microphone that was never opened.
let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
guard authorization == .authorized else {
    FileHandle.standardError.write(
        Data(
            """
            error: microphone authorization is \(authorizationDescription(authorization)), not authorized.

            The engine would still start and the sink block would still run — with silence — so any
            number taken now would be a measurement of a microphone that was never opened. Grant the
            calling application (the terminal, or the bundled probe) microphone access in System
            Settings > Privacy & Security > Microphone and run this again.

            """.utf8))
    exit(3)
}

let engine = AVAudioEngine()
// Touching `inputNode` is what enables input, and therefore what makes this process a candidate for
// the orange indicator M23 exists to keep dark. It is done once, here, for the app lifetime — the
// shape M23 mandates.
let inputNode = engine.inputNode

var boundDevice = defaultInputDevice()
if let deviceQuery {
    guard
        let match = devices.first(where: {
            $0.name.localizedCaseInsensitiveContains(deviceQuery)
                || $0.uid.localizedCaseInsensitiveContains(deviceQuery)
        })
    else {
        FileHandle.standardError.write(
            Data("error: no input device matching '\(deviceQuery)'. Try --devices.\n".utf8))
        exit(2)
    }
    guard let bound = bindInput(engine, to: match.id), bound == match.id else {
        FileHandle.standardError.write(
            Data(
                "error: the input unit did not accept device '\(match.name)'. Refusing to report a number for a device that was not bound.\n"
                    .utf8))
        exit(4)
    }
    boundDevice = bound
}

let format = inputNode.outputFormat(forBus: 0)
guard format.sampleRate > 0, format.channelCount > 0 else {
    FileHandle.standardError.write(
        Data("error: input node reports \(format.sampleRate) Hz — there is no input to measure.\n".utf8)
    )
    exit(5)
}

// The shape Phase 4 will ship: the sink node on the input chain, connected at the input node's OWN
// output format, because the sink node does not convert. The block does nothing but count — no
// allocation, no locks, no ARC — for the same reason the shipped one will do nothing but write into
// the ring.
let sink = AVAudioSinkNode { _, frameCount, _ in
    if sinkCallbacks.load(ordering: .acquiring) == 0 {
        firstAudioAt.store(monotonicNanoseconds(), ordering: .releasing)
    }
    _ = sinkCallbacks.wrappingAdd(1, ordering: .acquiringAndReleasing)
    _ = framesDelivered.wrappingAdd(Int(frameCount), ordering: .acquiringAndReleasing)
    return noErr
}
engine.attach(sink)
engine.connect(inputNode, to: sink, format: format)

let boundName =
    devices.first(where: { $0.id == boundDevice }).map { "\($0.name) [\($0.transport)]" } ?? "?"

if !emitCSV {
    print("Vocca engine-start probe")
    print("  device      : \(boundName)")
    print(
        "  format      : \(format.sampleRate) Hz, \(format.channelCount) ch, interleaved=\(format.isInterleaved)"
    )
    print("  prepare()   : \(preparePlacement.rawValue)")
    print("  idle gap    : \(idle) s before each start")
    print("  hold        : \(hold) s per session")
    print("  iterations  : \(iterations)")
    print("  suppression : \(suppressionState())")
    print("  mic access  : \(authorizationDescription(authorization))")
    print("")
}

var starts: [Double] = []
var stops: [Double] = []
var firstAudio: [Double] = []
var prepares: [Double] = []
var invalid: [String] = []

for iteration in 0..<iterations {
    if idle > 0 { Thread.sleep(forTimeInterval: idle) }
    let row = measureOneCycle(
        engine: engine, format: format, prepare: preparePlacement, hold: hold)

    if emitCSV {
        print(
            String(
                format: "%d,%.4f,%.4f,%.4f,%.4f,%d,%d,%@,%@", iteration, row.start, row.stop,
                row.prepare, row.firstAudioAfterStart, row.frames, row.callbacks,
                row.valid ? "valid" : "INVALID", row.invalidBecause as NSString))
    }

    guard row.valid else {
        invalid.append("iteration \(iteration): \(row.invalidBecause)")
        continue
    }
    starts.append(row.start)
    stops.append(row.stop)
    prepares.append(row.prepare)
    if row.firstAudioAfterStart >= 0 { firstAudio.append(row.firstAudioAfterStart) }
}

if !emitCSV {
    print("Milliseconds. \(label), \(boundName), prepare=\(preparePlacement.rawValue), idle=\(idle)s")
    for (name, samples) in [
        ("AVAudioEngine.start()", starts), ("AVAudioEngine.stop()", stops),
        ("prepare()", prepares), ("first realtime callback after start()", firstAudio),
    ] {
        if let summary = Summary(samples) { print("  " + summary.line(name)) }
    }
    print("")
    print("  suppression at end : \(suppressionState())")
    print("  valid rows         : \(starts.count) of \(iterations)")
    if invalid.isEmpty {
        print("  invalid rows       : 0")
    } else {
        print("  invalid rows       : \(invalid.count) — NOT included above")
        for note in invalid.prefix(10) { print("      \(note)") }
    }
}

// A run with any unverified row exits non-zero, so a measurement that quietly stopped measuring
// cannot be pasted into a document as though it were evidence.
if !invalid.isEmpty || starts.isEmpty { exit(6) }
