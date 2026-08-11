enum ShellQuoting {
  /// Single-quotes a value for POSIX shells.
  static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
