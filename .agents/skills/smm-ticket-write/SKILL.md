---
name: smm-ticket-write
description: Load before writing, rewording or restructuring an SMM Jira ticket or epic from firstmate, and before posting engineering notes. Points at the authoritative smm-ticket skill inside sitemate-mobile, which the Skill tool cannot see from here, and adds the epic-level and bulk-change practice that skill does not cover.
user-invocable: true
metadata:
  internal: false
---

# smm-ticket-write

## The real skill lives in the project clone

**`projects/sitemate-mobile/.claude/skills/smm-ticket/`**

The Skill tool cannot see it from firstmate, because it is inside a project
clone. Read it directly:

| File | What it owns |
|---|---|
| `SKILL.md` | Clean mode and create mode, phase by phase. Field routing. The confirm-then-write gate |
| `references/smm-fields.md` | Every field id, which are ADF-only, what each is for |
| `references/voice.md` | How SMM tickets are written |
| `scripts/md-to-adf-expands.mjs` | Markdown to ADF expand nodes, for the engineering notes comment |

That skill is the authority on a single ticket. Do not re-derive its rules.
This file covers what it does not: epics, bulk changes, and posting notes from
firstmate where its script is not on the path.

**Load `captain-voice` too** before drafting anything that goes out under his
name.

---

## Rules that bind from here

**Never post or edit without explicit approval.** A ticket is shared and
outward-facing. Draft, show the before and after, then write. This holds even
when the ask was "just clean it up", and it holds for comments.

**Never scale one approved rewrite to a batch.** Approval for one ticket's
wording is not approval for twelve.

**Every ticket key in a captain-facing message carries key + title + full browse
URL.** A bare key makes him look up his own status.

**Acceptance criteria are outcomes, not demo steps.** "A submission whose files
are all present starts on the arrival that completes the set", not "click submit
and observe". Thresholds, volumes and "because" belong in Ship + Verify, not in
acceptance criteria.

---

## Engineering notes

Every substantive ticket carries one comment. The smm-ticket skill owns the full
vocabulary; these are the three that an RFC-driven ticket almost always uses:

> **Engineering notes**: one clause on scope, e.g. "the task entity, written by
> the arrival check".
>
> **🛠 Where it touches** - files and line numbers, and which other ticket owns
> the neighbouring change
>
> **✅ Decisions that apply** - what this implements, and what was rejected
>
> **⚠️ Constraints and gotchas** - what will bite. Contention, size limits,
> ordering, what must not be reset

The constraints section is what earns the comment. It is where *"the task
already carries `payload` as a string, so measure a large form against the 400KB
item limit"* goes - the thing a future implementer discovers the hard way.

Rules from the project skill that matter most: 5 to 9 expands, plain-string
titles under about 60 characters, a leading emoji per title, never nest expands,
one topic each. Everything before the first heading stays visible when
collapsed, so put the punchline there.

### Posting from firstmate

The project skill's converter is not on firstmate's path. Two options:

**Run its script** with an absolute path:

```bash
node /Users/thev/sitemate/firstmate/projects/sitemate-mobile/.claude/skills/smm-ticket/scripts/md-to-adf-expands.mjs notes.md > notes.adf.json
```

**Or build the ADF directly** and POST it:

```python
def expand(title, *kids):
    return {"type": "expand", "attrs": {"title": title}, "content": list(kids)}

body = {"type": "doc", "version": 1, "content": [
    {"type": "paragraph", "content": [
        {"type": "text", "text": "Engineering notes", "marks": [{"type": "strong"}]},
        {"type": "text", "text": ": scope in one clause."}]},
    expand("🛠 Where it touches", …),
    expand("✅ Decisions that apply", …),
    expand("⚠️ Constraints and gotchas", …)]}

POST /rest/api/3/issue/{key}/comment   {"body": body}
```

**Do not post expands through the MCP's markdown path.** It renders `<expand>`
as literal text. Verify after posting:

```python
GET /rest/api/3/issue/{key}/comment
# expect '"type": "expand"' present, '<expand' absent
```

**Notes go in a comment, never the description.** The description is
wiki-rendered: expands flatten to bold paragraphs and `{}` in code spans corrupt
into wiki macros. The project skill records this as verified; do not retry it.

---

## Epics

The project skill covers tickets. Epics need their own care, and they are the
thing that goes stale unnoticed.

**An epic body states** what it is, what it delivers, and what must hold before
it is done. Short. The tickets carry detail.

**After any redesign, rewrite the epic body too.** On SMM-2636 the epic bodies
were the last stale thing in the set, still describing six alarms and a lease
long after every ticket under them had been rewritten. Nobody looks at an epic
body, which is exactly why it rots.

**Epics split by what ships, not by which team touches it.** The original split
put the server in one epic and the app in another; the architecture was one
thing built and switched on together, so it collapsed into one.

---

## Bulk changes

**Re-parent before deleting.** Move the keepers out, confirm the source is
empty, then delete it. Never the other way round.

**Merging two tickets:** rewrite the survivor's summary, description and
acceptance criteria to cover both, then delete the absorbed one.

Two tickets should be one when neither demos alone and their acceptance criteria
are the same scenarios from two ends. Signals: a staging/production split that
existed only to stub something no longer being built; a server half and a client
half of one feature; a status nothing clears and the observer that clears it;
the same change on two surfaces blocked on one dependency.

**Deleting a ticket is destructive and needs the captain's explicit word.**

**After any surgery, sweep for stale references.** Any RFC page naming a deleted
ticket is now lying. Extract every `browse/SMM-\d+` from the published page
storage and fetch each one - do not trust your own edits. A sweep done that way
caught four dead references a careful manual pass had missed.

**Sweep for stale vocabulary too.** After a rename, grep every ticket summary
and body for the old word. Legitimate survivals are only inside a "what this
version removes" table.

---

## Field reference, quickly

| Field | Id | Format |
|---|---|---|
| Description | `description` | ADF |
| Problem Statement | `customfield_10079` | ADF |
| Acceptance Criteria | `customfield_10097` | ADF |

Use `editJiraIssue` via the MCP, which converts markdown to ADF. The raw REST
API refuses markdown with *"Operation value must be an Atlassian Document"*.
`references/smm-fields.md` has the full list.

---

## Related

- **`rfc-write`** - the RFC these tickets carry out, and keeping the two in step
- **`captain-voice`** - how anything under his name is written
