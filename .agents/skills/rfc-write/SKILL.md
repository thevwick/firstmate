---
name: rfc-write
description: Load before writing, restructuring or publishing a Confluence RFC, a decision log, or the Jira epics and tickets that carry its staging plan. Covers the page structure that works, the Atlassian publishing mechanics that silently destroy content, smart links, and keeping pages and tickets in step.
user-invocable: true
metadata:
  internal: false
---

# rfc-write

Built from the SMM-2636 RFC set (five pages, Oct 2026): the parent, the server
side, the client side, the package page and the other callers. Read those as the
reference before writing a new one.

**Voice is a separate skill.** Load `captain-voice` and read `rfc-profile.md` in
full before drafting any prose. This skill is structure, mechanics and hygiene.
The two apply together.

---

## Rule zero: publish through the MCP, in HTML

`updateConfluencePage` takes **HTML**. Not markdown, not storage XML.

- `contentFormat: "markdown"` **escapes** the markers instead of converting them.
  The page renders as literal `\*\*bold\*\*`.
- Storage XML (`<ac:structured-macro>`, `<ac:rich-text-body>`, CDATA) is
  explicitly forbidden and renders as raw text.
- Call `getContentFormatGuide` with `{toolName: "updateConfluencePage"}` and
  follow it. It is the authority, not memory.

**A read always returns markdown**, whatever the stored format. So a read tells
you nothing about what the page actually holds: expand macros, panels and emoji
nodes are invisible in it. Never reconstruct a page from a read.

See `publishing.md` for what breaks, how to detect it, and the REST fallback for
pages too large to pass through a tool call.

---

## The structure that works

**An RFC is one page.** That is the normal shape and the one to reach for.

Split into child pages only when a single page would be unreadable. SMM-2636 is
the exception, not the model: it runs to roughly 20,000 words across a server
half, a client half, a package decision and three other callers, with audiences
that barely overlap. Someone building the arrival check should not have to read
the app's register of fourteen behaviours to find it.

If it does split, the parent carries the problem, the decision logs that span
surfaces, the epic breakdown and a summary table linking the children. Each
child opens with a scope table naming the parent.

The MOB template's section order:

`🤠 Overview` → `✨ Context` → `⭐ Proposal` → `🗒️ Decision Logs` →
`📋 Staging Plan / Tickets` → `🤔 Considerations` → `🐌 Performance 🐇` →
`Compatibility` → `🌟 Definition of success`

What earns its place beyond the template:

| Section | Why |
|---|---|
| **How it works currently** / **What is wrong with it** | Splitting Context in two. The reader needs today's behaviour before the complaint about it |
| **What this version removes** | When a design replaces an earlier one, a table of what went and why. Stops the next reader re-proposing it |
| **What recovers each failure** | A row per failure mode and what catches it. This is where reviewers find the holes |
| **Known limits** | What the design does not do, stated before someone discovers it |

**Decision logs live inside the RFC**, as `🌈 Mini DL n: <the question>`. The
heading is a question, not a topic. The options table collapses inside a
`<details>`; the verdict sits outside it in a success panel, so a reader sees
the answer without expanding anything.

`structure.md` has the full anatomy with the markup for each piece.

---

## What makes the content good

The SMM-2636 set reads well for reasons worth copying deliberately:

**Name the actor, never "we".** An RFC is one person's proposal, so "we queue the
files" claims a consensus that does not exist yet and hides who acts. Write *the
app queues the files*, *the handler reads the manifest*, *an engineer redrives
the run*. A reviewer can argue with a claim about the system; they cannot argue
with a committee.

This is the one place this skill overrides `captain-voice`, which measures "we"
at 17.6 per 1,000 words in his hand-written pages. That holds for his own
drafting. For an agent drafting on his behalf it produced exactly the committee
voice he rejected. Name the actor.

**No changelog in the body.** "We rewrote this page around an arrival-triggered
design" tells the reader about the document, not the system. Cut it. A decision
log recording that a *verdict* changed is different and belongs.

**One question per decision log.** Three alarms asking "is this submission
stuck?" three ways is one alarm. The review that cut six alarms to four is the
model: ask what an engineer would actually do about each, and what it costs to
build.

**Short paragraphs.** Nothing over 70 words. A paragraph making three points is
three paragraphs or a list. Walls of text are the most common complaint.

**Ground every claim in code.** `form-task.ts:523`, `tasks.stack.ts:61`,
`30,369,175 items, 34 GB, 8 existing indexes`. A design argument with a file and
line behind it survives review; one without it gets litigated.

---

## Links

**Every Jira link is a smart link.** Write the anchor as the URL itself with
`data-card-appearance="inline"`:

```html
<a href="https://sitemate.atlassian.net/browse/SMM-3262" data-card-appearance="inline">https://sitemate.atlassian.net/browse/SMM-3262</a>
```

Confluence renders the live ticket title and icon, and a renamed ticket updates
itself. A plain anchor with the title typed in goes stale the moment anyone
renames anything.

**Never hand-write a ticket title into prose.** That is what smart links are for.

---

## Keeping pages and tickets in step

A staging plan is a promise that those tickets exist. Breaking it is the easiest
way to make an RFC untrustworthy.

- **After any ticket surgery, sweep the pages.** Merging, deleting or renaming
  tickets leaves the staging tables pointing at nothing.
- **Verify every key exists.** Extract every `browse/SMM-\d+` from the published
  storage and fetch each one. Do not trust your own edits - a sweep run this way
  caught four dead references a manual pass missed.
- **The tickets must match the design.** A page describing arrival-triggering
  while its tickets describe a lease and a wake ladder is worse than no tickets.
- **Every ticket gets engineering notes**, in the house format: a lead line, then
  collapsed expands titled `🛠 Where it touches`, `✅ Decisions that apply`,
  `⚠️ Constraints and gotchas`. Post as **raw ADF** through the REST API; the
  MCP's markdown path renders `<expand>` as literal text.

`tickets.md` has the ADF comment builder and the sweep script.

---

## Before publishing, every time

1. `getContentFormatGuide` read, and the body is HTML.
2. Count the structural elements you are sending: expands, panels, code blocks,
   emoji nodes, tables.
3. Publish.
4. **Read the page back and count them again.** Equal, or something was dropped
   silently. This check is the only thing that catches a converter bug, and
   skipping it is how eight dead panels shipped unnoticed.
5. Confirm no paragraph is over 70 words, no em dashes, no first person.

---

## The failures this exists to stop

Each cost real time on SMM-2636:

- Published markdown; the page rendered as escaped literal text.
- Invented a `contentRepresentation: "append"` parameter; it was ignored, four
  calls each did a full replace, and the page was reduced to its final quarter.
- Converted good HTML into storage XML, which the MCP forbids.
- A converter that handled expands and code blocks but passed
  `<div data-type="panel-*">` straight through, so eight panels rendered as
  plain blocks. Read-back would have caught it. It was not run.
- Reconstructed a page from a markdown read, losing every expand macro.
- Treated an old draft as current, repeatedly, and argued from it.

The pattern in all of them: assuming what the system did rather than checking.
