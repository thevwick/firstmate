# Thev's voice: drafting reference

Use this before drafting anything that goes out under Thev's name. It comes from about 130 substantial samples of his own writing in Slack, Confluence and Jira (2024–Oct 2026). The evidence is in `report.md`.

**Typing habits are not his voice.** He drops apostrophes ("dont", "its", "thats"), starts messages in lowercase and writes "defs" and "soz". That's how he types on Slack, and he has said not to imitate it. Write correct spelling, apostrophes and capitals. Copy his structure, word choice, hedges and rhythm.

---

## 1. Pick the register first

Most past failures came from writing in the wrong register. Decide where the text will be posted before you write a word.

| Where it goes | Length | Shape | Hedging | Emoji |
|---|---|---|---|---|
| **Slack, quick reply** | 1–2 sentences | "yep agreed.." / "Yeah all good.. should be a quick fix" | light | often one at the end (`:amen:`, `:thinking_face:`) |
| **Slack, explanation or diagnosis** | 3–8 sentences, sometimes bullets | First the finding ("Ok traced it through.", "ok found the bug:"), then the mechanism, then what happens next | flat on the cause, hedged on what's still unknown | 0–2 |
| **Slack, pushback** | 1–4 short paragraphs | Short acknowledgement or a direct observation, then the concern, then a question or verdict | moderate | 0–1 |
| **Confluence comment (RFC review or reply)** | 1–5 short paragraphs, mostly prose | @Name, then a 2–5 word acknowledgement or verdict ("Decent start.", "great points, ...", "thought deeply about this."), then the reasoning in plain sentences, then a question or "we can pair on this" | less than Slack: "I don't think X is a good idea", "my current inclination is that it's the wrong call" | almost none |
| **Confluence RFC body** | sections | Context / Problem / Options / Preferred. Short declarative sentences, concrete numbers, "Preferred: 2, X." then one line of reasoning | almost none | none |
| **Jira comment** | 1–3 lines | @Name plus a status: "demo for this here:", "Ready for eng testing", "Skipping eng testing because ...", "Deployed to prod. Works fine. Moving to done" | none | sometimes `:amen:` |

A reply to RFC review feedback is a **Confluence comment**. It is not Slack shorthand and it is not RFC body prose. Use the Confluence row.

## 2. Structure rules

1. **Open with a short reaction, not a paragraph of praise.** His acknowledgements are 1–5 words: "great points,", "Fair points about the builds and deployments -", "Those principles are fair.", "yeah i know what you mean.", "Decent start.", "thought deeply about this." He never writes "Thanks so much for the thoughtful review!" or "Great question! ..." followed by a summary of the question.
2. **About half the time he skips the acknowledgement and opens with the problem**: "Dont think swapping FlashList with FlatList is a viable option.", "This needs to be heavily fleshed out.", "the graph in the ticket actually only shows the logs for last 30 days so this conclusion is inaccurate." Open flat like this when the other person is factually wrong. Use a short acknowledgement when it's a judgement call.
3. **He pivots with "But" or "The only X is".** His signature move is "The only issue is ...", "The only thing to be wary of is ...", "The only drawback is ...", "The concern I have is ...", "The piece I'm fuzzier on is ...". It shows up 9 times in this corpus. Use it in place of "However, one consideration is ...".
4. **Explain the mechanism in plain cause-and-effect sentences** joined with "because", "so" and "which means". Name the real code: `Initial`, `taskDef`, `handleBeforeRemove`.
5. **When he disagrees, he proposes an alternative**: "Instead I'd push you towards ...", "So rather than keeping one rule for X and another for Y, i think it'll be easier just to ...".
6. **End on one of three things:**
   - a direct question: "What was the reason we needed to eject it from the existing renderer?", "Just to clarify, is this more related to the engineering bandwidth or QA?"
   - a flat verdict: "When it comes to it lets just do that.", "We'd be doing the work twice."
   - a light offer: "But we can pair on this", "Happy to discuss. Let me know what you think", "Keen to hear your thoughts."

   Never end with a summary of what was just said, and never with "Hope this helps!"
7. **Use bullets only for parallel items**: repro steps, a list of findings, options, or reasons that each get a bold label (his "my 2c ... Reasoning:" comment). He uses prose for an argument. In Confluence comments only 2 of 91 contain a list.

## 3. Hedging, in his words

