# RFC anatomy

The reference set is SMM-2636: parent `4246568991`, server `4246306879`,
client `4247191620`, package `4239360022`, other callers `4306075660`.

## One page, usually

**Write one page.** Everything below - Overview, Context, Proposal, decision
logs, staging plan, considerations, definition of success - lives on it. That is
the shape of almost every RFC in the space.

### When to split

Only when one page would genuinely be unreadable. SMM-2636 split because it runs
to roughly 20,000 words and its audiences barely overlap: the server half, the
client half, the package decision and the other callers each have readers who do
not need the rest.

Signals you have reached that point:

- Several surfaces, each with its own substantial design, not just its own section
- A reader of one part would skip most of the page to find it
- One section has grown its own decision logs, staging rows and limits

Signals you have not:

- The page is long but linear
- The parts share one audience
- You are splitting to make each piece feel tidier

A split costs real effort to keep consistent. Every contradiction between pages
is a review finding, and keeping five pages in step through a redesign is most
of the work.

### If it does split

The parent carries the problem, the decision logs that span surfaces, the epic
breakdown, and a summary table with one row per part linking to its child.
Each child carries one surface in full.

**Every child opens with a scope table:**

```html
<table data-width="760">
  <thead><tr>
    <th><p><strong>Parent RFC</strong></p></th>
    <td><p><a href="…parent…" data-card-appearance="inline">…parent…</a></p></td>
  </tr></thead>
  <tbody><tr>
    <th><p><strong>Scope</strong></p></th>
    <td><p>What this page covers, in one or two sentences.</p></td>
  </tr></tbody>
</table>
```

The parent's summary table does the reverse: one row per part, what it means,
and a link to the child page.

## Section order

Template: `🤠 Overview` → `✨ Context` → `⭐ Proposal` → `🗒️ Decision Logs` →
`📋 Staging Plan / Tickets` → `🤔 Considerations` → `🐌 Performance 🐇` →
`Compatibility` → `🌟 Definition of success`.

Keep the sections you use, delete the ones you don't. Use the template's emoji
and add none of your own.

### Overview

Three or four sentences. What happens after the change, then what ships first.
No preamble about the document.

The SMM-2636 server page opens: *"At Submit the app writes
`submission-manifest.json` once, beside the submission's other files, and the
uploader sends everything in any order. Every file that lands in the task's
folder runs the same check…"*

Present tense, describing the end state as if it exists.

### Context, split in two

**How it works currently** - today's code path, concretely. File and line
references. No complaint yet.

**What is wrong with it** - the failure, and any existing defects that make the
change harder. This is where a reader decides whether the RFC is worth reading.

### Proposal

The bulk of the page. Sub-headings per mechanism, each answering one question.
From the server page: The manifest · The arrival check · Waiting on other
tasks · Where it runs · What the task records · What the run does · Making each
step safe to repeat · What recovers each failure · Monitoring.

Two sections that earn their place and are not in the template:

**What recovers each failure** - a table, one row per failure mode, one row per
recovery. A reviewer reads this looking for the row that is missing. If a
failure has no recovery, say so rather than omitting the row.

**What this version removes** - when the design replaces an earlier one, a table
of each dropped mechanism and why. Without it the next reader re-proposes the
thing you already rejected.

### Decision logs

Inside the RFC, after the Proposal. `🌈 Mini DL n: <question>`. See
`publishing.md` for the markup.

Rules that make them useful:

- **The heading is a question.** "What starts the handler?" not "The trigger".
- **Options get a column each**, with Description, Pros, Cons, Risks rows.
- **The verdict is outside the expand**, in a success panel, starting
  `Preferred: n, <the option>.`
- **Record a changed verdict.** "The first version of this RFC preferred option
  2. That is not what shipped." A log that hides its own history is worthless.
- **Rejected options keep their reasoning.** The Cons column is where the next
  person finds out why not.

### Staging Plan / Tickets

A table: what the work is, what it delivers, which tickets. One row per
deliverable, not per ticket.

**Every ticket named here must exist.** See `tickets.md`.

Group by epic, and say what each epic is for in a sentence. The SMM-2636 split:
epic 1 ships on the current architecture with no switch; epic 2 builds the new
architecture dark; epic 3 turns it on.

### Considerations

Known limits, performance, compatibility. **Known limits is the one that earns
its place** - what the design does not do, stated before someone finds out.

### Definition of success

A table: criterion, and how it is verified. The verification column is the
point, and it must be something a person can actually do.

Good: *"Upload a manifest and its files by hand, in any order, with the app
closed, and the form is created."*

Bad: *"The system is reliable."*

## Prose rules

**Name the actor.** The app, the handler, the run, the uploader, an engineer.
Not "we". An RFC is a proposal asking for consensus, so writing as though
consensus exists begs the question, and "we" hides who does the work.

**No changelog about the document.** Not "we rewrote this page", not "this is
smaller than the first version", not "an earlier draft proposed". The reader
wants the system. A decision log noting a changed verdict is the exception.

**Nothing over 70 words a paragraph.** Three points is three paragraphs, or a
list with a one-line lead.

**Prefer a table when the content is a table.** A paragraph listing six
behaviours and their tickets is a table. The register's "ticket for each item"
map was a paragraph until it became a list.

**Code references everywhere.** `index.ts:88`, `form-task.ts:523`,
`tasks.stack.ts:561`. Real measurements too: `30,369,175 items, 34 GB`.

**Say what is not decided.** A "Not decided yet:" line is better than silent
hand-waving, and it gets answered. One on SMM-2636 turned into the design's
whole retry-convergence story once someone asked about it.

## Reviewing a draft

Mechanical checks, all scriptable:

```
paragraphs over 70 words                  -> 0
first person (we / our / us)              -> 0
em dashes                                 -> 0
ticket links without data-card-appearance -> 0
referenced tickets that do not exist      -> 0
stale design vocabulary                   -> only inside "what this removes"
```

Then read it against the other pages in the set. Contradictions between pages
are the failure mode that reviewers notice and authors do not: an alarm list on
the parent that does not match the server's table, a page naming a ticket
another page says is deleted.
