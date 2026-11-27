import Foundation
import SQLite3

struct UndoMeal: Sendable {
    var previous: MealState
    var revision: Int
    var deadline: Date
}

actor MealStore {
    static let shared = MealStore()
    static let group = "group.com.hgsldswk.mealgap"
    private let url: URL?
    private let beforeWrite: @Sendable () throws -> Void

    init(url: URL? = nil, beforeWrite: @escaping @Sendable () throws -> Void = {}) {
        self.url = url
        self.beforeWrite = beforeWrite
    }

    private func withDatabase<T>(_ work: (OpaquePointer) throws -> T) throws -> T {
        let location: URL
        if let url { location = url }
        else if Launch.testing {
            location = URL.applicationSupportDirectory.appending(path: "MealGap-ui.sqlite")
        } else {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group) else { throw MealError.storage }
            location = container.appending(path: "MealGap.sqlite")
        }
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(location.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        defer { sqlite3_close(pointer) }
        guard result == SQLITE_OK, let db = pointer else { throw MealError.storage }
        sqlite3_busy_timeout(db, 3000)
        try execute("BEGIN IMMEDIATE", db)
        do {
            let version = try statement("PRAGMA user_version", db) { stmt in
                guard sqlite3_step(stmt) == SQLITE_ROW else { throw MealError.storage }
                return sqlite3_column_int(stmt, 0)
            }
            guard version <= 1 else { throw MealError.storage }
            if version == 0 {
                try execute("CREATE TABLE IF NOT EXISTS meal_state (id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL)", db)
                try execute("PRAGMA user_version = 1", db)
            }
            let value = try work(db)
            try execute("COMMIT", db)
            return value
        } catch {
            try? execute("ROLLBACK", db)
            throw error
        }
    }

    private func execute(_ sql: String, _ db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MealError.storage }
    }

    private func statement<T>(_ sql: String, _ db: OpaquePointer, _ work: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let stmt = pointer else { throw MealError.storage }
        defer { sqlite3_finalize(stmt) }
        return try work(stmt)
    }

    private func read(_ db: OpaquePointer) throws -> MealState {
        try statement("SELECT payload FROM meal_state WHERE id = 1", db) { stmt in
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return MealState() }
            guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw MealError.storage }
            return try JSONDecoder().decode(MealState.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
        }
    }

    private func write(_ state: MealState, _ db: OpaquePointer) throws {
        try beforeWrite()
        let data = try JSONEncoder().encode(state)
        try statement("INSERT OR REPLACE INTO meal_state (id, payload) VALUES (1, ?)", db) { stmt in
            try data.withUnsafeBytes { bytes in
                guard sqlite3_bind_blob(stmt, 1, bytes.baseAddress, Int32(data.count), nil) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_DONE else { throw MealError.storage }
            }
        }
    }

    func snapshot() throws -> MealState { try withDatabase(read) }

    func change(_ action: MealAction, now: Date = Launch.now(), zone: TimeZone = .current) throws -> (MealState, UndoMeal?) {
        try withDatabase { db in
            let previous = try read(db)
            var next = previous
            try next.apply(action, now: now, zone: zone)
            guard next != previous else { return (previous, nil) }
            next.revision += 1
            try write(next, db)
            switch action {
            case .start, .finish: return (next, UndoMeal(previous: previous, revision: next.revision, deadline: now.addingTimeInterval(8)))
            default: return (next, nil)
            }
        }
    }

    func undo(_ token: UndoMeal, now: Date = Launch.now()) throws -> MealState {
        try withDatabase { db in
            let current = try read(db)
            guard now < token.deadline, current.revision == token.revision else { throw MealError.stale }
            var restored = token.previous
            restored.revision = current.revision + 1
            restored.milestoneSeen.formUnion(current.milestoneSeen)
            try write(restored, db)
            return restored
        }
    }

    func resetForTesting(_ state: MealState) throws {
        guard Launch.testing else { return }
        try withDatabase { try write(state, $0) }
    }
}
