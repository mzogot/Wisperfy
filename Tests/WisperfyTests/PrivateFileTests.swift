import Foundation
import Testing
@testable import Wisperfy

@Suite struct PrivateFileTests {
    private func mode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func writesUserOnlyFileInUserOnlyDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisperfy-privatefile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Wisperfy").appendingPathComponent("history.json")

        try PrivateFile.write(Data("[]".utf8), to: url)

        #expect(try mode(of: url.path) == PrivateFile.fileMode)
        #expect(try mode(of: url.deletingLastPathComponent().path) == PrivateFile.directoryMode)
        #expect(try Data(contentsOf: url) == Data("[]".utf8))
    }

    @Test func tightensAnExistingLooseFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisperfy-privatefile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Wisperfy")
        let url = directory.appendingPathComponent("vocabulary.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try PrivateFile.write(Data("new".utf8), to: url)

        #expect(try mode(of: url.path) == PrivateFile.fileMode)
        #expect(try mode(of: directory.path) == PrivateFile.directoryMode)
    }
}
