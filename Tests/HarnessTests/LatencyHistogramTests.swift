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
import VoccaCore
import XCTest

/// The per-day latency histogram — `usage-vocabulary`'s B12–B16, written before the type exists.
///
/// The ledger stores a **bounded histogram per day**, not a per-day p50/p95, and this suite is
/// where that file-format decision is argued rather than asserted:
///
/// - percentiles do not average, so a stored per-day p95 cannot produce a 30-day p95. Buckets
///   sum, so any window's percentile is computable from them —
///   ``testAWindowPercentileSumsBucketsRatherThanAveragingPerDayPercentiles`` builds the case
///   where averaging reports a figure that *passes* the P2 gate over a window that *fails* it;
/// - a percentile read off a histogram is a **bucket bound**, not a spot millisecond value, so
///   the return type says `atMost` and a UI cannot render it as false precision. That is not a
///   loss: the gate asks "is p95 ≤ 800 ms?" (`ROADMAP.md:171`), and a bound at exactly 800 ms
///   answers that question exactly;
/// - no samples yields `nil`, never `0` — ``LatencySpan/Presence/notPresent``'s rule
///   (`LatencySpan.swift:44-53`) and `LatencyBenchmarkRealEngineTests.swift:75-76`'s: a row
///   prints n/a, never a fabricated number.
///
/// The bounds are the **persisted spelling** of a day's latency, so changing them is a
/// migration, not a tweak — pinned to one named constant by the source scan at the end.
final class LatencyHistogramTests: XCTestCase {

    // MARK: - Test helpers

    /// The count in the bucket whose upper bound is `bound` ms, addressed by the bound itself so
    /// a test reads in the vocabulary the gate uses rather than in array indices.
    private static func count(
        upToMilliseconds bound: Int, in histogram: LatencyHistogram
    ) throws -> Int {
        let index = try XCTUnwrap(
            LatencyHistogram.bucketUpperBoundsMilliseconds.firstIndex(of: bound),
            "\(bound) ms is not one of the histogram's bucket bounds — the test is asking about a bucket that does not exist")
        return histogram.bucketCounts[index]
    }

    /// The millisecond number a bound carries. **Test-only arithmetic**: it exists so B15 can
    /// carry out the averaging mistake explicitly and show what it produces. Production code
    /// keeps a bound as a bound.
    private static func milliseconds(of bound: LatencyBucketBound) -> Int {
        switch bound {
        case .atMostMilliseconds(let value): return value
        case .aboveMilliseconds(let value): return value
        }
    }

    /// The bounds as they are written in source — the persisted spelling the B16 scan pins.
    private static let boundsSpelling =
        "25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1200, 1600, 2400, 3200, 5000"

    /// Every file in `corpus` whose **code** spells the bounds, and how many times.
    ///
    /// Comments are stripped first, so prose that quotes the bounds is documentation rather than
    /// a second home for them — and the count is per occurrence, not per file, so a second
    /// declaration inside the one permitted file is caught too.
    ///
    /// Taking a corpus rather than reading the disk itself is what makes the guard testable in
    /// both directions: the same function is run over the real tree and over a source string that
    /// deliberately declares the bounds twice.
    private static func filesSpellingTheBounds(in corpus: [String: String]) -> [String: Int] {
        var sightings: [String: Int] = [:]
        for (name, content) in corpus {
            let code = SwiftSourceScanner.stripComments(from: content)
            let occurrences = code.components(separatedBy: Self.boundsSpelling).count - 1
            if occurrences > 0 {
                sightings[name] = occurrences
            }
        }
        return sightings
    }

    // MARK: - B12 · bucketing

    /// A sample lands in the **first** bucket whose upper bound it is at most.
    ///
    /// The sub-millisecond case is the one that makes the rule real: 25.5 ms is *not* ≤ 25 ms, so
    /// it belongs in the 50 ms bucket. Truncating it to 25 would move a sample into a bucket it
    /// is over, which is how a latency figure quietly improves itself.
    func testASampleLandsInTheFirstBucketWhoseUpperBoundItIsAtMost() throws {
        var histogram = LatencyHistogram()
        histogram.record(.milliseconds(26))
        histogram.record(.microseconds(25_500))
        histogram.record(.milliseconds(201))

        XCTAssertEqual(
            try Self.count(upToMilliseconds: 50, in: histogram), 2,
            "26 ms and 25.5 ms are both over the 25 ms bound and at most the 50 ms bound, so both belong in the 50 ms bucket")
        XCTAssertEqual(
            try Self.count(upToMilliseconds: 25, in: histogram), 0,
            "nothing recorded was ≤ 25 ms — a sample that rounds down into a faster bucket makes the day look better than it was")
        XCTAssertEqual(
            try Self.count(upToMilliseconds: 300, in: histogram), 1,
            "201 ms is over the 200 ms bound, so it lands in the next bucket up, not the one it exceeds")
        XCTAssertEqual(
            try Self.count(upToMilliseconds: 200, in: histogram), 0,
            "201 ms must not be counted as ≤ 200 ms")
        XCTAssertEqual(histogram.sampleCount, 3, "every recorded sample is counted exactly once")
    }

