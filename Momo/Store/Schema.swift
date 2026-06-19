//
//  Schema.swift
//  Irreversible tiered schema as named, ordered, immutable DatabaseMigrator migrations
//  (KTD2 / KTD4 / KTD4a). This is the one irreversible decision in the plan — the column
//  set is fixed against the U2/U4 Sample shape and the Phase-2 reads (U9/U10/U11):
//
//    * ts INTEGER PRIMARY KEY = UTC epoch seconds (KTD2) — aligned per-tier bucket starts.
//    * scalar metrics REAL NULL, AVG + MAX per gauge (KTD4) so the 1h tier keeps spikes.
//    * proc_1s / proc_1m keyed (ts, subsystem, pid) with value (avg) + value_max (KTD4a);
//      NO proc table at 1h — names age out (KTD4). Leaf name only (KTD4b).
//    * (ts, subsystem) indexed on proc tables so U11's point-at-ts lookup is cheap.
//    * a gap = absence of rows; a present NULL metric = sensor absent (U9 gap detection).
//
import Foundation
import GRDB

enum Schema {
    /// Named, ordered, immutable migrations. New schema versions append a NEW migration;
    /// existing ones are never edited (GRDB DatabaseMigrator contract).
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_tiered_schema") { db in
            for table in ["samples_1s", "samples_1m", "samples_1h"] {
                // fg_app is written at 1s/1m and left NULL at 1h (names age out, KTD4);
                // keeping the column on all tiers keeps the row type uniform.
                try db.execute(sql: """
                    CREATE TABLE \(table) (
                        ts                INTEGER PRIMARY KEY,
                        cpu_avg           REAL,
                        cpu_max           REAL,
                        mem_used_avg      REAL,
                        mem_used_max      REAL,
                        mem_total         REAL,
                        mem_pressure_max  REAL,
                        swap_used_avg     REAL,
                        swap_used_max     REAL,
                        disk_free         REAL,
                        disk_total        REAL,
                        disk_read_avg     REAL,
                        disk_read_max     REAL,
                        disk_write_avg    REAL,
                        disk_write_max    REAL,
                        net_rx_avg        REAL,
                        net_rx_max        REAL,
                        net_tx_avg        REAL,
                        net_tx_max        REAL,
                        temp_max_avg      REAL,
                        temp_max_max      REAL,
                        fan_max_avg       REAL,
                        fan_max_max       REAL,
                        thermal_max       REAL,
                        fg_app            TEXT
                    ) WITHOUT ROWID
                    """)
            }

            // Per-process side tables: 1s and 1m only (KTD4 — no 1h proc table).
            for table in ["proc_1s", "proc_1m"] {
                try db.execute(sql: """
                    CREATE TABLE \(table) (
                        ts         INTEGER NOT NULL,
                        subsystem  TEXT NOT NULL,
                        pid        INTEGER NOT NULL,
                        name       TEXT NOT NULL,
                        value      REAL NOT NULL,
                        value_max  REAL NOT NULL,
                        -- name is in the PK so a (pid,name) change within one bucket is
                        -- two distinct rows, never summed (KTD4a / U6 PID-reuse scenario);
                        -- lookups still use the (ts, subsystem) index below.
                        PRIMARY KEY (ts, subsystem, pid, name)
                    ) WITHOUT ROWID
                    """)
                // (ts, subsystem) point lookup for U11 causal drill-down.
                try db.execute(sql:
                    "CREATE INDEX idx_\(table)_ts_sub ON \(table) (ts, subsystem)")
            }
        }

        return migrator
    }
}
