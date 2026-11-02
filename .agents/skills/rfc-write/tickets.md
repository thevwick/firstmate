# The tickets behind an RFC

An RFC's staging plan is a promise that those tickets exist and say what the
page says. Breaking that is the quickest way to make the whole set untrusted.

## Epic shape

One epic per thing that ships, not per surface. The SMM-2636 split started as
server-in-one-epic and app-in-another, which was wrong: the new architecture is
one thing, built together and switched on together. It collapsed to:

- **Epic 1** - everything that ships on the current architecture, no switch, each
  change worth having alone
- **Epic 2** - the new architecture, built and in production, dark
- **Epic 3** - switch-on
- **After switch-on** - other callers move, the old path retires

An epic body states what it is, what it delivers, and what must hold before it
is done. Keep it short; the tickets carry the detail.

## Ticket fields

Three fields, and the API treats them differently:

| Field | Id | Format |
|---|---|---|
| Description | `description` | ADF |
| Problem Statement | `customfield_10079` | ADF |
| Acceptance Criteria | `customfield_10097` | ADF |

**Use `editJiraIssue` via the MCP**, which converts markdown to ADF. The raw
REST API refuses markdown strings with *"Operation value must be an Atlassian
Document"*.

**Description** carries **Problem** as bullets, then **Change** as what gets
built, then links to the RFC sections that explain it.

**Acceptance criteria are outcomes, not demo steps.** "A submission whose files
are all present starts on the arrival that completes the set", not "click submit
and observe". Each one must be checkable by someone who did not write the
ticket. Numbers and thresholds belong in Ship + Verify, not in acceptance
criteria.

## Engineering notes

Every ticket carries one comment, in this shape:

> **Engineering notes**: one line on where this runs.
>
> **🛠 Where it touches** - files, line numbers, which other ticket owns the
> neighbouring change
>
> **✅ Decisions that apply** - the design decisions this ticket implements, and
> what was rejected
>
> **⚠️ Constraints and gotchas** - the things that will bite. Contention, size
> limits, ordering, what must not be reset

The three sections are **collapsed expands with emoji titles**. The constraints
section is the one that earns the comment: it is where "the task already carries
`payload` as a string, measure a large form against the 400KB item limit" goes.

### Posting them

**The MCP's markdown path renders `<expand>` as literal text.** Post raw ADF
through the REST API instead:

```python
def expand(title, *kids):
    return {"type": "expand", "attrs": {"title": title}, "content": list(kids)}

body = {"type": "doc", "version": 1, "content": [
    {"type": "paragraph", "content": [
        {"type": "text", "text": "Engineering notes", "marks": [{"type": "strong"}]},
        {"type": "text", "text": ": where it runs."}]},
    expand("🛠 Where it touches", …),
    expand("✅ Decisions that apply", …),
    expand("⚠️ Constraints and gotchas", …)]}

POST /rest/api/3/issue/{key}/comment   {"body": body}
```

Node builders worth having: `text`, `strong`, `code`, `link` (a `marks` entry
with `href`), `paragraph`, `bulletList` / `listItem`.

**Verify it posted as real nodes:**

```python
GET /rest/api/3/issue/{key}/comment
# expect: '"type": "expand"' present, '<expand' absent
```

### Approval

**Never post a ticket comment without the captain's explicit approval.** That is
a standing rule. Draft, show, then post.

## Keeping tickets and pages in step

After any ticket surgery - merging, deleting, renaming, re-parenting - the pages
are stale. Sweep them.

**Verify every referenced key exists.** Do not trust your own edits:

```python
# every ticket the published pages reference
keys = set(re.findall(r"browse/(SMM-\d+)", storage_body))
# fetch each; anything that 404s is a dead reference
```

Run this against the **published** storage, not the local file. A sweep done
this way caught four dead references that a careful manual pass had missed,
three of which had been broken for weeks.

**Sweep for stale design vocabulary too.** After a rename or a redesign, grep
every ticket summary and body for the old words. The only legitimate survivals
are inside a "what this version removes" table.

## Merging tickets

Two tickets should be one when neither demos alone and their acceptance criteria
are the same scenarios from two ends. Signals:

- A staging/production split that existed only to stub something no longer built
- A server half and a client half of one feature
- A status nothing clears, and the observer that clears it
- The same change applied to two surfaces, both blocked on the same dependency

When merging: rewrite the survivor's summary, description and acceptance
criteria to cover both, **then** delete the absorbed one. Not the other way
round.

Deleting a ticket is destructive and needs the captain's word.

## Whole-set checks

```
every ticket referenced by a page exists           -> yes
every ticket has engineering notes with expands    -> yes
no ticket body describes a superseded design       -> yes
no epic body describes a superseded design         -> yes
each epic's children match the page's staging plan -> yes
```

The epic bodies are the ones that get forgotten. They were the last stale thing
in the SMM-2636 set, still describing six alarms and a lease long after every
ticket under them had been rewritten.
