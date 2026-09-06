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

/// A latency percentile as the histogram can honestly report it: a **bucket bound**, never a spot
/// millisecond value.
///
/// The type exists so a caller cannot render a bucketed figure as false precision. A histogram
/// that counted a dictation in the 150 ms bucket knows the reading was over 100 ms and at most
/// 150 ms; it does not know it was 137 ms, and `atMostMilliseconds(150)` is the strongest true
/// statement available. Printing "137 ms" from that data would be an invention.
///
/// This costs nothing the gate needs. P2 asks "is p50 ≤ 400 ms and p95 ≤ 800 ms?"
/// (`ROADMAP.md:171`), 400 and 800 are both bucket bounds, and `atMostMilliseconds(800)` answers
/// that question **exactly** — no rounding, no argument. Only a reading past the last bound is
/// unbounded above, and it says so.
public enum LatencyBucketBound: Sendable, Equatable {
    /// The reading was at most this many milliseconds — the bucket's inclusive upper bound.
    case atMostMilliseconds(Int)
    /// The reading was over this many milliseconds: the overflow bucket, which has no upper
    /// bound. The histogram cannot say how far over, and does not pretend to.
    case aboveMilliseconds(Int)
}

/// A day's dictation latencies as a bounded, summable distribution — the shape the usage ledger
/// persists, instead of a pre-computed p50/p95.
///
/// ## Why a histogram and not two stored numbers
///
/// **Percentiles do not average.** A per-day p95 cannot be combined into a 30-day p95: nine quiet
/// days at 100 ms and one bad day at 3200 ms average to 410 ms, which passes the P2 gate, while
/// the true p95 over the hundred samples is 3200 ms, which fails it. Bucket *counts*, by
/// contrast, simply add up, so any window — a week, thirty days, one day — has a percentile
/// computable from the days it contains. That is the whole reason this type exists, and
/// `LatencyHistogramTests` builds the case above as an executable argument.
///
/// Because these bounds are what gets written to disk, they are the **persisted spelling** of a
/// day's latency: changing them is a format migration, not a tweak. They live in exactly one
/// named constant, pinned by a source scan in the tests.
///
/// ## The bounds
///
/// Fifteen bounds plus an overflow bucket, tightest where dictation latency actually lands and
/// widening as the readings stop mattering individually. **400 and 800 are both bounds on
/// purpose** — they are the P2 targets, so the gate's question falls exactly on a boundary and is
/// answered without rounding either way. The overflow bucket keeps the format bounded: a
/// pathological thirty-second session is counted without the file growing a bucket per outlier.
///
/// ## No fabrication
///
/// An empty histogram has **no** percentile — ``percentile(_:)`` returns `nil`, never `0`. This
/// is ``LatencySpan/Presence/notPresent``'s rule one level up: a day whose sessions were all
/// aborted measured nothing, and a fabricated 0 ms would read as the fastest day on record.
///
/// `VoccaCore` imports nothing, so every computation here is integer arithmetic on the standard
/// library's `Duration` — no `Foundation`, no `ceil`, no floating point anywhere on the path.
public struct LatencyHistogram: Sendable, Equatable {

    /// The bucket upper bounds, in milliseconds, in ascending order. **Inclusive uppers**: a
    /// sample lands in the first bucket whose bound it is at most, so a reading of exactly 800 ms
    /// is inside "p95 ≤ 800 ms" rather than over it.
    ///
    /// This is the persisted format. One constant, one home, one migration if it ever changes.
    public static let bucketUpperBoundsMilliseconds: [Int] = [
        25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1200, 1600, 2400, 3200, 5000
    ]

    /// One count per bucket, in ``bucketUpperBoundsMilliseconds`` order, with **one extra
    /// trailing entry**: the overflow bucket for readings past the last bound.
    public private(set) var bucketCounts: [Int]

    /// An empty day: every bucket zero, and therefore no percentile at all.
    public init() {
        bucketCounts = Array(repeating: 0, count: Self.bucketUpperBoundsMilliseconds.count + 1)
    }

    /// A histogram over `samples`, recorded in order. Order cannot matter — a histogram is a
    /// count per bucket — which is exactly why days can be summed.
    public init(samples: [Duration]) {
        self.init()
        for sample in samples {
            record(sample)
        }
    }

