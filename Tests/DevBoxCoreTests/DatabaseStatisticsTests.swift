import XCTest
@testable import DevBoxCore

final class DatabaseStatisticsTests: XCTestCase {
    func testStrictNonnegativeIntegerParsing() {
        for text in [nil, "", "-1", "+1", " 1", "1 ", "1.0", "1e3", "１２", "abc", "9223372036854775808", "18446744073709551615"] as [String?] {
            XCTAssertNil(DatabaseStatistics.nonnegativeInteger(text), "\(String(describing: text))")
        }
        XCTAssertEqual(DatabaseStatistics.nonnegativeInteger("0"), 0)
        XCTAssertEqual(DatabaseStatistics.nonnegativeInteger("0012"), 12)
        XCTAssertEqual(DatabaseStatistics.nonnegativeInteger(String(Int64.max)), Int64.max)
    }

    func testTotalsAreCheckedAndRequireBothMetrics() {
        func stats(_ data: Int64?, _ index: Int64?) -> DatabaseStatistics {
            .init(tableCount: 0, viewCount: 0, estimatedRows: nil, dataBytes: data, indexBytes: index)
        }
        XCTAssertEqual(stats(12, 34).totalBytes, 46)
        XCTAssertEqual(stats(Int64.max, 0).totalBytes, Int64.max)
        XCTAssertNil(stats(Int64.max, 1).totalBytes)
        XCTAssertNil(stats(nil, 0).totalBytes)
        XCTAssertNil(stats(0, nil).totalBytes)
    }

    func testAggregationEmptySchemasViewsAndVersionedTables() throws {
        var values: [String: DatabaseStatistics] = [:]
        try DatabaseStatistics.accumulate(["empty", nil, nil, nil, nil, nil], into: &values)
        try DatabaseStatistics.accumulate(["資料`", "one", "BASE TABLE", "3", "10", "20"], into: &values)
        try DatabaseStatistics.accumulate(["資料`", "two", "SYSTEM VERSIONED", "4", "30", "40"], into: &values)
        for type in ["VIEW", "SYSTEM VIEW"] {
            try DatabaseStatistics.accumulate(["資料`", "view", type, nil, "999", nil], into: &values)
        }
        XCTAssertEqual(values["empty"], .init(tableCount: 0, viewCount: 0, estimatedRows: 0, dataBytes: 0, indexBytes: 0))
        XCTAssertEqual(values["資料`"], .init(tableCount: 2, viewCount: 2, estimatedRows: 7, dataBytes: 40, indexBytes: 60))
    }

    func testUnknownAndOverflowPropagatePerMetricWithoutLosingCounts() throws {
        for unavailable in [nil, "-1", "garbage", "9223372036854775808"] as [String?] {
            var values: [String: DatabaseStatistics] = [:]
            try DatabaseStatistics.accumulate(["db", "a", "BASE TABLE", unavailable, "10", String(Int64.max)], into: &values)
            try DatabaseStatistics.accumulate(["db", "b", "BASE TABLE", "5", "20", "1"], into: &values)
            try DatabaseStatistics.accumulate(["db", "c", "BASE TABLE", "5", "30", "0"], into: &values)
            XCTAssertEqual(values["db"], .init(tableCount: 3, viewCount: 0, estimatedRows: nil, dataBytes: 60, indexBytes: nil))
            XCTAssertNil(values["db"]?.totalBytes)
        }
    }

    func testInvalidRowsAndCountOverflowFailSafely() {
        var values: [String: DatabaseStatistics] = [
            "db": .init(tableCount: Int64.max, viewCount: 0, estimatedRows: 0, dataBytes: 0, indexBytes: 0)
        ]
        for row: [String?] in [[], [nil, nil, nil, nil, nil, nil], ["db", "table", nil, "0", "0", "0"],
                               ["db", "table", "BASE TABLE", "0", "0", "0"]] {
            XCTAssertThrowsError(try DatabaseStatistics.accumulate(row, into: &values))
        }
    }

    func testCancelledRequestNeverConnects() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DatabaseService().databaseStatistics(settings: .init(socketPath: "/nonexistent/devbox-test.sock"), password: "")
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled statistics request succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
