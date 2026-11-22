import XCTest
import SQLite3
@testable import RunnerCore

final class SQLitePreviewTests: XCTestCase {
    func testTablesSchemaValuesAndQuotedIdentifiersWithoutChangingSource() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.db")
        try withDatabase(source) { database in
            try execute(database, """
            CREATE TABLE "odd"";name" (id INTEGER, name TEXT, score REAL, missing, bytes BLOB);
            INSERT INTO "odd"";name" VALUES (42, '日本語', 1.25, NULL, X'00FF');
            INSERT INTO "odd"";name" VALUES (43, '', 0.0, NULL, X'');
            CREATE VIEW names AS SELECT name FROM "odd"";name";
            """)
        }
        let original = try Data(contentsOf: source)
        let manager = FileAccessManager()
        let staged = try await manager.stageSQLitePreview(path: source.path)
        let document = SQLiteDocument(url: staged.url)
        let schema = try await document.schema()
        XCTAssertEqual(schema.tables.map(\.name), ["names", "odd\";name"])
        XCTAssertEqual(schema.tables.first?.type, "view")
        let table = try XCTUnwrap(schema.tables.last)
        XCTAssertTrue(table.sql.contains("CREATE TABLE"))
        let page = try await document.page(table: table, offset: 0)
        XCTAssertEqual(page.columns, ["id", "name", "score", "missing", "bytes"])
        XCTAssertEqual(page.rows.first, ["42", "日本語", "1.25", "NULL", "BLOB · 2 bytes · 00 FF"])
        XCTAssertEqual(page.rows.last?[1], "（空文字列）")
        XCTAssertEqual(page.rows.last?[4], "BLOB · 0 bytes")
        XCTAssertFalse(page.hasMore)
        let view = try await document.page(table: schema.tables[0], offset: 0)
        XCTAssertEqual(view.rows.first, ["日本語"])
        XCTAssertEqual(try Data(contentsOf: source), original)
        let grants = await manager.currentGrants()
        XCTAssertTrue(grants.isEmpty)
        await manager.closeDocumentPreview(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["fixture.db"])
    }

    func testPaginationEmptyTableAndLongValues() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.sqlite")
        try withDatabase(source) { database in
            try execute(database, """
            CREATE TABLE items (id INTEGER, content TEXT);
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<201)
            INSERT INTO items SELECT x, printf('%02000d', x) FROM n;
            CREATE TABLE empty (value);
            """)
        }
        let manager = FileAccessManager()
        let staged = try await manager.stageSQLitePreview(path: source.path)
        let document = SQLiteDocument(url: staged.url)
        let schema = try await document.schema()
        let table = try XCTUnwrap(schema.tables.first { $0.name == "items" })
        let first = try await document.page(table: table, offset: 0)
        let second = try await document.page(table: table, offset: 100)
        let last = try await document.page(table: table, offset: 200)
        XCTAssertEqual(first.rows.count, 100)
        XCTAssertTrue(first.hasMore)
        XCTAssertTrue(first.rows[0][1].hasSuffix("…（省略）"))
        XCTAssertEqual(second.rows.first?[0], "101")
        XCTAssertTrue(second.hasMore)
        XCTAssertEqual(last.rows.first?[0], "201")
        XCTAssertFalse(last.hasMore)
        let empty = try await document.page(table: XCTUnwrap(schema.tables.first { $0.name == "empty" }), offset: 0)
        XCTAssertEqual(empty.columns, ["value"])
        XCTAssertTrue(empty.rows.isEmpty)
        do { _ = try await document.page(table: table, offset: -1); XCTFail("Negative offset accepted") } catch {}
        do { _ = try await document.page(table: table, offset: SQLiteDocument.maximumOffset + 1); XCTFail("Unbounded offset accepted") } catch {}
        await manager.closeDocumentPreview(staged)
    }

    func testWALSnapshotIncludesCommittedRowsWithoutTouchingSourceSidecars() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("live.sqlite")
        // Keep the writer open, otherwise SQLite can checkpoint and remove WAL.
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
        let database = try XCTUnwrap(writer)
        defer { sqlite3_close(database) }
        try execute(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE items (value); INSERT INTO items VALUES ('WALにだけ存在');")
        let paths = [source.path, source.path + "-wal", source.path + "-shm"]
        let originals = try paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let manager = FileAccessManager()
        let staged = try await manager.stageSQLitePreview(path: source.path)
        let document = SQLiteDocument(url: staged.url)
        let schema = try await document.schema()
        let page = try await document.page(table: XCTUnwrap(schema.tables.first), offset: 0)
        XCTAssertEqual(page.rows, [["WALにだけ存在"]])
        XCTAssertEqual(try paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }, originals)
        await manager.closeDocumentPreview(staged)
    }

    func testInvalidEncryptedOversizedAndSymbolicSourcesAreRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("invalid.db")
        try Data(repeating: 0x41, count: 128).write(to: source)
        let manager = FileAccessManager()
        do { _ = try await manager.stageSQLitePreview(path: source.path); XCTFail("Invalid header accepted") } catch {}
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(SQLiteSnapshot.maximumBytes + 1))
        try handle.close()
        do { _ = try await manager.stageSQLitePreview(path: source.path); XCTFail("Oversized file accepted") } catch {}
        let valid = root.appendingPathComponent("valid.db")
        try withDatabase(valid) { try execute($0, "CREATE TABLE items (value);") }
        let link = root.appendingPathComponent("link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
        do { _ = try await manager.stageSQLitePreview(path: link.path); XCTFail("Symbolic file accepted") } catch {}
        let walLink = URL(fileURLWithPath: valid.path + "-wal")
        try FileManager.default.createSymbolicLink(at: walLink, withDestinationURL: source)
        do { _ = try await manager.stageSQLitePreview(path: valid.path); XCTFail("Symbolic WAL accepted") } catch {}
    }

    func testRollbackJournalIsNotSilentlyIgnored() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.db")
        try withDatabase(source) { try execute($0, "CREATE TABLE items (value);") }
        let journal = URL(fileURLWithPath: source.path + "-journal")
        let bytes = Data("pending journal".utf8)
        try bytes.write(to: journal)
        do { _ = try await FileAccessManager().stageSQLitePreview(path: source.path); XCTFail("Journal ignored") } catch {}
        XCTAssertEqual(try Data(contentsOf: journal), bytes)
    }

    func testExpensiveViewIsInterrupted() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.db")
        try withDatabase(source) { database in
            try execute(database, "CREATE VIEW expensive AS WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT sum(x) FROM n;")
        }
        let manager = FileAccessManager()
        let staged = try await manager.stageSQLitePreview(path: source.path)
        let document = SQLiteDocument(url: staged.url)
        let schema = try await document.schema()
        do { _ = try await document.page(table: XCTUnwrap(schema.tables.first), offset: 0); XCTFail("Unbounded view completed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("2秒")) }
        await manager.closeDocumentPreview(staged)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SQLitePreviewTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func withDatabase(_ url: URL, operation: (OpaquePointer) throws -> Void) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open(url.path, &connection)
        defer { if let connection { sqlite3_close(connection) } }
        XCTAssertEqual(result, SQLITE_OK)
        try operation(XCTUnwrap(connection))
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw RunnerError(String(cString: sqlite3_errmsg(database))) }
    }
}