    /// How many samples the histogram holds, overflow included.
    public var sampleCount: Int {
        bucketCounts.reduce(0, +)
    }

    /// How many samples were past the last bound. Kept nameable so a caller can say "3 sessions
    /// over 5 s" rather than losing them into a percentile.
    public var overflowCount: Int {
        bucketCounts[bucketCounts.count - 1]
    }

    /// Counts one measured latency into the first bucket whose upper bound it is at most.
    ///
    /// The sample's milliseconds are rounded **up**, never truncated: 25.5 ms is over the 25 ms
    /// bound and belongs in the 50 ms bucket. Truncating would move readings into buckets they
    /// exceed, which is a latency figure quietly improving itself.
    public mutating func record(_ elapsed: Duration) {
        let milliseconds = Self.millisecondsRoundedUp(elapsed)
        for (index, bound) in Self.bucketUpperBoundsMilliseconds.enumerated()
        where milliseconds <= bound {
            bucketCounts[index] += 1
            return
        }
        bucketCounts[bucketCounts.count - 1] += 1
    }

    /// The nearest-rank percentile, reported as the bucket bound it falls in — or `nil` when
    /// there are no samples.
    ///
    /// Nearest rank takes the ceiling of `percent × n / 100` and returns the bucket holding that
    /// ranked sample, computed with integer arithmetic: this module has no `ceil`, and the
    /// integer form is exact where the floating one is not (`0.95 × 20` is not 19 in binary
    /// floating point). `percent` is clamped to 1...100; `nil` means one thing only — **no
    /// samples, no percentile** — so a caller renders n/a rather than a fabricated number.
    public func percentile(_ percent: Int) -> LatencyBucketBound? {
        let total = sampleCount
        guard total > 0, let lastBound = Self.bucketUpperBoundsMilliseconds.last else {
            return nil
        }
        let clampedPercent = max(1, min(100, percent))
        let rank = (clampedPercent * total + 99) / 100
        var cumulative = 0
        for (index, count) in bucketCounts.enumerated() {
            cumulative += count
            guard cumulative >= rank else { continue }
            if index < Self.bucketUpperBoundsMilliseconds.count {
                return .atMostMilliseconds(Self.bucketUpperBoundsMilliseconds[index])
            }
            return .aboveMilliseconds(lastBound)
        }
        // Unreachable: `rank` is at most `total`, and the loop accumulates to exactly `total`.
        return nil
    }

    /// The distribution over several days: bucket counts added together.
    ///
    /// This is the operation a stored p50/p95 cannot offer, and the only honest way to get a
    /// window figure. Summing days and then taking the percentile is not an approximation of
    /// averaging the days' percentiles — it is the correct answer, and the average is the wrong
    /// one.
    public static func summed(_ histograms: [LatencyHistogram]) -> LatencyHistogram {
        var total = LatencyHistogram()
        for histogram in histograms {
            for (index, count) in histogram.bucketCounts.enumerated()
            where index < total.bucketCounts.count {
                total.bucketCounts[index] += count
            }
        }
        return total
    }

    /// `elapsed` in whole milliseconds, rounded **up**, using only `Duration.components` — the
    /// standard library's integer view of a duration `(seconds, attoseconds)`.
    ///
    /// Two guards keep the arithmetic total: a negative delta cannot come from a
    /// ``MonotonicClock`` and is read as zero rather than wrapped into a bucket by accident, and
    /// a duration of more seconds than the last bound covers returns early, so multiplying
    /// seconds by 1000 can never overflow.
    private static func millisecondsRoundedUp(_ elapsed: Duration) -> Int {
        let components = elapsed.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let lastBoundMilliseconds = Int64(bucketUpperBoundsMilliseconds.last ?? 0)
        let overflowSeconds = lastBoundMilliseconds / 1000 + 1
        guard components.seconds < overflowSeconds else {
            return Int(overflowSeconds * 1000)
        }
        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        let subSecondMilliseconds =
            (components.attoseconds + attosecondsPerMillisecond - 1) / attosecondsPerMillisecond
        return Int(components.seconds * 1000 + subSecondMilliseconds)
    }
}
