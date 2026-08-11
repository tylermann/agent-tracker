import Foundation

/// Writes files atomically (temp file + rename into place), preserving or setting POSIX
/// permissions, with an optional timestamped backup of the previous contents.
enum AtomicFileWriter {
  static func write(
    _ data: Data,
    to url: URL,
    permissions: Int?,
    backup: Bool,
    fileManager: FileManager = .default
  ) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: nil
    )
    if backup, fileManager.fileExists(atPath: url.path) {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyyMMdd-HHmmss"
      let backupURL = url.appendingPathExtension(
        "agent-tracker-backup-\(formatter.string(from: Date()))")
      if !fileManager.fileExists(atPath: backupURL.path) {
        try fileManager.copyItem(at: url, to: backupURL)
      }
    }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let existingPermissions =
      (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
    try data.write(to: temporary, options: .atomic)
    if let permissions {
      try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
    } else if let existingPermissions {
      try fileManager.setAttributes(
        [.posixPermissions: existingPermissions], ofItemAtPath: temporary.path)
    }
    if fileManager.fileExists(atPath: url.path) {
      _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
    } else {
      try fileManager.moveItem(at: temporary, to: url)
    }
  }
}