    /// A sample **exactly on** a bound lands in that bucket: the bounds are inclusive uppers.
    ///
    /// Pinned rather than left incidental, because the gate's question is asked at a bound. A
    /// dictation that took exactly 800 ms is inside "p95 ≤ 800 ms"; an exclusive upper would put
    /// it in the 1200 ms bucket and fail a release that passed.
    func testASampleExactlyOnABoundLandsInThatBucketNotTheNextOne() throws {
        var histogram = LatencyHistogram()
        histogram.record(.milliseconds(25))
        histogram.record(.milliseconds(400))
        histogram.record(.milliseconds(800))

        XCTAssertEqual(
            try Self.count(upToMilliseconds: 25, in: histogram), 1,
            "the first bound is inclusive too — 25 ms is ≤ 25 ms")
        XCTAssertEqual(
            try Self.count(upToMilliseconds: 400, in: histogram), 1,
            "exactly 400 ms is inside the P2 p50 target, not over it")
        XCTAssertEqual(
            try Self.count(upToMilliseconds: 800, in: histogram), 1,
            "exactly 800 ms is inside the P2 p95 target, not over it")
        XCTAssertEqual(
            try Self.count(upToMilliseconds: 50, in: histogram), 0,
            "an inclusive upper bound means nothing spills into the next bucket")
        XCTAssertEqual(try Self.count(upToMilliseconds: 600, in: histogram), 0)
        XCTAssertEqual(try Self.count(upToMilliseconds: 1200, in: histogram), 0)
    }

    /// A sample above the last bound lands in the overflow bucket, and is reported as
    /// `aboveMilliseconds(5000)` — the honest shape for a reading the histogram cannot bound.
    ///
    /// The overflow bucket is what keeps the histogram bounded: a 30-second pathological session
    /// must be countable without the format growing a bucket per outlier.
    func testASampleAboveTheLastBoundLandsInTheOverflowBucket() {
        var histogram = LatencyHistogram()
        histogram.record(.milliseconds(5001))
        histogram.record(.seconds(30))

        XCTAssertEqual(
            histogram.overflowCount, 2,
            "both samples are over the last bound, so both belong in overflow — a bounded histogram cannot grow a bucket per outlier")
        XCTAssertEqual(
            histogram.sampleCount, 2,
            "an overflowing sample is still a counted sample; dropping it would understate the day")
        XCTAssertEqual(
            histogram.percentile(50), .aboveMilliseconds(5000),
            "the histogram cannot bound an overflowing reading, so it must say 'above 5000 ms' rather than name a bound it did not measure")
    }

    // MARK: - B13 · nearest-rank percentiles

    /// One sample: every percentile is that sample's bucket.
    ///
    /// Nearest rank over n = 1 selects rank 1 at every percentile, so p50 and p95 agree. A day
    /// with a single dictation is the common case in early daily use, and it must report
    /// something rather than nothing.
    func testASingleSampleIsReportedAsItsOwnBucketAtEveryPercentile() {
        let histogram = LatencyHistogram(samples: [.milliseconds(137)])

        XCTAssertEqual(
            histogram.percentile(50), .atMostMilliseconds(150),
            "137 ms lands in the 150 ms bucket, and with one sample that bucket is the whole distribution")
        XCTAssertEqual(histogram.percentile(95), .atMostMilliseconds(150))
        XCTAssertEqual(histogram.percentile(100), .atMostMilliseconds(150))
    }

    /// Every sample in one bucket: every percentile is that bucket, at every rank.
    ///
    /// This is the case that shows the resolution honestly. Seven readings spread over 101–150 ms
    /// all report "at most 150 ms" — the histogram never claims to know which of them the p95
    /// was, because it does not.
    func testSamplesInOneBucketReportThatBucketAtEveryPercentile() {
        let histogram = LatencyHistogram(
            samples: [101, 110, 120, 130, 140, 149, 150].map { Duration.milliseconds($0) })

        XCTAssertEqual(histogram.sampleCount, 7)
        for percent in [1, 25, 50, 95, 99, 100] {
            XCTAssertEqual(
                histogram.percentile(percent), .atMostMilliseconds(150),
                "every sample is in the 150 ms bucket, so p\(percent) is that bucket — the histogram must not invent a spot value inside it")
        }
    }

