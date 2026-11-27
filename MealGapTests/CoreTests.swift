import Foundation
import CoreImage
import ImageIO
import SQLite3
import XCTest

final class CoreTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func sample(_ start: Date, _ end: Date, zone: String = "UTC") -> IntervalRecord {
        IntervalRecord(active: ActiveInterval(start: start, zone: zone), end: end, endZone: zone, source: "test", updated: end)
    }
    private func database() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appending(path: "test.sqlite")
    }

    func testCrossMidnightDSTAndRecordedDay() throws {
        let overnight = sample(date("2026-11-19T19:10:00Z"), date("2026-11-20T07:05:00Z"))
        XCTAssertEqual(overnight.duration, 42900)
        let spring = sample(date("2026-03-08T01:30:00-05:00"), date("2026-03-08T03:30:00-04:00"), zone: "America/New_York")
        let autumn = sample(date("2026-11-01T01:30:00-04:00"), date("2026-11-01T01:30:00-05:00"), zone: "America/New_York")
        XCTAssertEqual(spring.duration, 3600)
        XCTAssertEqual(autumn.duration, 3600)
        XCTAssertNotEqual(autumn.active.start, autumn.end)
        var state = MealState()
        let travel = sample(date("2026-11-19T12:00:00Z"), date("2026-11-19T17:00:00Z"), zone: "Asia/Tokyo")
        let now = date("2026-11-20T12:34:00Z")
        try state.apply(.complete(travel, activeID: nil, editing: false), now: now, zone: utc)
        XCTAssertEqual(state.trend(days: 1, now: now, zone: utc), [TrendPoint(day: "2026-11-20", seconds: 18000)])
        XCTAssertTrue(state.csv().contains("2026-11-19T17:00:00Z,Asia/Tokyo,18000"))
    }

    func testValidationAndEndpointAdjacency() throws {
        let start = date("2026-11-19T19:10:00Z")
        let middle = start.addingTimeInterval(600)
        let now = start.addingTimeInterval(1200)
        var state = MealState()
        let first = sample(start, middle)
        try state.apply(.complete(first, activeID: nil, editing: false), now: now, zone: utc)
        try state.apply(.complete(sample(middle, now), activeID: nil, editing: false), now: now, zone: utc)
        for (record, error) in [(sample(start, now), MealError.overlap(first)), (sample(now, now), .order), (sample(now, middle), .order), (sample(now, now.addingTimeInterval(1)), .future)] {
            XCTAssertThrowsError(try state.apply(.complete(record, activeID: nil, editing: false), now: now, zone: utc)) {
                XCTAssertEqual($0 as? MealError, error)
            }
        }
        try state.apply(.start(now, nil), now: now, zone: utc)
        XCTAssertThrowsError(try state.apply(.finish(middle, "timer"), now: middle, zone: utc))
        XCTAssertNotNil(state.active)
    }

    func testConcurrentStartRollbackAndReopen() async throws {
        let file = try database()
        let start = date("2026-11-19T19:10:00Z")
        let end = start.addingTimeInterval(60)
        let store = MealStore(url: file)
        let second = MealStore(url: file)
        async let firstWrite = store.change(.start(start, nil), now: start, zone: utc)
        async let secondWrite = second.change(.start(start, nil), now: start, zone: utc)
        let (first, later) = try await (firstWrite, secondWrite)
        let tokens = [first.1, later.1]
        XCTAssertEqual(tokens.compactMap { $0 }.count, 1)
        let active = try await second.snapshot().active
        XCTAssertEqual(active?.start, start)
        let failing = MealStore(url: file, beforeWrite: { throw MealError.storage })
        do { _ = try await failing.change(.finish(end, "timer"), now: end); XCTFail("Expected write failure") }
        catch { XCTAssertEqual(error as? MealError, .storage) }
        let restored = try await MealStore(url: file).snapshot()
        XCTAssertEqual(restored.active, active)
        XCTAssertTrue(restored.records.isEmpty)
        let completed = try await store.change(.finish(end, "timer"), now: end)
        XCTAssertNil(completed.0.active)
        XCTAssertEqual(completed.0.records.first?.duration, 60)
        let repeated = try await second.change(.finish(end, "timer"), now: end)
        XCTAssertNil(repeated.1)
        XCTAssertEqual(repeated.0.records.count, 1)
    }

    func testUndoExpiryAndRevision() async throws {
        let file = try database()
        let now = Date()
        let store = MealStore(url: file)
        let started = try await store.change(.start(now, nil), now: now)
        let token = try XCTUnwrap(started.1)
        do { _ = try await store.undo(token, now: now.addingTimeInterval(8)); XCTFail("Expected expiration") }
        catch { XCTAssertEqual(error as? MealError, .stale) }
        let cleared = try await store.undo(token, now: now.addingTimeInterval(1))
        XCTAssertNil(cleared.active)
        let next = try await store.change(.start(now, nil), now: now)
        let nextToken = try XCTUnwrap(next.1)
        _ = try await store.change(.reminders(true), now: now)
        do { _ = try await store.undo(nextToken, now: now); XCTFail("Expected version conflict") }
        catch { XCTAssertEqual(error as? MealError, .stale) }
    }

    func testTemplatesSnapshotAndExpiredEdits() throws {
        let now = Date()
        var state = MealState()
        var template = TimingTemplate(localName: "Private title", minutes: 720, imported: false, created: now)
        try state.apply(.saveTemplate(template, pro: false), now: now, zone: utc)
        try state.apply(.start(now, template.id), now: now, zone: utc)
        template.minutes = 480
        try state.apply(.saveTemplate(template, pro: false), now: now, zone: utc)
        try state.apply(.importTemplate(720), now: now, zone: utc)
        XCTAssertThrowsError(try state.apply(.importTemplate(720), now: now, zone: utc)) { XCTAssertEqual($0 as? MealError, .duplicate) }
        XCTAssertFalse(state.canCreateTemplate(pro: false))
        XCTAssertTrue(state.canCreateTemplate(pro: true))
        try state.apply(.deleteTemplate(template.id), now: now, zone: utc)
        XCTAssertEqual(state.active?.targetMinutes, 720)
        let end = now.addingTimeInterval(600)
        try state.apply(.finish(end, "timer"), now: end, zone: utc)
        XCTAssertEqual(state.records.count, 1)
        XCTAssertTrue(state.canCreateTemplate(pro: false))
    }

    func testTrialBoundaryMigrationReceiptAndRevocation() throws {
        let original = date("2026-01-01T12:00:00Z")
        let update = original.addingTimeInterval(45 * 86400)
        var access = Entitlement(firstOpen: original)
        access.open(at: original, free: true)
        XCTAssertTrue(access.hasPro(at: update, free: true))
        access.open(at: update, free: false)
        XCTAssertEqual(access.trialStart, update)
        XCTAssertTrue(access.hasPro(at: access.trialEnd.addingTimeInterval(-1), free: false))
        XCTAssertFalse(access.hasPro(at: access.trialEnd, free: false))
        access.applyVerified(trial: update.addingTimeInterval(86400))
        XCTAssertEqual(access.trialStart, update)
        access.applyVerified(trial: original)
        access.applyVerified(trial: update)
        XCTAssertFalse(access.hasPro(at: update, free: false))
        access.applyVerified(pro: true)
        let offline = try JSONDecoder().decode(Entitlement.self, from: JSONEncoder().encode(access))
        XCTAssertTrue(offline.hasPro(at: update, free: false))
        access.applyVerified(pro: false)
        XCTAssertFalse(access.hasPro(at: update, free: false))
    }

    func testRunningIntervalCrossesTrialEndWithoutLosingData() throws {
        let first = date("2026-01-01T12:00:00Z")
        let access = Entitlement(firstOpen: first)
        let start = access.trialEnd.addingTimeInterval(-60)
        let end = access.trialEnd.addingTimeInterval(60)
        var state = MealState()
        let template = TimingTemplate(minutes: 720, imported: false, created: first)
        try state.apply(.saveTemplate(template, pro: access.hasPro(at: start, free: false)), now: start, zone: utc)
        try state.apply(.start(start, template.id), now: start, zone: utc)
        XCTAssertFalse(access.hasPro(at: end, free: false))
        try state.apply(.finish(end, "timer"), now: end, zone: utc)
        XCTAssertEqual(state.records.first?.duration, 120)
        XCTAssertEqual(state.records.first?.active.targetMinutes, 720)
        XCTAssertTrue(state.csv().contains(",120\r\n"))
    }

    func testCodeFileAndCardQRCode() throws {
        let payload = TemplateCode.data(720)
        XCTAssertEqual(try TemplateCode.decode("Template\n\(TemplateCode.encode(720))"), 720)
        XCTAssertEqual(try TemplateCode.decode(payload), 720)
        XCTAssertEqual(Set((try JSONSerialization.jsonObject(with: payload) as? [String: Int] ?? [:]).keys), Set(["version", "targetMinutes"]))
        let file = try ShareRequest.file(payload, named: "Card.mealinterval")
        defer { ShareRequest.cleanup([file]) }
        XCTAssertEqual(try TemplateCode.fromFile(file), 720)
        for value in ["{\"version\":2,\"targetMinutes\":720}", "{\"version\":1,\"targetMinutes\":720.0}", "{\"version\":1,\"targetMinutes\":true}", "{\"version\":1,\"targetMinutes\":10081}", "{\"version\":1,\"targetMinutes\":12,\"name\":\"private\"}", String(repeating: " ", count: 4097)] {
            XCTAssertThrowsError(try TemplateCode.decode(Data(value.utf8)))
        }
        let url = "https://apps.apple.com/app/id1234567890"
        let card = try ShareArt.card(minutes: 720, milestone: false, url: url)
        let image = try XCTUnwrap(CIImage(data: card))
        XCTAssertEqual(image.extent.size, CGSize(width: 1080, height: 1350))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        XCTAssertEqual(detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }, [url])
        let shortTemplate = try ShareArt.card(minutes: 360, milestone: false, url: url)
        let shortImage = try XCTUnwrap(CIImage(data: shortTemplate))
        XCTAssertEqual(shortImage.extent, image.extent)
        XCTAssertEqual(detector.features(in: shortImage).compactMap { ($0 as? CIQRCodeFeature)?.messageString }, [url])
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testMilestoneAndReviewConditions() throws {
        let now = Date()
        var state = MealState()
        for index in 0..<7 {
            let end = now.addingTimeInterval(Double(index - 7) * 86400)
            try state.apply(.visit, now: end, zone: utc)
            try state.apply(.complete(sample(end.addingTimeInterval(-600), end), activeID: nil, editing: false), now: now, zone: utc)
        }
        XCTAssertEqual(state.milestonePending, 7)
        try state.apply(.dismissMilestone, now: now, zone: utc)
        let last = try XCTUnwrap(state.sorted.first)
        try state.apply(.delete(last.id), now: now, zone: utc)
        try state.apply(.complete(last, activeID: nil, editing: false), now: now, zone: utc)
        XCTAssertNil(state.milestonePending)
        XCTAssertTrue(state.canReview)
        try state.apply(.review, now: now, zone: utc)
        XCTAssertFalse(state.canReview)
    }

    func testSchemaZeroMigratesWithoutDiscardingExistingState() async throws {
        let url = try database()
        let store = MealStore(url: url)
        let now = Date()
        let saved = try await store.change(.start(now, nil), now: now).0
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = 0", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let reopened = try await MealStore(url: url).snapshot()
        XCTAssertEqual(reopened, saved)
    }
}
