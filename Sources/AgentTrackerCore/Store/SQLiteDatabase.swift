import CSQLite
import Foundation

/// Bound parameter values for SQLite statements.
enum SQLiteValue {
  case text(String)
  case int(Int32)
  case double(Double)
  case null
}

/// A minimal wrapper around a raw sqlite3 handle: statement preparation, parameter binding,
/// updates, and transactions. Callers own thread-safety; this type does no locking.
final class SQLiteDatabase {
  static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private(set) var handle: OpaquePointer?

  init(path: String, flags: Int32) throws {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      sqlite3_close(handle)
      throw RunStoreError.open(message)
    }
    self.handle = handle
  }

  deinit {
    sqlite3_close(handle)
  }

  var errorMessage: String {
    handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
  }

  var changedRowCount: Int32 { sqlite3_changes(handle) }

  func execute(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? errorMessage
      sqlite3_free(error)
      throw RunStoreError.sqlite(message)
    }
  }

  func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw RunStoreError.sqlite(errorMessage)
    }
    return statement
  }

  func bind(_ values: [SQLiteValue], to statement: OpaquePointer) {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
      case .int(let number): sqlite3_bind_int(statement, index, number)
      case .double(let number): sqlite3_bind_double(statement, index, number)
      case .null: sqlite3_bind_null(statement, index)
      }
    }
  }

  func update(_ sql: String, values: [SQLiteValue]) throws {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    bind(values, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw RunStoreError.sqlite(errorMessage)
    }
  }

  /// Runs `body` inside BEGIN IMMEDIATE / COMMIT, rolling back if it throws.
  func withTransaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
}