    /// A spread whose p50 and p95 land in different buckets, hand-computed by nearest rank.
    ///
    /// Ten samples: 10, 20, 30, 40, 50, 60, 700, 900, 1500, 4000 ms. Nearest rank takes
    /// ceil(p × n): p50 → rank 5 → the 5th smallest (50 ms) → the 50 ms bucket; p95 → rank 10 →
    /// the 10th (4000 ms) → the 5000 ms bucket. The two must not collapse into one number: a day
    /// whose median is fast and whose tail is four seconds is exactly the day the gate is asked
    /// about.
    func testASpreadReportsDifferentBucketsForTheMedianAndTheNinetyFifth() {
        let histogram = LatencyHistogram(
            samples: [10, 20, 30, 40, 50, 60, 700, 900, 1500, 4000].map {
                Duration.milliseconds($0)
            })

        XCTAssertEqual(
            histogram.percentile(50), .atMostMilliseconds(50),
            "nearest rank over 10 samples puts p50 at rank 5, the 50 ms reading, which sits exactly on the 50 ms bound")
        XCTAssertEqual(
            histogram.percentile(95), .atMostMilliseconds(5000),
            "nearest rank puts p95 at rank 10 — the 4000 ms reading — and the smallest bound that contains it is 5000 ms")
        XCTAssertEqual(
            histogram.percentile(90), .atMostMilliseconds(1600),
            "rank 9 is the 1500 ms reading, which lands in the 1600 ms bucket")
        XCTAssertNotEqual(
            histogram.percentile(50), histogram.percentile(95),
            "a median and a tail two orders of magnitude apart must not report the same bucket — that difference is the whole information the gate reads")
    }

    // MARK: - B14 · no samples, no percentile

    /// No samples yields `nil` at every percentile — never `0`.
    ///
    /// A day of `aborted` and `emptySkip` sessions records no latency at all. Reporting 0 ms for
    /// it would put a fabricated, *perfect* number into the gate's window; the honest surface is
    /// n/a. This is ``LatencySpan/Presence/notPresent``'s rule applied one level up
    /// (`LatencySpan.swift:44-53`).
    func testNoSamplesYieldsNoPercentileRatherThanAFabricatedZero() {
        let empty = LatencyHistogram()

        XCTAssertEqual(empty.sampleCount, 0)
        XCTAssertNil(
            empty.percentile(50),
            "no samples, no percentile — a day with no measured dictation must render n/a, never a fabricated 0 ms that would read as the fastest day on record")
        XCTAssertNil(
            empty.percentile(95), "the same holds at every percentile, not just the median")
        XCTAssertNil(
            LatencyHistogram.summed([LatencyHistogram(), LatencyHistogram()]).percentile(95),
            "summing empty days sums to an empty window — an absent measurement stays absent across the fold")
    }

    // MARK: - B15 · why the histogram exists

    /// **The reason this type exists.** A window's percentile is computed from summed buckets,
    /// and is not the average of the per-day percentiles.
    ///
    /// Ten days: nine of ten dictations at 100 ms, one bad day of ten at 3200 ms. Averaging the
    /// per-day p95s gives 410 ms, which *passes* the P2 gate's p95 ≤ 800 ms. Summing the buckets
    /// gives the truth — rank 95 of 100 falls past the 90 fast readings and into the 3200 ms
    /// bucket — which *fails* it. Averaging percentiles is not a coarser answer here; it is the
    /// wrong one, and it is wrong in the direction that ships a release.
    func testAWindowPercentileSumsBucketsRatherThanAveragingPerDayPercentiles() throws {
        let fastDay = LatencyHistogram(
            samples: Array(repeating: Duration.milliseconds(100), count: 10))
        let slowDay = LatencyHistogram(
            samples: Array(repeating: Duration.milliseconds(3200), count: 10))
        let days = Array(repeating: fastDay, count: 9) + [slowDay]

        let perDayPercentiles = days.compactMap { $0.percentile(95) }
        XCTAssertEqual(
            perDayPercentiles.count, 10, "every day here has samples, so every day has a p95")
        let averagedPerDay =
            perDayPercentiles.map(Self.milliseconds(of:)).reduce(0, +) / perDayPercentiles.count
        XCTAssertEqual(
            averagedPerDay, 410,
            "the mistake, computed explicitly: (9 × 100 + 3200) / 10 = 410 ms, which reads as comfortably inside the ≤ 800 ms gate")

        let window = LatencyHistogram.summed(days)

        XCTAssertEqual(
            window.sampleCount, 100,
            "the window holds every day's samples, not every day's summary")
        XCTAssertEqual(
            window.percentile(95), .atMostMilliseconds(3200),
            """
            THE REASON THIS TYPE EXISTS. Percentiles do not average: rank 95 of 100 samples falls \
            past the 90 readings at 100 ms and into the 3200 ms bucket, so the window's true p95 \
            is 3200 ms — over the P2 gate's 800 ms. If the ledger stored a per-day p50/p95 \
            instead of buckets, the only 30-day figure it could compute would be the average of \
            those, 410 ms, and the gate would report a pass on a window that fails. Buckets sum; \
            percentiles do not.
            """)
        XCTAssertEqual(
            window.percentile(50), .atMostMilliseconds(100),
            "the median over the window is still the fast bucket — the tail moves p95 without moving p50, which is exactly what a two-number gate is for")
        let windowP95 = try XCTUnwrap(window.percentile(95))
        XCTAssertNotEqual(
            Self.milliseconds(of: windowP95), averagedPerDay,
            "the averaged figure and the true figure are different answers to the same question, and only one of them was computed from the samples")
    }

