#if SQLITE_ENABLE_SNAPSHOT || (!GRDBCUSTOMSQLITE && !GRDBCIPHER)
/// A long-live read-only WAL transaction.
///
/// `WALSnapshotTransaction` **takes ownership** of its reader
/// `SerializedDatabase` (TODO: make it a move-only type eventually).
final class WALSnapshotTransaction: @unchecked Sendable {
    // @unchecked because `release` is protected by `reader`.
    
    private let reader: SerializedDatabase
    
    // nil when closed
    private var release: (@Sendable (_ isInsideTransaction: Bool) -> Void)?
    
    /// The state of the database at the beginning of the transaction.
    let walSnapshot: WALSnapshot
    
    /// Creates a long-live WAL transaction on a read-only connection.
    ///
    /// The `release` closure is always called. It is called when the
    /// `WALSnapshotTransaction` is deallocated, or if the initializer
    /// throws.
    ///
    /// In normal operations, the argument to `release` is always false,
    /// meaning that the connection is no longer in a transaction. If true,
    /// the connection has been left inside a transaction, due to
    /// some error.
    ///
    /// Usage:
    ///
    /// ```swift
    /// let transaction = WALSnapshotTransaction(
    ///     reader: reader,
    ///     release: { isInsideTransaction in
    ///         ...
    ///     })
    /// ```
    ///
    /// - parameter reader: A read-only database connection.
    /// - parameter release: A closure to call when the read-only connection
    ///   is no longer used.
    init(
        onReader reader: SerializedDatabase,
        release: @escaping @Sendable (_ isInsideTransaction: Bool) -> Void)
    throws
    {
        assert(reader.configuration.readonly)
        
        do {
            // Open a long-lived transaction, and enter snapshot isolation
            self.walSnapshot = try reader.sync(allowingLongLivedTransaction: true) { db in
                try db.beginTransaction(.deferred)
                try db.execute(sql: "SELECT rootpage FROM sqlite_master LIMIT 1")
                return try WALSnapshot(db)
            }
            self.reader = reader
            self.release = release
        } catch {
            // self is not initialized, so deinit will not run.
            Self.commitAndRelease(reader: reader, release: { _ in release })
            throw error
        }
    }
    
    deinit {
        close()
    }
    
    /// Executes database operations in the snapshot transaction, and
    /// returns their result after they have finished executing.
    func read<T>(_ value: (Database) throws -> T) throws -> T {
        // We should check the validity of the snapshot, as DatabaseSnapshotPool does.
        return try reader.sync { db in
            if release == nil /* closed? */ {
                throw DatabaseError.snapshotIsLost()
            }
            
            return try value(db)
        }
    }
    
    /// Schedules database operations for execution, and
    /// returns immediately.
    func asyncRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void) {
        // We should check the validity of the snapshot, as DatabaseSnapshotPool does.
        reader.async { db in
            if self.release == nil /* closed? */ {
                value(.failure(DatabaseError.snapshotIsLost()))
            } else {
                value(.success(db))
            }
        }
    }
    
    func close() {
        Self.commitAndRelease(reader: reader) { _ in
            let release = self.release
            // Commit and close only once!
            self.release = nil
            return release
        }
    }
    
    // Commits and release iff the `release` argument returns a non-nil closure.
    private static func commitAndRelease(
        reader: SerializedDatabase,
        release: (Database) -> ((_ isInsideTransaction: Bool) -> Void)?)
    {
        // WALSnapshotTransaction may be deinitialized in the dispatch
        // queue of its reader: allow reentrancy.
        let (r, isInsideTransaction) = reader.reentrantSync(allowingLongLivedTransaction: false) { db in
            let r = release(db)
            
            // Only commit if not released yet
            if r != nil {
                try? db.commit()
            }
            return (r, db.isInsideTransaction)
        }
        r?(isInsideTransaction)
    }
}
#endif
