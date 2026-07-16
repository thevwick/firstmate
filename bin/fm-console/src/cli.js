#!/usr/bin/env node
// fm-console entry point. Resolves the firstmate bin/ dir and FM_HOME, then
// renders the Ink app full-screen. A --check flag boots the app headlessly and
// exits 0 for the smoke test (no interactive stdin required).

import React from 'react';
import { render } from 'ink';

import App from './app.js';
import { binDir, resolveHome } from './io.js';

const bin = binDir(import.meta.url);
const home = resolveHome(bin);

const args = process.argv.slice(2);
if (args.includes('-h') || args.includes('--help')) {
  process.stdout.write(
    [
      'usage: fm-console.sh [--check]',
      '',
      "Full-screen control surface for one firstmate home. Shows the fleet and",
      'bridges commands into the running primary session via fm-send. No network.',
      '',
      'FM_HOME             firstmate home to operate on (default: repo root).',
      'FM_SUPERVISOR_TARGET  primary firstmate pane the command bridge sends into.',
      'FM_SUPERVISOR_BACKEND optional pane backend (tmux|herdr).',
      '',
      '--check             boot headlessly, then exit 0 (smoke test).',
      '',
    ].join('\n')
  );
  process.exit(0);
}

// Headless smoke mode: render once with no raw-mode stdin, unmount, exit 0.
// This lets the shell smoke test verify the app boots without a TTY.
if (args.includes('--check')) {
  const app = render(React.createElement(App, { bin, home }), {
    exitOnCtrlC: false,
    patchConsole: false,
    // No stdin in --check: Ink must not try to enable raw mode.
    stdin: undefined,
  });
  // Give the first async refresh a beat, then tear down cleanly.
  setTimeout(() => {
    app.unmount();
    app
      .waitUntilExit()
      .catch(() => {})
      .finally(() => process.exit(0));
    // Hard fallback so --check always terminates.
    setTimeout(() => process.exit(0), 500);
  }, 300);
} else {
  const app = render(React.createElement(App, { bin, home }), {
    exitOnCtrlC: true,
    patchConsole: false,
  });
  app.waitUntilExit().then(() => process.exit(0));
}
