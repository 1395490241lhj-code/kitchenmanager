const { createHash } = require('crypto');

const SYNC_ENTITY_NAMESPACE = '5cf6248b-86c5-5c71-9f1d-cc0b46224718';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isUuid(value) {
  return typeof value === 'string' && UUID_RE.test(value);
}

function uuidToBytes(uuid) {
  return Buffer.from(uuid.replaceAll('-', ''), 'hex');
}

function bytesToUuid(bytes) {
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

function uuidV5(name, namespace = SYNC_ENTITY_NAMESPACE) {
  if (!isUuid(namespace)) throw new TypeError('namespace must be a UUID');
  const digest = createHash('sha1')
    .update(uuidToBytes(namespace))
    .update(Buffer.from(String(name), 'utf8'))
    .digest()
    .subarray(0, 16);
  digest[6] = (digest[6] & 0x0f) | 0x50;
  digest[8] = (digest[8] & 0x3f) | 0x80;
  return bytesToUuid(digest);
}

function deterministicSyncEntityId({ scopeType, scopeId, entityType, legacyKey }) {
  if (!['household', 'user'].includes(scopeType)) throw new TypeError('scopeType must be household or user');
  if (!isUuid(scopeId)) throw new TypeError('scopeId must be a UUID');
  if (!/^[a-z][a-z0-9_]{1,63}$/.test(entityType || '')) throw new TypeError('entityType is invalid');
  if (typeof legacyKey !== 'string' || legacyKey.length < 1 || legacyKey.length > 512) {
    throw new TypeError('legacyKey must contain 1-512 characters');
  }
  // Only the hash-derived UUID leaves this function; callers must persist it and
  // must never log the source legacy key, which may contain user-entered text.
  return uuidV5(`${scopeType}\u001f${scopeId.toLowerCase()}\u001f${entityType}\u001f${legacyKey}`);
}

module.exports = {
  SYNC_ENTITY_NAMESPACE,
  deterministicSyncEntityId,
  isUuid,
  uuidV5
};
