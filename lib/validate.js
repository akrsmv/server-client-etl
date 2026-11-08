'use strict';

// Shared event contract, enforced at the edge (server) and again at the
// consumer (processor): the log is append-only and may carry lines written
// before validation existed, so both ends validate.

const EVENT_NAMES = new Set(['add_revenue', 'subtract_revenue']);

// Far inside NUMERIC(20,4) and small enough that double arithmetic on the
// demo's sums stays exact.
const MAX_ABS_VALUE = 1e15;

// Returns null when valid, otherwise the rejection reason.
const validateEvent = (event) => {
  if (!event || typeof event !== 'object' || Array.isArray(event)) {
    return 'event must be a JSON object';
  }
  if (typeof event.id !== 'string' || event.id.length === 0 || event.id.length > 128) {
    return 'event.id must be a non-empty string (<=128 chars); the producer assigns it and its retries reuse it';
  }
  if (typeof event.userId !== 'string' || event.userId.length === 0 || event.userId.length > 255) {
    return 'event.userId must be a non-empty string (<=255 chars)';
  }
  if (!EVENT_NAMES.has(event.name)) {
    return "event.name must be 'add_revenue' or 'subtract_revenue'";
  }
  if (typeof event.value !== 'number' || !Number.isFinite(event.value) || Math.abs(event.value) > MAX_ABS_VALUE) {
    return 'event.value must be a finite number with |value| <= 1e15';
  }
  return null;
};

module.exports = { validateEvent, EVENT_NAMES, MAX_ABS_VALUE };
