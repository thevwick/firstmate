---
name: captain-voice
description: The captain's writing voice, built from ~130 samples of his real Slack, Confluence and Jira writing. Load before drafting ANY text that will go out under his name - Confluence comments, RFC replies, Jira comments, Slack messages, PR descriptions. Not for firstmate's own replies to him.
---

# captain-voice

## Rule zero: no em dashes. Ever.

This applies to **every** register and every profile in this skill - Slack,
Confluence comments, RFC bodies, Jira, PR descriptions, commit messages. There
are zero em dashes in ~8,800 words of the captain's Slack and one across all his
Confluence comments. The AI drafts he rejected had 18 per 1,000 words. It is the
single clearest tell and he has corrected it more than once.

Use a spaced hyphen ( - ), a full stop, or join with "so" / "because".

## Two profiles

- **`voice-profile.md`** - Slack, Confluence comments, Jira. Use for review
  replies, ticket comments, messages.
- **`rfc-profile.md`** - RFC and decision-log **bodies**. Built from 25 RFCs
  with a trust grading: his hand-written pages outrank the agent-co-written
  ones.

A reply to an RFC review comment is a **Confluence comment**, not RFC body.

Read the right one in full before drafting. They are the reference, not a
summary of one.

**The strongest RFC marker:** he writes "we" 17.6 times per 1,000 words. The
agent-drafted RFC scored 0.8. If a draft proposal has no "we" as its subject,
it is not in his voice yet.

## When this applies

Any text the captain will post as himself. Review replies, ticket comments,
Slack messages, PR bodies. It does not apply to firstmate talking to the captain.

## The failure this exists to stop

Drafts kept reading as AI-generated even after the obvious tells were removed.
The cause was structural, not lexical: a fixed template (acknowledge, restate,
correct, cite), 22-word mean sentences against his 15, "X not Y" at 34x his
rate, em dashes, and labelled transitions standing in for ordinary connectives.
Changing the words while keeping the shape does not fix it.

## Before handing over any draft

1. **Pick the register first** (profile §1). An RFC review reply is a
   **Confluence comment**, not Slack shorthand and not RFC body prose. Getting
   this wrong has been the single biggest cause of rejected drafts.
2. Run the §10 checklist.
3. Do not reproduce his Slack typing habits - dropped apostrophes, lowercase
   starts. He said explicitly not to. Correct spelling and punctuation; copy
   structure, hedges and rhythm.

## If the draft is rejected again

Do not iterate on your own output. That sands the same object. Go back to the
exemplars in §9, find the closest match for the register, and write against
that instead.