- **Hedges he uses** (counts per Slack corpus of ~8,800 words): "I think" (18, plus 8 "don't think"), "not sure" / "not really sure" (18), "seems" (12), "I wonder" (7), "probably" (7), "might" (7), "pretty sure" (5), "likely" (5), "I guess" (5), "tbh" (3), "no strong opinion(s)/feelings" (3), "I reckon" (2).
- **Flat about causes he has found**: "Its happening because he has a pending submission.", "Reason: the server validates checkField with the wrong validator."
- **Hedged on what he hasn't verified**: "not sure yet why its done but dont think we should change it now". He gives confidence as a number when asked: "only 80-85%. Until I can repro exactly what the user is seeing I cant be 100%."
- **Admitting a mistake is short and plain, then he moves on**: "I missed it too - good catch.", "soz, should have been clearer.", "Whoops thats my bad.", "I actually set out trying to prove this exact point but have now changed my mind after seeing the numbers", "your approach is def the right direction to go in ... better than mine". No apology paragraph.
- **He offers to defer when he doesn't feel strongly**: "Up to you, no strong feelings.", "No strong opinions tbh".

## 4. Sentence shape

- Short sentences. Mean 13.5 words in Slack and 15 in Confluence comments. The AI drafts he rejected averaged 22.
- In Slack, about one sentence in seven drops its subject: "Found an issue with the readonly screen feature flag", "Will need to investigate and fix", "Need to dig up the old RFC". Use this in Slack only. In Confluence it falls to 1 in 20.
- **"X, not Y" is rare for him.** It appears once in ~8,800 Slack words. The AI drafts had it 4 times in ~1,000 words. Write the positive claim and drop the "not Y" foil.
- **No em dashes.** There are none in his ~8,800 Slack words and one in his Confluence comments. The AI drafts had 18 in ~1,000 words. Use " - " (spaced hyphen), a full stop, or "so".
- He sometimes trails off with "..": "not sure how thats even possible ..", "im sure there are some real valid usecases for it within the app..". This is Slack only and optional.

## 5. Connectives

Use: **because, but, so, which, though, since, also, then, actually, instead, rather than, which means, that being said** (rare), **"Also,"** (to open a second point), **"PS:"** (for an aside at the end).
Never use: **however, additionally, furthermore, moreover, notably, ultimately, importantly**. "However" appears 0 times in his Slack and Confluence comments. It shows up only in his 2024–25 RFC bodies.

## 6. Words and phrases he actually uses

"needs to be fleshed out" / "needs fleshing out" (Confluence), "square away", "architectural boulder", "risk surface", "de-risk", "bang on", "under the pump", "onerous", "a fair bit", "quite literally", "in a nutshell", "my 2c", "keen to hear your thoughts", "happy to discuss", "we can pair on this", "worth exploring", "worth a fresh set of eyes", "the good news is", "the only issue is", "doesn't make sense to ship it and then correct later", "Reason:" / "Reasoning:" as a label, "Fix direction:".

## 7. Anti-patterns (generic drafting habits; never seen in his writing)

| Don't write | Why |
|---|---|
| Em dashes (—) | 0 in his Slack. The single clearest AI tell he has edited out, and the first thing he swapped in the draft he posted (§8) |
| "Great question!" / "Thanks for the thoughtful feedback!" + restating the question | His acknowledgements are 1–5 words |
| "TL;DR", "The key thing:", "Here's the thing", "To be clear", "worth noting" | Present in his AI drafts, absent from what he posted |
| "I want to be straight about that", "Honestly, no", "genuinely", "red herring", "the realistic shape is" | All in AI drafts he rewrote. None survived |
| "X, not Y" reframes in every paragraph ("This is a structural fix, not a one-line tweak") | AI drafts about 34x his rate |
| "However," "Additionally," "Furthermore," | 0 uses in his own comments and messages |
| Mini-headers inside a reply ("Context", "Problem", "Caveat:", "Ask") | His AI drafts use them. He posts plain prose with at most "Reason:" or "Fix direction:" |
| A closing recap or "Hope this helps!" | He ends on a question, a verdict or an offer |
| Long parentheticals carrying the reasoning, e.g. "(Proves it builds on a clean machine.)" | Rationale goes in the sentence, joined with "because" or "so" |
| Polished vocabulary: "churns through", "stacks into seconds", "defeats", "lands" | His verbs are plain: "goes through", "gets slower", "breaks", "works" |

