import Darwin
import Foundation

/// Spawns a child process in the caller's own foreground process group and waits for it.
///
/// Foundation's `Process` creates a separate process group on macOS. An interactive child in that
/// group is backgrounded relative to its parent, so its first terminal read receives SIGTTIN and
/// it appears to hang. This launcher keeps the child in the caller's group instead.
public enum ForegroundProcessLauncher {
  public static func spawn(
    executable: String,
    arguments: [String],
    environment: [String: String]
  ) throws -> pid_t {
    var attributes: posix_spawnattr_t? = nil
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw POSIXError(.EINVAL)
    }
    defer { posix_spawnattr_destroy(&attributes) }

    var signals = sigset_t()
    sigemptyset(&signals)
    sigaddset(&signals, SIGINT)
    sigaddset(&signals, SIGQUIT)
    guard posix_spawnattr_setsigdefault(&attributes, &signals) == 0,
      posix_spawnattr_setpgroup(&attributes, getpgrp()) == 0
    else { throw POSIXError(.EINVAL) }

    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF)
    guard posix_spawnattr_setflags(&attributes, flags) == 0 else {
      throw POSIXError(.EINVAL)
    }

    var childPID: pid_t = 0
    let environmentEntries = environment.map { "\($0.key)=\($0.value)" }
    let result = withCStringArray([executable] + arguments) { argv in
      withCStringArray(environmentEntries) { envp in
        posix_spawn(&childPID, executable, nil, &attributes, argv, envp)
      }
    }
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
    }
    return childPID
  }

  /// Waits for the child to exit and returns a shell-style status: the exit code, or 128 + signal
  /// number if the child was killed by a signal.
  public static func wait(for pid: pid_t) throws -> Int32 {
    var waitStatus: Int32 = 0
    while waitpid(pid, &waitStatus, 0) == -1 {
      if errno == EINTR { continue }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    let signal = waitStatus & 0x7f
    return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
  }

  private static func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) rethrows -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer {
      for pointer in pointers {
        if let pointer { free(pointer) }
      }
    }
    return try pointers.withUnsafeMutableBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }
}
