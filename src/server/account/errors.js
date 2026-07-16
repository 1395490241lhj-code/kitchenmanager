class AccountDeletionError extends Error {
  constructor(code, message, status = 400, options = {}) {
    super(message);
    this.name = 'AccountDeletionError';
    this.code = code;
    this.status = status;
    this.cause = options.cause;
  }
}

module.exports = { AccountDeletionError };
