import CSQLite
import Foundation

extension RunStore {
  static let schema = """
    CREATE TABLE IF NOT EXISTS events(
        event_id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        occurred_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS events_run_id ON events(run_id);
    CREATE TABLE IF NOT EXISTS runs(
        run_id TEXT PRIMARY KEY,
        harness TEXT NOT NULL,
        harness_session_id TEXT,
        terminal_id TEXT,
        executable TEXT,
        pid INTEGER,
        project_root TEXT,
        cwd TEXT,
        branch TEXT,
        git_insertions INTEGER,
        git_deletions INTEGER,
        prompt_preview TEXT,
        status TEXT NOT NULL,
        unread INTEGER NOT NULL DEFAULT 0,
        started_at REAL NOT NULL,
        last_event_at REAL NOT NULL,
        ended_at REAL,
        exit_code INTEGER,
        -- Kept last so a fresh database matches the column order an ALTER-migrated one ends up with.
        working_since REAL,
        last_turn_duration REAL,
        model_id TEXT
    );
    CREATE INDEX IF NOT EXISTS runs_status ON runs(status, last_event_at DESC);
    CREATE INDEX IF NOT EXISTS runs_recent ON runs(last_event_at DESC) WHERE ended_at IS NOT NULL;
    """

  /// Existing databases were created with `CREATE TABLE IF NOT EXISTS`, so new columns have to
  /// be added explicitly. Fresh databases already have these columns from `schema`.
  func migrateRunGitDiffstatColumns() throws {
    try withLock {
      let columns = try tableColumns("runs")
      if !columns.contains("git_insertions") {
        try database.execute("ALTER TABLE runs ADD COLUMN git_insertions INTEGER")
      }
      if !columns.contains("git_deletions") {
        try database.execute("ALTER TABLE runs ADD COLUMN git_deletions INTEGER")
      }
    }
  }

  /// Turn timing was added after the first releases. Existing rows start out null and pick up real
  /// values on their next event; the sidebar simply shows no duration until then.
  func migrateRunTurnTimingColumns() throws {
    try withLock {
      let columns = try tableColumns("runs")
      if !columns.contains("working_since") {
        try database.execute("ALTER TABLE runs ADD COLUMN working_since REAL")
      }
      if !columns.contains("last_turn_duration") {
        try database.execute("ALTER TABLE runs ADD COLUMN last_turn_duration REAL")
      }
    }
  }

  /// Model identity was added after run persistence. Existing rows remain unknown until a hook,
  /// wrapper event, or context sample supplies the model.
  func migrateRunModelColumn() throws {
    try withLock {
      let columns = try tableColumns("runs")
      if !columns.contains("model_id") {
        try database.execute("ALTER TABLE runs ADD COLUMN model_id TEXT")
      }
    }
  }

  private func tableColumns(_ table: String) throws -> Set<String> {
    let statement = try database.prepare("PRAGMA table_info(\(table))")
    defer { sqlite3_finalize(statement) }
    var names = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = sqlite3_column_text(statement, 1) else { continue }
      names.insert(String(cString: name))
    }
    return names
  }

  /// Merges legacy `orphan-<harness>-<session>` rows (an earlier run-ID scheme) into the
  /// harness-neutral `orphan-<session>` identity. Runs on every open: there is no schema version
  /// gate, so stale CLI helpers that still write legacy IDs keep being folded in.
  func migrateHarnessQualifiedOrphans() throws {
    try withLock {
      try database.withTransaction {
        let statement = try database.prepare(
          """
          SELECT \(RunRowCodec.columns)
          FROM runs
          WHERE harness_session_id IS NOT NULL AND run_id LIKE 'orphan-%'
          """)
        defer { sqlite3_finalize(statement) }

        var legacySessions = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
          let run = RunRowCodec.decode(statement)
          guard let sessionID = run.harnessSessionID,
            run.runID == "orphan-\(run.harness.rawValue)-\(sessionID)"
          else { continue }
          legacySessions.insert(sessionID)
        }

        for sessionID in legacySessions {
          try migrateHarnessQualifiedOrphanUnlocked(sessionID: sessionID)
        }
      }
    }
  }

  private func migrateHarnessQualifiedOrphanUnlocked(sessionID: String) throws {
    let canonicalID = "orphan-\(sessionID)"
    let legacyIDs = Harness.allCases.map { "orphan-\($0.rawValue)-\(sessionID)" }
    let candidates = try ([canonicalID] + legacyIDs).compactMap { try runUnlocked(id: $0) }
    guard !candidates.isEmpty else { return }

    let preferred = candidates.max { lhs, rhs in
      if lhs.lastEventAt != rhs.lastEventAt {
        return lhs.lastEventAt < rhs.lastEventAt
      }
      return harnessPriority(lhs.harness) < harnessPriority(rhs.harness)
    }!
    let preferredHarness =
      candidates.contains(where: { $0.harness == .cursor }) ? Harness.cursor : preferred.harness

    var merged = preferred
    merged.runID = canonicalID
    merged.harness = preferredHarness
    merged.startedAt = candidates.map(\.startedAt).min() ?? preferred.startedAt
    merged.lastEventAt = candidates.map(\.lastEventAt).max() ?? preferred.lastEventAt

    let metadataOrder =
      candidates.filter { $0.harness == preferredHarness }
      + candidates.filter { $0.harness != preferredHarness }
    merged.harnessSessionID = metadataOrder.compactMap(\.harnessSessionID).first
    merged.ghosttyTerminalID = metadataOrder.compactMap(\.ghosttyTerminalID).first
    merged.executable = metadataOrder.compactMap(\.executable).first
    merged.processID = metadataOrder.compactMap(\.processID).first
    merged.projectRoot = metadataOrder.compactMap(\.projectRoot).first
    merged.workingDirectory = metadataOrder.compactMap(\.workingDirectory).first
    merged.branch = metadataOrder.compactMap(\.branch).first
    merged.gitDiffstat = metadataOrder.compactMap(\.gitDiffstat).first
    merged.promptPreview = metadataOrder.compactMap(\.promptPreview).first
    merged.modelID = metadataOrder.compactMap(\.modelID).first

    for run in candidates where run.runID != canonicalID {
      try database.update(
        "UPDATE events SET run_id = ? WHERE run_id = ?",
        values: [.text(canonicalID), .text(run.runID)]
      )
      try database.update("DELETE FROM runs WHERE run_id = ?", values: [.text(run.runID)])
    }
    try upsertUnlocked(merged)
  }

  private func harnessPriority(_ harness: Harness) -> Int {
    harness == .cursor ? 1 : 0
  }
}
