import Foundation

/// Writes a file that only this user can read.
///
/// `~/Library` is user-private already, but a file created with the default umask is
/// 0644 in a 0755 directory. History and vocabulary contain everything the user has
/// ever dictated, so they are kept at 0600 in a 0700 directory: defense in depth, and
/// it holds if the folder is ever copied somewhere less private.
enum PrivateFile {
    static let directoryMode = 0o700
    static let fileMode = 0o600

    static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryMode]
        )
        // createDirectory only applies attributes to directories it creates.
        try manager.setAttributes([.posixPermissions: directoryMode], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: fileMode], ofItemAtPath: url.path)
    }
}
