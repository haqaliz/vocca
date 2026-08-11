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

import Foundation
import Synchronization
import VoccaCore

/// The first ``ModelDownloadSession`` implementation: the store's own machinery, behind the
/// seam `VoccaUI` consumes — so the download window never sees a store type.
///
/// ``start()`` drives ``ModelStore/downloadIfMissing(manifest:transport:onProgress:)`` and
/// feeds the event stream; ``cancel()`` cancels the driving task. The store's
/// ``ModelDownloadError/interrupted`` maps to ``ModelDownloadEvent/cancelled`` — the Skip
/// semantics: the user chose to stop, the `.part` survives, and the engine answers
/// `modelUnavailable` until a later attempt. Every other failure maps to
/// ``ModelDownloadEvent/failed(_:)`` with the cause named.
///
/// The protocol's requirements are nonisolated, so the in-flight task handle is guarded by a
/// ``Mutex`` rather than actor state: `cancel()` must be callable from any thread (the Skip
/// button), and the continuation is itself thread-safe, so progress events are yielded
/// directly, in the store's own order.
public actor StoreModelDownloadSession: ModelDownloadSession {

    private let store: ModelStore
    private let manifest: ModelManifest
    private let transport: any ModelTransport

    private let taskLock: Mutex<Task<Void, Never>?>

    public nonisolated let events: AsyncStream<ModelDownloadEvent>

    private nonisolated let continuation: AsyncStream<ModelDownloadEvent>.Continuation

    public init(
        store: ModelStore, manifest: ModelManifest, transport: any ModelTransport
    ) {
        self.store = store
        self.manifest = manifest
        self.transport = transport
        self.taskLock = Mutex(nil)
        var continuation: AsyncStream<ModelDownloadEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    /// Starts the download if it is not already in flight. Idempotent; when the version is
    /// already present and verified the store returns immediately and the stream ends in
    /// ``ModelDownloadEvent/committed``.
    public func start() {
        guard taskLock.withLock({ $0 }) == nil else { return }
        let task = Task {
            do {
                try await store.downloadIfMissing(
                    manifest: manifest, transport: transport
                ) { [continuation] fraction in
                    continuation.yield(.progress(fraction))
                }
                continuation.yield(.committed)
            } catch ModelDownloadError.interrupted {
                continuation.yield(.cancelled)
            } catch {
                continuation.yield(.failed(String(describing: error)))
            }
            continuation.finish()
        }
        taskLock.withLock { $0 = task }
    }

    public nonisolated func cancel() {
        taskLock.withLock { $0?.cancel() }
    }
}
