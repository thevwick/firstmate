// Pure command composition. Quick-actions COMPOSE plain text into the input
// line for the captain to review and send; they never execute anything here.
// The console only ever DELIVERS the captain's typed/confirmed text to the
// running primary session via fm-send (see bridge.js). All approval gates stay
// with firstmate; this module adds no auto-approve or bypass path.

// Quick-actions the console offers per selected task. Each composes a natural-
// language instruction firstmate already understands. `destructive: true`
// actions require an explicit confirm keystroke in the UI before they compose.
export const QUICK_ACTIONS = [
  { key: 's', label: 'status', destructive: false, verb: 'status' },
  { key: 'm', label: 'merge', destructive: true, verb: 'merge' },
  { key: 't', label: 'teardown', destructive: true, verb: 'teardown' },
];

// Compose the instruction text for a quick-action against a task id.
// Returns a plain sentence firstmate reads as a captain instruction, e.g.
// "merge fm-login-k3". The verb+id form is intentional: it is what a captain
// would type, and firstmate applies its normal gate to it.
export function composeQuickAction(verb, taskId) {
  const v = String(verb || '').trim();
  const id = String(taskId || '').trim();
  if (!v) throw new Error('composeQuickAction: missing verb');
  if (!id) throw new Error('composeQuickAction: missing task id');
  return `${v} ${id}`;
}

// Look up a quick-action definition by its keystroke.
export function actionForKey(key) {
  return QUICK_ACTIONS.find((a) => a.key === key) || null;
}

// Whether a composed command line is safe to send as-is (non-empty after trim).
// The console never blocks content on safety grounds - firstmate owns that -
// it only refuses to send an empty line.
export function isSendable(text) {
  return typeof text === 'string' && text.trim().length > 0;
}

// Normalize a command line for sending: trim trailing whitespace/newlines so a
// stray Enter in the composer does not become part of the instruction.
export function normalizeCommand(text) {
  return String(text ?? '').replace(/\s+$/, '');
}
