import XCTest
@testable import CochleaCore

/// The app reads the same file `dictate` writes, so these fix the shape of
/// that contract from the Swift side.
final class LexiconFileTests: XCTestCase {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
    }

    func testItDecodesWhatDictateWrites() throws {
        // Byte-for-byte the shape `Lexicon.to_dict` produces, including the
        // snake_case key, which is the one thing a Swift Codable will silently
        // get wrong.
        let json = """
        {
          "version": 1,
          "language": "en",
          "entries": [
            {"term": "kubectl", "boost": 1.5, "added_at": 1.0,
             "last_used_at": 2.0, "hits": 3, "rejections": 0},
            {"term": "eval gate", "boost": 1.5, "added_at": 1.0,
             "last_used_at": 2.0, "hits": 0, "rejections": 1}
          ],
          "canonical": {"kube-ctl": "kubectl"}
        }
        """
        let file = try JSONDecoder().decode(LexiconFile.self,
                                            from: Data(json.utf8))
        XCTAssertEqual(file.entries.count, 2)
        XCTAssertEqual(file.entries[0].hits, 3)
        XCTAssertEqual(file.entries[0].lastUsedAt, 2.0)
        XCTAssertEqual(file.canonical["kube-ctl"], "kubectl")
    }

    func testAPhraseIsDistinguishedFromAWord() {
        // They behave differently -- a phrase is only boosted in context -- so
        // the list has to be able to say which is which.
        XCTAssertTrue(LexiconFile.Entry(term: "eval gate").isPhrase)
        XCTAssertFalse(LexiconFile.Entry(term: "kubectl").isPhrase)
    }

    func testAHandEditedFileMissingBookkeepingStillLoads() {
        // The format is deliberately plain so a user can read and edit it
        // (D10). Someone who adds a term by hand will not write `hits`.
        let json = #"{"entries": [{"term": "kubectl"}]}"#
        let file = try? JSONDecoder().decode(LexiconFile.self, from: Data(json.utf8))
        XCTAssertEqual(file?.entries.first?.term, "kubectl")
        XCTAssertEqual(file?.entries.first?.hits, 0)
    }

    func testAMissingFileIsAnEmptyLexiconNotAFailure() {
        // The normal state before the first import. The settings window has to
        // open regardless.
        XCTAssertTrue(LexiconFile.load(from: temporaryURL()).entries.isEmpty)
    }

    func testACorruptFileDoesNotStopTheWindowOpening() throws {
        let url = temporaryURL()
        try Data("{ not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(LexiconFile.load(from: url).entries.isEmpty)
    }

    func testEntriesAreOrderedByHowOftenTheyHaveWon() {
        // Hits tell an entry earning its place from one only costing F2
        // headroom. Insertion order says nothing.
        var file = LexiconFile()
        file.entries = [
            LexiconFile.Entry(term: "alpha", hits: 0),
            LexiconFile.Entry(term: "beta", hits: 9),
            LexiconFile.Entry(term: "gamma", hits: 4),
        ]
        XCTAssertEqual(file.sorted.map(\.term), ["beta", "gamma", "alpha"])
    }

    func testRemovingAnEntryLeavesTheRest() {
        var file = LexiconFile()
        file.entries = [LexiconFile.Entry(term: "a"), LexiconFile.Entry(term: "b")]
        file.remove("a")
        XCTAssertEqual(file.entries.map(\.term), ["b"])
    }

    func testSavingKeepsTheFileOwnerOnly() throws {
        // `dictate` writes 0600 and an atomic replace does not carry
        // permissions across, so the app must set them again or it quietly
        // widens access to terms taken from the user's messages.
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var file = LexiconFile()
        file.entries = [LexiconFile.Entry(term: "kubectl")]
        try file.save(to: url)
        let mode = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    func testASavedFileIsReadableByDictateAgain() throws {
        // The round trip that matters: the app writes, the helper reads. The
        // term is the only field `Lexicon.from_dict` requires.
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var file = LexiconFile()
        file.entries = [LexiconFile.Entry(term: "kubectl", boost: 1.5, hits: 2)]
        try file.save(to: url)
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any]
        let entries = object?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.first?["term"] as? String, "kubectl")
        XCTAssertEqual(entries?.first?["last_used_at"] as? Double, 0)
    }
}
