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

/// The raw Microphone authorization status the adapter reads off the system
/// (`AVCaptureDevice.authorizationStatus(for: .audio)`), before it becomes the reducer's
/// vocabulary: the TCC answer's three live shapes. `.restricted` does not survive the adapter —
/// it is a denial the user cannot lift from the pane, and the denied surface is the honest
/// rendering for it (`MicrophoneAuthorization.status(from:)` maps it there).
public enum MicrophoneAuthorizationStatus: Sendable, Equatable {
    /// The first request has not been made.
    case notDetermined
    /// The system's answer is no.
    case denied
    /// The system's answer is yes.
    case granted
}

/// The injected-read seam the onboarding flow's reducer consumes (`first-run-permissions` A2):
/// a plain struct of current statuses, fed by the wiring from the adapters — the AX trust `Bool`
/// and the tap-armed fact on one side (`AXSource.isProcessTrusted()` and
/// `TapHealth != .permissionMissing`), `MicrophoneAuthorization.authorizationStatus()` on the
/// other.
///
/// Stdlib-only, like the rest of `VoccaCore` (`CoreBoundaryTests`): this file holds no read and
/// no system call — the struct and the two pure mappings below are the flow's entry and refresh
/// inputs, fully headless-testable, and the decisions that turn raw facts into states live here,
/// exactly where the test suite pins them (never in the reducer, whose vocabulary stays the two
/// A1 enums).
public struct OnboardingPermissionReads: Sendable, Equatable {

    /// The Accessibility permission's current state — the M5c three states, mapped from the raw
    /// facts by ``accessibility(trusted:tapArmed:)``.
    public var accessibility: OnboardingAccessibility

    /// The Microphone permission's current state, mapped from the raw status by
    /// ``microphone(status:)``.
    public var microphone: OnboardingMicrophone

    public init(accessibility: OnboardingAccessibility, microphone: OnboardingMicrophone) {
        self.accessibility = accessibility
        self.microphone = microphone
    }

    /// The pure mapping from the two raw facts to the reducer's Accessibility vocabulary (M5c):
    /// `notGranted` = no trust — whatever the tap's health says, a dead tap cannot fabricate a
    /// grant; `grantedNotArmed` = trust without a live tap — the restart-required middle state,
    /// the one that carries the [ Restart Vocca ] path (M3); `armed` = trust and a live tap.
    ///
    /// The `tapArmed` fact comes from `TapHealth != .permissionMissing`; the wiring feeds it in
    /// (A5). This seam only defines the mapping — the mapping's home is pinned by
    /// `OnboardingPermissionReadsTests`.
    public static func accessibility(trusted: Bool, tapArmed: Bool) -> OnboardingAccessibility {
        guard trusted else { return .notGranted }
        return tapArmed ? .armed : .grantedNotArmed
    }

    /// The pure mapping from the raw TCC status to the reducer's Microphone vocabulary: the
    /// three raw states ARE the three reducer states, translated in the one place the adapter's
    /// answer becomes a flow fact.
    public static func microphone(status: MicrophoneAuthorizationStatus) -> OnboardingMicrophone {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .granted:
            return .granted
        }
    }
}