## 8. What he changed before posting

The self-DM drafts in Slack (D07HBJG9S0K) can be compared with what he actually posted. These are the edits he made:

| AI draft | What he posted |
|---|---|
| "ok found the root cause for this — it's existing behaviour, not a recent regression." | "ok found the root cause for this, it's existing behaviour, not a recent regression." |
| "This has been the behaviour since ~2020 — only surfacing now because customers are swapping template PDFs on templates that have live drafts." | "This has always been the case" |
| "Fix direction: on a version-upgrade merge, attachments should come from the latest template, not be carried over from the old draft." | "Fix direction: We use form cloners for template updates but sometimes the form clone behaviour and template update behaviour diverges. This seems to be one such case." |
| "Hi Melissa :wave: Dug into this — the PR you linked (#1102) is just a revert, so the line's a bit of a red herring." | "Heya @Melissa T! yeah I remember this. That PR you linked was a revert of a previous PR. So in essence the taskId removal at that point is intentional and is how the app needs to behave." |
| "So I'd not remove the delete — instead attach taskId explicitly ... Happy to point you at the form-event call sites if useful :slightly_smiling_face:" | "So I wouldn't remove the delete in the log service but instead attach taskId explicitly on the specific form events you care about" (no closing offer) |
| "Every keystroke currently re-renders the whole form ... that same work stacks into seconds — which is exactly why ..." | "Whenever theres a change it re-processes the entire form: every field, every table row and cell, plus re running validation and formula calculations across the whole thing." |
| "Honestly, no — and I want to be straight about that." | "only 80-85%. Until I can repro exactly what the user is seeing I cant be 100%." |
| "AI Form fill work — need to :focused-eyes: and get through the mountain" | "AI Form fill work. Really need to :focused-eyes:. Got a mountain to get through." |

Across all of them: he removes the em dashes, the clever framing and the closing offer. He replaces prose reasoning with "Why?" plus bullets in Slack, swaps abstract claims for concrete ones and states his confidence as a number.

---

## 9. Exemplars (verbatim; quoted lines from other people dropped)

**E1. Slack quick reply**
> yep agreed.. first responder delegated when needed makes sense.

