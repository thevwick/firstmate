// Unit tests for formatting helpers and the pure df parser.
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { humanBytes, humanDuration, truncate } from '../src/format.js';
import { parseDf } from '../src/io.js';

test('humanBytes scales to K/M/G and handles null', () => {
  assert.equal(humanBytes(null), '-');
  assert.equal(humanBytes(0), '0B');
  assert.equal(humanBytes(512), '512B');
  assert.equal(humanBytes(2048), '2K');
  assert.equal(humanBytes(1024 * 1024 * 1.5), '1.5M');
  assert.equal(humanBytes(1024 * 1024 * 1024 * 3), '3G');
});

test('truncate collapses whitespace and ellipsizes to width', () => {
  assert.equal(truncate('a  b\nc', 10), 'a b c');
  assert.equal(truncate('abcdefghij', 5), 'abcd…');
  assert.equal(truncate('short', 20), 'short');
  assert.equal(truncate('anything', 0), '');
});

test('parseDf extracts available bytes and use% from df -k output', () => {
  const out = [
    'Filesystem  1024-blocks       Used Available Capacity  Mounted on',
    '/dev/disk3s5 1000000000  400000000 500000000    45%    /System/Volumes/Data',
  ].join('\n');
  const r = parseDf(out);
  assert.equal(r.free, 500000000 * 1024);
  assert.equal(r.usePct, 45);
});

test('parseDf degrades to nulls on unparseable input', () => {
  assert.deepEqual(parseDf(''), { free: null, usePct: null });
  assert.deepEqual(parseDf('only a header line'), { free: null, usePct: null });
});

test('humanDuration scales seconds to a compact relative label', () => {
  assert.equal(humanDuration(45), '45s');
  assert.equal(humanDuration(40), '40s');
  assert.equal(humanDuration(6 * 60), '6m');
  assert.equal(humanDuration(3 * 3600), '3h');
  assert.equal(humanDuration(2 * 86400), '2d');
});

test('humanDuration degrades to a dim placeholder on null/negative/non-finite', () => {
  assert.equal(humanDuration(null), '-');
  assert.equal(humanDuration(-5), '-');
  assert.equal(humanDuration(NaN), '-');
  assert.equal(humanDuration(Infinity), '-');
});
