const MAX_POSTGRES_BIGINT = 9223372036854775807n;

function parseUnsignedBigIntString(value, { field = 'cursor', allowNumber = false } = {}) {
  let text;
  if (allowNumber && Number.isSafeInteger(value) && value >= 0) {
    text = String(value);
  } else if (typeof value === 'string') {
    text = value;
  } else {
    throw new TypeError(`${field} must be a decimal string`);
  }
  if (!/^(0|[1-9]\d*)$/.test(text)) {
    throw new TypeError(`${field} must be a non-negative decimal integer`);
  }
  const parsed = BigInt(text);
  if (parsed > MAX_POSTGRES_BIGINT) {
    throw new RangeError(`${field} exceeds PostgreSQL BIGINT`);
  }
  return parsed;
}

function parseCursor(value = '0') {
  return parseUnsignedBigIntString(value, { field: 'cursor' });
}

function serializeCursor(value) {
  if (typeof value === 'bigint') {
    if (value < 0n || value > MAX_POSTGRES_BIGINT) throw new RangeError('cursor is outside PostgreSQL BIGINT');
    return value.toString(10);
  }
  return parseCursor(String(value)).toString(10);
}

function parseVersion(value, { allowNull = false } = {}) {
  if ((value === null || value === undefined) && allowNull) return null;
  return parseUnsignedBigIntString(value, { field: 'baseVersion', allowNumber: true });
}

module.exports = {
  MAX_POSTGRES_BIGINT,
  parseCursor,
  parseVersion,
  serializeCursor
};