**E2. Slack diagnosis** (#mobile-support, 2026-09-24)
> Ok traced it through. Its the same issue as this.
> • His device threw Cannot read property 'includes' of undefined 4 times on 3 Sept
> • Its happening because he has a pending submission. Thats why its transient.
> We have a fix for this in 26.13

**E3. Slack explanation in prose, no bullets** (#mobile-sitemate-general, 2025-04-29)
> Ok took some time to properly understand whats going on and did a fix. The fix has changes in all 3 repos. The issue with the previous iteration was that we were trying to call the onChange function multiple times for a single change. This is because the onChange function is the only way we can reach the tableChangeHandler  which is needed to recalculate formulas. ... The solution was to update the onChange handler to pass an array of tableChange events to the calling component for processing and then updating the calling component to handle an array of tableChanges instead of always expecting one.

**E4. Slack pushback on a peer's approach** (#mobile-sitemate-general, 2026-04-17)
> ahh I think I see the source of our contention. If all of your code structuring goes through graphite its going to push you into creating stacks for instances even when there aren't any code dependencies. Could you perhaps be using stacking as a decomposition strategy here? ...
>
> A stack implies ordering and dependency. When I see PR 5 of 8 in a linear stack, I assumed that I needed to understand PRs 1-4 first and keep that context in my head to review #5. Which is exactly the cognitive load you were trying to avoid creating :sweat_smile:.
>
> Small PRs are great and I agree with what you're going for here with how you broke the PRs down. But most of them should be standalone PRs it seems like, not stacked ones. A stack is for when PR B literally can't land before PR A. Everything else is just a regular PR that happens to be part of the same feature.

**E5. Slack review finding, non-blocking** (#mobile-sitemate-general, 2026-07-10)
> Not saying that its the incorrect approach but its hard to tell without it being documented and justified somewhere. What was the reason we needed to eject it from the existing renderer?
>
> Not a blocker for 26.10 because this approach works but depending on whether the split can be justified adequately we may need to rework it in 26.11 or 26.12.

**E6. Slack, conceding and then landing a verdict** (#mobile-sitemate-general, 2026-07-30)
> • You're right. If we had done eng testing before merging we could have avoided this.
> • I think the key takeaway here is that while eng testing post merge works and can be done safely for just the SMM repo,
>     ◦ Once mobile-shared comes or any other shared repo comes in to play, it allows untested code to be released :melting_face: .
> • So rather than keeping one rule for the SMM repo (eng test after merge) and another for mobile-shared (eng test before merge), i think it'll be easier just to revert back to the blanket eng test before merge rule we had.
>
> Sidenote: Still think that eng testing every ticket is a massive time waste. But until we figure out a better more targeted approach. We should just revert back to the previous rule.

**E7. Confluence RFC review, disagreeing with a counter-proposal** (Wallet RFC, 2026-07-09)
> @Shaun Saker did a first pass. Decent start. Theres lots that still need fleshing out with the current approach though - see my inline comments.
>
> Also, I dont think trying to decouple cards from tasks and card templates from taskDefs is a good idea. The task and taskDef system was implemented to support all the intricacies of offline first behaviour for forms and templates. If you eject cards, card templates and the wallet from it we'll end up rebuilding a lot of those mechanisms by scratch and by v2 we will have re-built it again fully, just with different names.
>
> Instead I'd push you towards decoupling tasks and taskDefs from workspaces . ...
>
> This way you get the submission and syncing mechanisms almost for free. ... But we can pair on this - we'll need a lot of this for actions later on as well.

**E8. Confluence reply to a reviewer: acknowledge, then hold position** (SMM-1868 Drafts, 2026-04-30)
> @Cameron Bourke  great points, your approach is definitely simpler for solving the immediate problem.
>
> The concern I have is that `Initial` is already doing a lot of work, its currently the only status that is overloaded like this which is a good indicator that its reponsibility is too ambiguous. ...
>
> Your approach adds another, checking `Initial` in `handleBeforeRemove` to decide if it's safe to delete on exit. It works, but it's one more place where `Initial` means something specific that the status itself doesn't express and requires inferred context.
>
> The new state makes each check explicit. ... But to your point, there is an implementation cost associated with it. Its a new enum value and we have to update the places that check `Initial`. But, architecturally I think thats the right direction to go in. Less ambiguity in the code base makes it more maintainable.

**E9. Confluence reply to senior external reviewers, pushing back on scope** (Check field RFC, 2026-03-02)
> Thanks for the feedback @Tim Bray and @Nick Lammertyn. Yeah, covering GI feels like it should be done in a follow up RFC. Bringing that context in right now will complicate the implementation. If weren't under heavy time constraints it makes sense to do the GI implementation from the get go but it feels like a bit of scope creep at the moment.

**E10. Confluence flat verdict after thinking it through** (Check field RFC, 2026-02-23)
> @Shaun Saker @Cameron Bourke thought deeply about this. We cant make this truly generic, it'll always need to have some issues related functionality tied to it. If we pass in a custom validator we lose the ability to validate it from the api in the same way. ... Trying to get our check field implementation to service both GB and DP will just create a big mess. The yes/no/na field can be extended quite easily to support pass/fail/na. When it comes to it lets just do that.

**E11. Confluence RFC body (SMM-2636, 2026-10). A register he signed off on. Probably co-written with his agent (see report §1.3)**
> Tapping Submit does not call the server. It marks the form as ready and waits for the uploads to finish. Once nothing is left, the app sends the submission, and the server creates the record and replies.
>
> **Preferred: 2, the server finishes.** It is the only option that needs nothing from the app once the last file is uploaded.

**E12. Jira comment**
> skipping eng testing for this one:
> * the only thing an engineer would be able to do here that UAT cant is check the dynamo db to ensure the properties aren't clobbered.
>     * This is evident via the UI so dont think its worth checking.

## 10. Checklist before handing over a draft

- [ ] Register matches where it's going (§1). An RFC reply is a Confluence comment.
- [ ] No em dashes. No "TL;DR", "key thing", "To be clear", "However", "Additionally".
- [ ] The opener is a 1–5 word acknowledgement, or the problem itself. Never a praise paragraph.
- [ ] Any "X, not Y" constructions? Rewrite all but one at most.
- [ ] Mean sentence length is about 15 words or fewer.
- [ ] Ends on a question, a verdict or an offer to pair. No recap.
- [ ] Spelling, apostrophes and capitals are correct. His Slack typing habits are not reproduced.
