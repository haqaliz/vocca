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

public enum MatrixEvidenceEvent: Sendable, Equatable {
    case sessionOpened(mode: SessionMode)
    case delivery(targetBundleID: String, result: InjectionResult)
}

public enum MatrixEvidenceLine {
    public static func format(_ event: MatrixEvidenceEvent) -> String {
        switch event {
        case .sessionOpened(let mode):
            return "session opened mode=\(modeSpelling(of: mode))"
        case .delivery(let targetBundleID, let result):
            let attempted = result.attempted.map(\.rawValue).joined(separator: ", ")
            return "delivery target=\(targetBundleID) rung=\(result.rung.rawValue) attempted: [\(attempted)] verified=\(result.verified)"
        }
    }

    private static func modeSpelling(of mode: SessionMode) -> String {
        switch mode {
        case .dictation: return "dictation"
        case .conversing: return "conversing"
        }
    }
}