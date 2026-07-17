// Tunable constants for fm-console. Kept in one place so cadence and thresholds
// are named, not scattered as magic numbers through the UI.

// How often the board re-reads firstmate state and redraws, in milliseconds.
export const REFRESH_INTERVAL_MS = 2000;

// How often a task's worktree size (du) is recomputed, in milliseconds.
// du walks the whole worktree, so it runs on a slower cadence than the board
// refresh and never blocks a redraw.
export const DU_INTERVAL_MS = 15000;

// The watcher's liveness beacon (state/.last-watcher-beat) is considered fresh
// when it was touched within this many seconds. Mirrors fm-guard.sh's default
// FM_GUARD_GRACE so the console and the guard agree on "is a watcher alive".
export const WATCHER_GRACE_SECS = 300;

// The macOS Data volume the engine's disk-pressure header watches. This is the
// one macOS-correct path the console hardcodes (the engine assumes macOS); the
// rest of the console is generic firstmate state only.
export const DATA_VOLUME = '/System/Volumes/Data';

// Card group order, top to bottom. Keys map to task states derived in state.js.
// Excludes 'done': the redesigned board shows finished work in its own RECENT
// DONE section (state.js's boardSections), not mixed into the IN FLIGHT groups.
export const GROUP_ORDER = ['needs-you', 'ready', 'working', 'blocked'];

export const GROUP_LABELS = {
  'needs-you': 'NEEDS YOU',
  ready: 'READY',
  working: 'WORKING',
  blocked: 'BLOCKED',
  done: 'DONE',
};

// How many RECENT DONE rows the board shows (task cards and backlog Done
// records combined, most-recent-first). A taste of recent history, not the
// archive - data/backlog.md and GitHub remain the full record.
export const RECENT_DONE_LIMIT = 6;

// Below this terminal height/width the board degrades to a minimal single-
// column layout: no side-by-side sections, tighter card rows, and dropped
// optional chrome, rather than clipping content unreadably.
export const MIN_ROWS_FOR_FULL_LAYOUT = 24;
export const MIN_COLS_FOR_FULL_LAYOUT = 70;

// Terminal rows one in-flight card draws: a headline row (id + state badge +
// model chip) and a metadata row (size/age/branch/PR/endpoint, with the
// fuller last-event text trailing when it fits). Ink has no scrolling, so
// this must match the Card component's actual row count exactly - the row
// budget in state.js's computeRowBudget is spent against this unit, not a
// per-card count, or a multi-line card silently overflows its section (see
// the Card and capRows comments in app.js).
export const CARD_ROW_HEIGHT = 2;

// Below this content width a card drops its least-important metadata fields
// (endpoint, then branch/PR, then size) one at a time rather than wrapping
// them into an unreadable run-on line.
export const CARD_NARROW_WIDTH = 64;
export const CARD_VERY_NARROW_WIDTH = 48;

// Terminal rows a board section's own chrome costs: 2 border lines (top and
// bottom) plus 1 title line. The one place this is defined; state.js's
// computeRowBudget spends its body-row math against it, and app.js's
// content-hugging IN FLIGHT height must add exactly this back on top of the
// capped body-row count, or the two drift and a card's headline row silently
// clips (the Ink no-scrolling corruption the Card/capRows comments warn about).
export const SECTION_ROW_CHROME = 3;

// Terminal color per state.js's healthLevel ('green'/'yellow'/'red'/'grey'),
// used for a card's left border stripe, its health dot, and its state badge -
// the "heat-map" requirement: a card needing the captain must read as red at
// a glance, not just a small dot. The one place this state->color mapping is
// defined; app.js imports it rather than keeping its own copy.
export const HEALTH_COLORS = {
  green: 'green',
  yellow: 'yellow',
  red: 'red',
  grey: 'gray',
};

// Claude's brand accent (the warm coral/orange used across Anthropic's own
// surfaces). Applied to the identity mark on a card whose harness is claude -
// see CLAUDE_MARK below and app.js's HarnessMark render code.
export const CLAUDE_ACCENT = '#D97757';

// Neutral accent for a crew running on any non-claude harness (codex, grok,
// opencode, pi), so the Claude accent above stays a meaningful signal rather
// than a decoration applied to everything.
export const OTHER_HARNESS_ACCENT = '#7C9CBF';

// Identity glyph shown next to a card's harness/model/effort chip: a sparkle
// stands in for Claude (a terminal cannot render the real logo raster), a
// plain diamond marks any other harness. figures has no exact sparkle, so
// this is one of the few literal glyphs in the app - both are widely
// supported Unicode (not exotic), and figures.pointer is used everywhere else
// state/action glyphs are needed.
export const CLAUDE_MARK = '✵';
export const OTHER_HARNESS_MARK = '◆';

// How many trailing lines of firstmate's OWN pane the FIRSTMATE ACTIVITY panel
// captures and shows, newest at the bottom (a live-tail read). Sized generous
// enough to read like a real terminal tail while still fitting the panel's
// allotted height in either layout mode (see app.js's FirstmateActivityPanel);
// the panel itself further caps what it draws to its actual row budget so a
// wide capture never overflows Ink's fixed-height layout.
export const FIRSTMATE_ACTIVITY_CAPTURE_LINES = 25;

// Compact-strip height (in body rows, not counting the section's own
// SECTION_ROW_CHROME) for the FIRSTMATE ACTIVITY panel when it shares the
// screen with in-flight task cards, so it never crowds out IN FLIGHT/QUEUED/
// RECENT DONE - just enough to read as "firstmate is doing something" at a
// glance. The captain can still see the full capture via the idle-fleet
// layout, where the panel takes over IN FLIGHT's whole freed box.
export const FIRSTMATE_ACTIVITY_STRIP_ROWS = 5;