    // MARK: - B16 · the bounds have exactly one home

    /// The bucket bounds are declared in exactly one named constant, pinned by a source scan —
    /// the ``InjectionStrategyStoreTests/testTheRememberedAppsCapLivesOnlyInTheNamedConstant``
    /// precedent (`InjectionStrategyStoreTests.swift:42`).
    ///
    /// These bounds are the **persisted spelling** of a day's latency. A second copy — a decoder's
    /// "legacy" list, a chart's axis, a migration's table — is not a duplicate constant, it is a
    /// second file format that agrees with the first until the day someone edits one of them, and
    /// then every stored day is silently mis-bucketed. So the scan pins the *bounds themselves*,
    /// not the identifier: another name over the same numbers is exactly the failure.
    ///
    /// The vacuity guard runs **both ways**, because a scan that finds nothing passes by default:
    /// the real tree must yield the one declaration that exists, and the same function run over a
    /// corpus that declares the bounds twice must report both files.
    func testTheBucketBoundsLiveInExactlyOneNamedConstant() throws {
        let bounds = LatencyHistogram.bucketUpperBoundsMilliseconds
        XCTAssertEqual(
            bounds.count, 15,
            "fifteen bounds plus one overflow bucket — a bound added or dropped is a format change, not a tuning knob")
        XCTAssertEqual(
            LatencyHistogram().bucketCounts.count, bounds.count + 1,
            "every bound gets a bucket, and the extra trailing one is overflow — readings past the last bound are counted, never dropped")
        XCTAssertEqual(
            bounds, bounds.sorted(),
            "the bounds must ascend: 'the first bucket whose bound the sample is at most' is only well defined in order")
        XCTAssertEqual(
            Set(bounds).count, bounds.count, "a repeated bound would make one bucket unreachable")
        XCTAssertTrue(
            bounds.contains(400),
            "400 ms is the P2 p50 target (ROADMAP.md:171) and must be a bound, so the gate's question lands exactly on a boundary rather than inside a bucket")
        XCTAssertTrue(
            bounds.contains(800),
            "800 ms is the P2 p95 target and must be a bound for the same reason — 'p95 ≤ 800 ms' is answerable exactly, with no rounding either way")

        let root = try PackageRootLocator.find(from: #filePath)
        var corpus: [String: String] = [:]
        for tree in [root.appendingPathComponent("Sources"), root.appendingPathComponent("Tests")] {
            for file in SwiftSourceScanner.swiftFiles(under: tree) {
                corpus[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
            }
        }
        XCTAssertFalse(corpus.isEmpty, "vacuity guard: the scan saw no files at all")

        let sightings = Self.filesSpellingTheBounds(in: corpus)
        XCTAssertEqual(
            sightings["LatencyHistogram.swift"], 1,
            "vacuity guard, first direction: the constant that exists must be found, exactly once, in the file that names it")
        XCTAssertEqual(
            Set(sightings.keys), ["LatencyHistogram.swift", "LatencyHistogramTests.swift"],
            "the bounds may be spelled only in the Core file that declares them and in this pinning test; anywhere else is a second, silently diverging copy of the persisted format. Found: \(sightings)")

        let corpusWithASecondHome: [String: String] = [
            "LatencyHistogram.swift":
                "public static let bucketUpperBoundsMilliseconds: [Int] = [\(Self.boundsSpelling)]",
            "UsageDayCodec.swift":
                "private let legacyLatencyBuckets: [Int] = [\(Self.boundsSpelling)]",
        ]
        XCTAssertEqual(
            Set(Self.filesSpellingTheBounds(in: corpusWithASecondHome).keys),
            ["LatencyHistogram.swift", "UsageDayCodec.swift"],
            "vacuity guard, other direction: run against a source that declares the bounds a second time under another name, the scan must see both files — otherwise the assertion above is a test that cannot fail")
        XCTAssertTrue(
            Self.filesSpellingTheBounds(in: ["Prose.swift": "// \(Self.boundsSpelling)"]).isEmpty,
            "a comment quoting the bounds is documentation, not a second declaration — the scan strips comments so prose stays free to explain the format")
    }
}
