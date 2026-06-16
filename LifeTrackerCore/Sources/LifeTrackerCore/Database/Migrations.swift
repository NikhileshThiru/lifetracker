import Foundation
import GRDB

extension AppDatabase {
    /// The migrator. Migrations are append-only and never destructive
    /// (we soft-delete, never drop user data).
    var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            try Self.createSchema(db)
            try Self.seedDefaults(db)
        }

        return migrator
    }

    /// The full schema (life-tracker-spec.md section 9). Includes tables for
    /// deferred features (goals, intents, daily_summaries, data_sources,
    /// health_samples, sync_state) so future work is migration-free.
    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

        CREATE TABLE users (
          id TEXT PRIMARY KEY, display_name TEXT,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER
        );

        CREATE TABLE categories (
          id TEXT PRIMARY KEY, user_id TEXT, parent_id TEXT,
          name TEXT NOT NULL,
          kind TEXT NOT NULL,
          color_hex TEXT, icon TEXT,
          is_default INTEGER NOT NULL DEFAULT 0,
          created_by TEXT NOT NULL DEFAULT 'user',
          sort_order INTEGER NOT NULL DEFAULT 0,
          is_archived INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER
        );

        CREATE TABLE check_ins (
          id TEXT PRIMARY KEY, user_id TEXT,
          occurred_at INTEGER NOT NULL, timezone TEXT NOT NULL,
          raw_transcript TEXT NOT NULL,
          audio_path TEXT, stt_engine TEXT NOT NULL,
          input_method TEXT NOT NULL,
          parse_status TEXT NOT NULL,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER
        );

        CREATE TABLE parse_runs (
          id TEXT PRIMARY KEY, check_in_id TEXT NOT NULL,
          parser TEXT NOT NULL,
          model_id TEXT, prompt_version TEXT, raw_output TEXT,
          succeeded INTEGER NOT NULL, error TEXT, created_at INTEGER NOT NULL
        );

        CREATE TABLE events (
          id TEXT PRIMARY KEY, user_id TEXT, category_id TEXT,
          title TEXT, notes TEXT,
          start_at INTEGER, end_at INTEGER,
          state TEXT NOT NULL,
          sequence_hint INTEGER,
          confidence REAL NOT NULL DEFAULT 1.0,
          source TEXT NOT NULL,
          source_ref TEXT,
          origin_check_in_id TEXT,
          is_pinned INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER
        );
        CREATE INDEX idx_events_start ON events(start_at);
        CREATE INDEX idx_events_open ON events(end_at) WHERE end_at IS NULL;
        CREATE INDEX idx_events_category ON events(category_id);
        CREATE INDEX idx_events_state ON events(state);
        CREATE UNIQUE INDEX idx_events_sourceref ON events(source, source_ref) WHERE source_ref IS NOT NULL;

        CREATE TABLE event_revisions (
          id TEXT PRIMARY KEY, event_id TEXT NOT NULL, check_in_id TEXT,
          batch_id TEXT,
          change_kind TEXT NOT NULL,
          before_json TEXT, after_json TEXT, created_at INTEGER NOT NULL
        );
        CREATE INDEX idx_revisions_batch ON event_revisions(batch_id);

        CREATE TABLE goals (
          id TEXT PRIMARY KEY, user_id TEXT, category_id TEXT,
          name TEXT NOT NULL, target_value REAL NOT NULL,
          target_unit TEXT NOT NULL,
          period TEXT NOT NULL,
          direction TEXT NOT NULL,
          active_from INTEGER NOT NULL, active_to INTEGER,
          is_active INTEGER NOT NULL DEFAULT 1,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER
        );

        CREATE TABLE goal_progress (
          id TEXT PRIMARY KEY, goal_id TEXT NOT NULL,
          period_start INTEGER NOT NULL, period_end INTEGER NOT NULL,
          actual_value REAL NOT NULL, computed_at INTEGER NOT NULL
        );

        CREATE TABLE daily_summaries (
          id TEXT PRIMARY KEY, user_id TEXT, date TEXT NOT NULL,
          tracked_minutes INTEGER, gap_minutes INTEGER,
          summary_text TEXT, generated_by TEXT, generated_at INTEGER,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER
        );

        CREATE TABLE intents (
          id TEXT PRIMARY KEY, user_id TEXT, date TEXT NOT NULL,
          text TEXT NOT NULL, rank INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'open',
          linked_event_id TEXT,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER
        );

        CREATE TABLE data_sources (
          id TEXT PRIMARY KEY, kind TEXT NOT NULL,
          display_name TEXT, is_enabled INTEGER NOT NULL DEFAULT 0,
          last_synced_at INTEGER, anchor_token TEXT,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
        );

        CREATE TABLE health_samples (
          id TEXT PRIMARY KEY, hk_uuid TEXT, sample_type TEXT NOT NULL,
          subtype TEXT, start_at INTEGER NOT NULL, end_at INTEGER NOT NULL,
          value REAL, unit TEXT, source_name TEXT, metadata_json TEXT,
          event_id TEXT, imported_at INTEGER NOT NULL, deleted_at INTEGER
        );
        CREATE UNIQUE INDEX idx_health_hkuuid ON health_samples(hk_uuid) WHERE hk_uuid IS NOT NULL;

        CREATE TABLE settings (key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at INTEGER NOT NULL);

        CREATE TABLE sync_state (table_name TEXT PRIMARY KEY, last_pushed_at INTEGER, last_pulled_at INTEGER, cursor TEXT);
        """)
    }

    /// Seeds schema version, a single local user, and the default categories.
    /// Categories are dynamic; these defaults are starting points the user can
    /// rename/recolor/archive.
    static func seedDefaults(_ db: Database) throws {
        let now = Clock.nowMillis()

        try db.execute(
            sql: "INSERT INTO meta (key, value) VALUES (?, ?)",
            arguments: ["schema_version", "1"]
        )

        let userID = newID()
        try db.execute(
            sql: """
            INSERT INTO users (id, display_name, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            """,
            arguments: [userID, "Me", now, now]
        )

        // (name, kind, color_hex, SF Symbol icon) — dark-mode-friendly palette.
        let defaults: [(name: String, kind: String, color: String, icon: String)] = [
            ("Sleep", "sleep", "#5E5CE6", "bed.double.fill"),
            ("Work", "work", "#0A84FF", "laptopcomputer"),
            ("Exercise", "exercise", "#30D158", "figure.run"),
            ("Social", "social", "#FF9F0A", "person.2.fill"),
            ("Chores", "chore", "#8E8E93", "checklist"),
            ("Leisure", "leisure", "#BF5AF2", "gamecontroller.fill"),
            ("Commute", "transit", "#64D2FF", "car.fill"),
            ("Meals", "meal", "#FF6482", "fork.knife"),
            ("Other", "other", "#98989D", "circle.dashed"),
        ]

        for (index, c) in defaults.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO categories
                  (id, user_id, name, kind, color_hex, icon, is_default, created_by, sort_order, is_archived, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 1, 'user', ?, 0, ?, ?)
                """,
                arguments: [newID(), userID, c.name, c.kind, c.color, c.icon, index, now, now]
            )
        }
    }
}
