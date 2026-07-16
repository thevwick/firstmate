// Small pure formatting helpers for the UI. Kept separate so they can be unit
// tested and so the render code stays about layout, not arithmetic.

// Human-readable byte size (e.g. 1.4G, 820M). null -> a dim placeholder.
export function humanBytes(bytes) {
  if (bytes == null || !Number.isFinite(bytes)) return '-';
  const units = ['B', 'K', 'M', 'G', 'T'];
  let n = bytes;
  let i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i += 1;
  }
  const rounded = n >= 100 || i === 0 ? Math.round(n) : Math.round(n * 10) / 10;
  return `${rounded}${units[i]}`;
}

// Truncate a one-line string to width with an ellipsis, collapsing internal
// newlines to spaces first so a multi-line status never breaks the layout.
export function truncate(text, width) {
  const s = String(text ?? '').replace(/\s+/g, ' ').trim();
  if (width <= 0) return '';
  if (s.length <= width) return s;
  if (width <= 1) return s.slice(0, width);
  return `${s.slice(0, width - 1)}…`;
}
