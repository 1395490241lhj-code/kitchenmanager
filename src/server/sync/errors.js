class SyncError extends Error {
  constructor(code, message, status = 400, options = {}) {
    super(message);
    this.name = 'SyncError';
    this.code = code;
    this.status = status;
    this.details = options.details || null;
    this.cause = options.cause;
  }
}

class SyncRepositoryError extends SyncError {
  constructor(code = 'sync_unavailable', message = 'Sync repository is temporarily unavailable', options = {}) {
    super(code, message, 503, options);
    this.name = 'SyncRepositoryError';
  }
}

function toSyncError(error) {
  if (error instanceof SyncError) return error;
  return new SyncRepositoryError('sync_unavailable', 'Sync service is temporarily unavailable', { cause: error });
}

module.exports = { SyncError, SyncRepositoryError, toSyncError };
