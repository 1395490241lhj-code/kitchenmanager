// Phase 2C-2 in-process metric counters. Deliberately not a Prometheus/OTel
// client — this is a documented starting point (see
// docs/BACKEND_OBSERVABILITY.md) that emits stable-named counters/values a
// human can grep in Render's log search (via the structured logger) and a
// test can assert on directly via snapshot(). No raw/high-cardinality label
// (userId, IP, mutationId) is ever attached to a label set — only route/
// status/result-shaped labels.
//
// Swapping this for Datadog/Prometheus/OTel later only means replacing this
// module's implementation; call sites only ever call increment()/observe().

const SYNC_METRIC_NAMES = Object.freeze({
  SYNC_REQUEST_TOTAL: 'sync_request_total',
  SYNC_REQUEST_SUCCESS: 'sync_request_success',
  SYNC_REQUEST_FAILURE: 'sync_request_failure',
  SYNC_RATE_LIMITED: 'sync_rate_limited',
  SYNC_UPGRADE_REQUIRED: 'sync_upgrade_required',
  SYNC_MUTATION_OPERATIONS: 'sync_mutation_operations',
  SYNC_MUTATION_CONFLICT: 'sync_mutation_conflict',
  SYNC_MUTATION_REJECTED: 'sync_mutation_rejected',
  SYNC_MUTATION_APPLIED: 'sync_mutation_applied',
  SYNC_MUTATION_DUPLICATE: 'sync_mutation_duplicate',
  SYNC_READ_LATENCY: 'sync_read_latency',
  SYNC_WRITE_LATENCY: 'sync_write_latency',
  BACKEND_5XX: 'backend_5xx'
});

function labelKey(name, labels) {
  const sortedKeys = Object.keys(labels).sort();
  const labelPart = sortedKeys.map((key) => `${key}=${labels[key]}`).join(',');
  return labelPart ? `${name}{${labelPart}}` : name;
}

function createMetricsRegistry() {
  const counters = new Map();
  const observations = new Map();

  function increment(name, amount = 1, labels = {}) {
    const key = labelKey(name, labels);
    const next = (counters.get(key) || 0) + amount;
    counters.set(key, next);
    return next;
  }

  function observe(name, value, labels = {}) {
    const key = labelKey(name, labels);
    const list = observations.get(key) || [];
    list.push(value);
    observations.set(key, list);
    return list.length;
  }

  function snapshot() {
    const counterSnapshot = {};
    for (const [key, value] of counters) counterSnapshot[key] = value;
    const observationSnapshot = {};
    for (const [key, values] of observations) observationSnapshot[key] = values.slice();
    return { counters: counterSnapshot, observations: observationSnapshot };
  }

  // Test/diagnostic only — never used by request-handling code.
  function _clear() {
    counters.clear();
    observations.clear();
  }

  return { increment, observe, snapshot, _clear };
}

module.exports = { createMetricsRegistry, SYNC_METRIC_NAMES };
