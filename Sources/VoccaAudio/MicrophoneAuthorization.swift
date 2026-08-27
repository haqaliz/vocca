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

import AVFoundation
import VoccaCore

/// **The microphone-permission adapter — the third `VoccaAudio` file permitted to name
/// AVFoundation** (the `AudioFormatConverterTests` expected-importer list, amended in the same
/// commit — the `first-run-permissions` PRD's R6 row, planned rather than discovered).
///
/// The flow's two reads (PRD M5/M5b): the authorization status and the request that makes the
/// TCC prompt land at the moment the flow controls. Translation only — no policy: the 4-state
/// system answer maps to the raw 3-state status by the one judgment row (`.restricted` is a
/// denial the user cannot lift, so it is `.denied` — the honest surface), and what the statuses
/// *mean* for the flow is mapped above the seam, in ``OnboardingPermissionReads``
/// (`VoccaCore`), where it is tested headlessly.
///
/// Executed by nothing in CI (no TCC grant on a hosted runner, and the prompt is a
/// window-server interaction); the pure mapping ``status(from:)`` is the tested half.
public enum MicrophoneAuthorization {

    /// The system's 4-state answer → the raw 3-state status. `.restricted` (parental controls /
    /// MDM) is a denial the user cannot lift from the pane, so it reads as `.denied` — the M2
    /// denial surface is the honest rendering for it. `@unknown default` stays `.denied`: a
    /// future system answer must never read as granted.
    public static func status(from system: AVAuthorizationStatus) -> MicrophoneAuthorizationStatus {
        switch system {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .denied
        case .denied:
            return .denied
        case .authorized:
            return .granted
        @unknown default:
            return .denied
        }
    }

    /// The current authorization status, read fresh. Translation only.
    public static func authorizationStatus() -> MicrophoneAuthorizationStatus {
        status(from: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// The request that lands the TCC prompt (`AVCaptureDevice.requestAccess(for: .audio)`),
    /// answered as the raw `Bool`. Translation only: the meaning of the answer is the reducer's
    /// (`OnboardingAction.microphoneRequestResulted`, M5b).
    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}