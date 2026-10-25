# Thev's RFC body voice: drafting reference

Use this when drafting or editing the **body of an RFC or decision log** that goes out under Thev's name. It extends `.agents/skills/captain-voice/voice-profile.md`. That profile still covers Slack, Confluence comments and Jira, and its rule zero and §7 anti-patterns still apply here. A reply to an RFC review comment is **not** RFC body. Use the profile's Confluence comment row for that.

It is built from 25 RFC and decision-log pages he drove (Sep 2024 to Oct 2026), all read in full. The evidence and the trust grading are in `report.md`. In short:

- **Tier A, his own hand** (15 pages, Sep 2024 to Jan 2026, ~12.7k prose words): typos, dropped apostrophes, "(?)" asides, "Ez.", first person. The voice below comes from these.
- **Tier B, mixed** (6 pages, Jan to May 2026): his edits on top of agent-shaped text. Used only to date when the shift happened.
- **Tier C, agent co-written and signed off** (SMM-2636 and its three child pages, Oct 2026, ~7.6k words). The page links a claude.ai artifact. It has em dashes, rhetorical "X, not Y", and "rather than" at 8 times his rate. Use it only for the **structures** he has since adopted (the `Preferred:` panel, the Rating and Risks rows, Known limits), and write them in Tier A wording.

Where the two disagree, Tier A wins. The aim is his voice, not an echo of an earlier agent draft.

---

## Rule zero

**No em dashes.** There are 0 in 12.7k words of his hand-written RFC prose. Every em dash in the RFC corpus is in an agent-era page (SMM-1997: 7, SMM-2636 server page: 6, SMM-2636 parent: 3). Use " - ", a full stop, or a semicolon. He uses semicolons occasionally: "There is only one major limitation in this approach; to achieve column freezing we need to implement a horizontal scroll view per table row."

---

## 1. The three markers that most separate his RFCs from agent drafts

Measured per 1,000 prose words. Tier A is his own; Tier C is SMM-2636.

| Marker | Tier A (his) | Tier C (agent) | What to do |
|---|---|---|---|
| **"we"** | **17.6** | 0.8 | Write proposals with "we" as the subject: "We can...", "We will need to...", "we need to". This is the biggest gap. |
| "Currently" (starting the status quo) | 14 uses | 0 | Open the Context with "Currently," or "We currently...". The agent wrote "today" 32 times (2.0/1k). He never does. |
| "rather than" | 0.3 | **2.4** | Use it once at most. The agent version is a tell. |
| "so" | 1.2 | 8.3 | Use it as a joiner when it fits. Don't push it in. |
| "the user" / "users" | 7.9 | 1.6 | Talk about what the **user** experiences. The agent talks about "the app" and "the phone". |
| "our" / "us" | 2.9 / 1.3 | 0.7 / 0.1 | "our current upload system", "our users", "allows us to". |
| "already", "only", "exactly" | 0.9, 1.5, 0 | 3.1, 3.4, 0.6 | Don't stack these intensifiers. |
| Story points in the body | 2.1 | 0 | Hand-written staging tables always carry estimates ("1.5sp", "3 sp"). |
| Rhetorical "X, not Y" | 0 | 0.9 | Never. His only ", not" phrases set scope literally ("impacts all forms, not just forms with frozen headers/columns"). |

**Sentence length is the same in both** (mean 16.7 vs 16.2 words, median 15 in both, about 17% of sentences 25 words or more). Length is not the tell. Subject, tense and vocabulary are.

---

## 2. Section architecture

### The template is the skeleton, not his choice

His section names and heading emoji come from the MOB RFC template. The unfilled template (page `2886205474`, Aug 2025) has:

`:cowboy-eyes: Overview` → `✨ Context` → `⭐ Proposal` → `:jira: Staging Plan / Tickets` → `🤔 Considerations` → `🐌 Performance 🐇` → `◀️ Compatibility & Backwards Compatability` → `🌟 Definition of success`

The 2024 to early 2025 template put ✨ on every heading ("✨ Overview", "✨ Context", "✨ Proposal", "✨ Considerations"). Decision logs use the ENG decision template: `📚 Problem to solve`, `Background`, `☑️ Criteria & weighting`, `🌈 Options considered`, `🌟 Outcome`.

**What he does with it:**

- He **keeps** the template sections he uses and **deletes** the ones he doesn't, even Overview. SMM-1423 has no Overview: it opens with "The Issue".
- When he **adds** a section, he copies the template's ✨ onto it: "✨ Technical" (SMM-1452), "✨ The Future" (SMM-1187), "✨ Mid Implementation circle back" (SMM-1281), "✨ Future" (SMM-1281).
- Sections he commonly adds: **Technical** or **Current flow** (a walkthrough of today's code path), **Implementation**, **Future** (what is deliberately deferred), **Current Limitations** (SMM-1105), **Changelog** (SMM-1452, "📓 Changelog"), **Entity Lifecycle** (V3 Stage 1), **Security Risk** (SMM-2037).
- He often leaves the template's instruction panel ("Ensure to fill out all fields in the RFC template...") and empty checkbox lists in place. **Delete these when drafting.** They are template residue, not voice.

**Heading emoji rule:** use the template's emoji and add none of your own. When writing through the API, custom emoji (`:cowboy-eyes:`, `:jira:`) do not carry over. SMM-2636 swapped in 🤠 and 📋, which is acceptable. DL headings inside an RFC take 🌈: "🌈 DL 1: Where does a submission finish?"

**In-body emoji** are rare and his own: two 💸 in two years ("This approach will accrue some serious technical debt 💸", "Commercial Solution excels in UX and performance but too costly 💸"). Optional, at most one per RFC, never in the agent-era pages.

### Size decides the shape

| Size | What he does | Example |
|---|---|---|
| **One decision, under ~800 words** | Drops the template. Uses his own plain headings in story order, or the decision-log headings. | SMM-1423: "The Issue" → "Our Current reCAPTCHA Implementation" → "Attack Pattern Observed" → "Key Vulnerability" → options table → "Proposal". "Offline form limit complexity": bold **Context**, **Problem**, **Options:** and nothing else. |
| **One feature, 1.5k to 3k words** | Full template. The Proposal is a short paragraph plus numbered expands holding diffs: "1.) Add userSummaries as a task dependency for tasks", "2.) Leverage existing user events", "3.) SMM changes". | SMM-1217, SMM-1333, SMM-1187, SMM-1032 |
| **Cross-team** | A short parent page with numbered phases, then one RFC per stage. Each stage subsection ends with a two-column **"SMM team to implement \| GB team to implement"** table. | SMM-1542 parent (220 words), V3 Stage 1, SMM-1871 |
| **Very large (agent era)** | A parent page with four decision logs, plus three child pages, each with its own Mini DLs. | SMM-2636 |

He iterates in the open. V1 and V2 of the Gearbelt Stage 1 RFC are kept and marked "(Deprecated)". V3 opens: "This RFC builds upon 2 previous RFCs that explored different approaches to achieve this functionality." SMM-1281 has a "Mid Implementation circle back" section added after the PR landed.

### Overview vs Context

**Overview: what this RFC does, in 1 to 3 sentences.** Usually it is "This RFC" plus a verb: *proposes* (SMM-1057, SMM-1032), *aims to* (SMM-1187), *explores* (SMM-1363, SMM-1300, SMM-1871), *describes* (SMM-1452). "In this RFC we aim to scope out..." (SMM-1333) and "In this RFC we will go over..." (SMM-1217) are variants. When the problem is sharp, he states it flatly first and leaves out "This RFC" (SMM-1281). He does not put background, history or numbers in the Overview.

**Context: today's behaviour, then what is wrong with it, then who asked.**
1. Status quo, opening with "Currently," / "We currently..." / "Our current...", with links to the code lines or the Figma flow.
2. The limitation, introduced with "This makes...", "This has led to...", "This limitation creates...", "As a consequence...", or "However, when...".
3. Demand: the customer or ticket. "This functionality has been requested by ABB.", followed by three Fathom clip links.

Mechanism detail goes in Context or in a **Technical** section. The Proposal does not re-explain the problem.

---

## 3. Decision logs: the options table

### His hand-written table (2024 to 2025)

- **Header row:** an empty top-left cell, then **Option 1 | Option 2 | ...**
- **Row "Description":** the option's **name** in bold, 2 to 7 words: "**Regular Deeplinking**", "**Use Recaptcha V2 exclusively**", "**Hybrid Approach (client + server)**", "**Native Bridge Approach**". It is a name, not a sentence.
- **Rows "Pros" / "Cons":** short verbless fragments, often bold, one per line: "**No additional costs**", "**Low implementation effort**", "**Massive implementation overhead**", "**Still leaves us open to some attacks**". An item that needs explaining gets a bold label, then " - " and the explanation: "**Very poor UX** - Having to do a captcha challenge to login every single time is bound to annoy our users". A longer list gets bold group labels with colons and sub-bullets: "**Native platform support:** - Uses built in iOS/Android mechanisms - No third party dependencies required".
- **Row "T-shirt size":** XS / S / M / L / XL, combined values like "L/XL", or a qualified one: "**S, but very expensive**".
- In 2024 he also used weighted criteria with x/10 scores ("Security (30%)" ... "**Hybrid Approach**: 9/10 - Centralised control and consistent with existing security measures"). He has not used this since October 2024.

### The current table he signs off (2026, SMM-2636 family)

- **Header:** `**1: keep it on the phone**`, `**2: the server finishes**`. Number, colon, then a lowercase verb phrase.
- **Rows:** Description | Pros | Cons | Rating against criteria | Risks.
- **Description** is one sentence of 10 to 20 words.
- **Pros / Cons**: 1 to 3 items per cell, 5 to 15 words each, each item prefixed with the `:plus:` or `:minus:` Atlassian emoji.
- **Rating against criteria**: two lines. The `:plus:` line, in green text, lists the criteria the option meets, joined with " · ". The `:minus:` line, in red text, lists the criteria it misses, each with a short reason in brackets. Verbatim: ":plus: Implementation cost · Cross-team dependency / :minus: Survives the app stopping (fails the one that matters most)".
- **Risks**: 1 or 2 full sentences naming the failure and its consequence.

**There is no hand-written example of the Rating against criteria row.** It exists only in the SMM-2636 pages. For a new DL, keep the row (he signed it off and reviewers now expect it). Keep the criteria names short and reuse them across all options. Put the reasoning in the brackets, as SMM-2636 does.

**Writing cells in his voice:** Pros and Cons are fragments, not sentences. No "This option...". No full stop after a single fragment. Plain nouns and verbs: "Lightweight", "No longer maintained", "Harder to customise", "Larger". He will add a frank aside in brackets: "Requires complicated state tracking (this just may be a hang up of how we have the system implemented rather than a limitation of the library itself."

### The preference statement

He has written it four ways. All are flat, and none starts with "We recommend".

| Form | Verbatim | Page |
|---|---|---|
| "Given ..." | "Given the above points for our current needs regular deeplinking will suffice." | SMM-1363, 2025 |
| "Given ..." | "Given the decision criteria, the **Hybrid Approach** is recommended for the following reasons:" (then bold group labels with bullets) | PDF Sanitisation, 2024 |
| Bold verdict | "**Server side management is preferred.**" | SMM-1300, 2025 |
| Bold label | "**Decision:** Option 2 appears to be the most robust and safest out of the 3." | SMM-1300, 2025 |
| Outcome heading | "Inspections and Issues in SMM will be represented by single submission tasks." | DL ongoing vs single, Jan 2026 |
| `Preferred:` panel (current) | "**Preferred: 2, the server finishes.** It is the only option that needs nothing from the app once the last file is uploaded." | SMM-2636, 2026 |

**Use the current form for new DLs:** a green success panel holding `**Preferred: N, <the option's header phrase>.**`, then **one sentence naming the single property that decides it.** Optionally add a second sentence with a precedent or the cost of the alternative:

> **Preferred: 2, extend what we own.** Option 3 is roughly four times the code it replaces.

> **Preferred: 2, through a queue.** Delayed redelivery is the deciding feature: a missing file needs a second look later, and only a queue gives that without building a scheduler.

The sentence after the verdict is a reason, not a restatement. In his hand-written pages the reason is equally short and concrete: "Given the infrequent(?) nature of these attacks, we'll implement a measured first response by increasing our reCAPTCHA v3 threshold from 0.5 to 0.7."

---

## 4. Sentences and paragraphs in RFC prose

- **Length:** mean 16 to 17 words, median 15. About 38% of sentences are 12 words or fewer and 17% are 25 or more. Mix one long mechanism sentence with two or three short ones.
- **Paragraphs:** 1 to 4 sentences. Explanation that needs more goes into bullets or an expand.
- **Declarative and future-tense for the plan.** "We can achieve the required freezing of rows and columns by restructuring the following components." "This will be done in 3 parts." "We will need to migrate the data from our existing file structure into the new one with this release." Present tense for how things work today.
- **How he opens a section:** a plain topic sentence that says what the section does, or the fact itself. "Currently, our system prevents users from...". "Our current upload system is too complex.". "The current table implementation (non frozen) centres around a monolithic TableField component...". "Having done a similar migration for the activity state previously we have a good framework of what needs to be done.". He never opens with a question or a scene-setting line.
- **Connectives:** "However," (1.2/1k, mid-paragraph), "Which" to start a follow-on sentence ("Which makes it difficult for our users..."), "This means", "Instead", "Additionally" (3 times in Tier A), "Since", "As a consequence". The voice profile bans "However" in comments and Slack. **In an RFC body it is attested 16 times in Tier A.** Default to "But". One "However," per section is acceptable and in character.
- **Soft quantifiers he uses:** "quite" ("It is quite opaque"), "a lot of", "some", "a very large amount of code", "significant". Plain adjectives: "too complex", "poor user experience", "hard to resolve bugs".
- **First person singular is rare and is used for motive or opinion only:** "This refactoring was motivated by the challenges I faced when trying to isolate and add frozen panes to Prefilled tables" (inside an info panel). "Personally, I prefer RTK because it is **opinionated**". Once per RFC at most.
- **Bold lead-ins.** His bold opens a **label**, not a sentence: "**Activity State**", "**Current:**", "**New:**", "**API:**", "**SMM App changes:**", "**End goal:**", "**Reason:**", "**Decision:**", "**IMPORTANT**:", "**Important**:". He bolds a whole sentence only for the one instruction a reader must not miss: "**We will need to migrate the data from our existing file structure into the new one with this release.**", "**The issue taskDefinition must be filtered out from the inspections list screen on SMM**". In SMM-2636 about half the paragraphs open with a bold sentence ("**Force quit is not covered...**"). That is the agent's habit. Allow it only inside a Known limits list.
- **Mid-sentence emphasis:** bold or coloured text on the one word that matters: "**All state interactions should occur via this service**" (red), "This should be the **only** place...", "PersonStates **does not** apply to SMM".

---

## 5. Facts and numbers

He puts a number wherever a claim could be argued with, and he links to its source.

- **Where numbers go:** the Impact or Context section (size of the problem), the options table (cost, size), the Proposal (the threshold or limit being changed), and every staging row (story points).
- **Precision follows what was measured.** Counted things are exact: "We have **305** failed PDF upload attempts in SMM in just the past month (**September 30th - October 29th) :** Datadog Reference". "This task will touch on a total of **25** files". "every 14 seconds". Prices are exact: "US$500/month", "PSPDFKit: $4,999/year base license". Estimates are marked as estimates: "new pricing model is opaque but purported to be 4-5 figures", "15+ seconds", "40 - 50%", with a footnote: "These performance estimates are based on RN optimisation patterns and similar rendering improvements. Actual results may vary and should be validated through performance profiling".
- **How he sources them:** an inline link on the number or a trailing "ref", for example "(see the attempts stop after the `Invalid Captcha` error, this is when it switches to V2 - ref)", or a link on the words "14 seconds" pointing at the code line. A ticket key sits next to the claim it backs (SMM-1315, SMM-738).
- **Scales get context:** "increasing our reCAPTCHA v3 threshold from 0.5 to 0.7. This represents a significant increase on Google's 0.1-1.0 scale, where 0.5 is the typical recommended threshold."
- **2026 adds:** `file:line` references ("`UploaderModule.kt:167-182`"), lifetime counts ("158,302 lifetime occurrences"), line-change splits ("Of the submission code's 733 lines, 36% is unchanged, 41% altered and 23% deleted") and cost at volume ("Roughly $0.007 a month in AU on-demand pricing"). These are fine to keep, provided each one is sourced.

---

## 6. Risk, limits and things not yet verified

### In his own hand

- He names the weak point of the option he chose, in its own subsection: "**Disadvantages of the Chosen Approach:**" (SMM-1057, SMM-1032) or "Disadvantages/ concerns of current approach" (SMM-1187), then the mitigation in the same bullet: "Somewhat of an overhaul. However we can leverage the existing table field tests to minimise most of the uncertainty that comes with this approach."
- **Current Limitations** (SMM-1105, Dec 2024) is the hand-written ancestor of Known limits. It states the limit, how it shows up, what was tried, and what is still open:

> There is only one major limitation in this approach; to achieve column freezing we need to implement a horizontal scroll view per table row. It has proven difficult to sync these scrollViews in the PoC stage to achieve smooth scrolling. There is always some choppiness even on small tables.

- **Unverified things are marked briefly, in place.** He uses no hedging paragraph:
  - "Given the infrequent(?) nature of these attacks"
  - "Remove the abstract upload service entirely..?"
  - "Suspicion here is that since this is creating a `worklet` function and seems to not be supported by `Reanimated`"
  - "POC not done yet. Will probably not invest time in this unless both of the other options have insurmountable issues."
  - "WIP - Can do this last. (Found potential clash between the activity state preservation work we did between logins. Need to think this out properly)"
  - "Not sure it's worth the effort yet"
  - "We need to asses whether changing the key structure like this is feasible"
  - "(This may have performance implications)"
- **What is deliberately out of scope** gets its own short list: "Currently not needed - No asset deletion from S3 when removed from forms - No upload cancellation handling - No orphaned asset cleanup (future enhancement)". The **Future** section says what a later RFC would pick up.

### The Known limits shape he signs off (2026)

A bold one-sentence claim, then 1 to 3 sentences on the mechanism, then what would fix it or who carries the risk:

> **A lost signal for an app never reopened is not recovered.** The five minute check can only find submissions it knows about, and a lost signal means the server never knew. Only the app rewriting its file list recovers that, which needs the app to run again.

Unverified claims are flagged as such: "Observed in a local trace.", "Two iOS claims rest on Apple's documentation rather than observation, covered by the stage 0b spike." Use this shape, and keep the claim sentence free of "X, not Y".

---

## 7. Tables, bullets, panels, expands

- **Tables** for options, staging, compatibility, field mappings, and cross-team splits ("SMM team to implement | GB team to implement").
- **Bullets** for proposal steps, scope lists, and Definition of success. Nested bullets two or three deep are normal in his hand-written pages.
- **Prose** for Overview, Context and the paragraph leading into a Proposal.
- **Expands** hold code, diffs and long file lists: "Current list of files using ActivityStateContext:", "Pros and cons", "Why Immer?". Expand titles can be numbered steps: "1.) TaskContext Provider + Task state reducer ---> Task Slice + Update zustand store to support slice". The main page should read without opening anything.
- **Panels:** an info panel for motive or an aside ("This refactoring was motivated by..."), a warning panel for a **Reason:** or a gotcha, an error panel for a hard warning ("This step will likely break a lot of tests that need to be fixed!"), and a success panel for the `Preferred:` line.
- **Code** is shown as diffs with `+` and `-` against real file paths, with inline comments that talk to the implementer: "// Eventhough this will always be singular unlike lists we still need to pass it through here", "<-- teamId doesnt exist in the metadata currently we will need to add it in".

### Staging plan rows

Hand-written columns: **Summary | Description | Story points**. He sometimes adds **Notes**, **Release** or **Ticket**.
- **Summary**: an imperative phrase or the ticket key.
- **Description**: 1 to 4 bullets, each starting with a verb ("Create...", "Update...", "Make the required changes...", "Implement..."). A dependency is stated in plain words: "We will be using the teamId added to person fields in the previous ticket so this must happen after that".
- **Notes**: frank planning remarks: "This is heavily DP-API focused. We may need to schedule a ticket with them", "This doesnt need to be done alongside the default tables frozen panes work and is better suited for a maintenance sprint".
- **Story points**: "3 sp", "1.5sp", "2.5sp", sometimes with an aside: "1.5sp May have to stuff around with some cdk stuff." Includes a **TOTAL** row.

The 2026 version: a bold numbered Summary ("**1: stop the crash**"), Description in full sentences, with a bold must-do sentence where needed ("**Must land before stage 4 reaches Gearbelt submissions.**"), points left blank, and a closing line that says what each stage delivers: "After 1 the crash is gone. After 2 large files upload on iOS..."

### Definition of success

Hand-written: 1 to 3 bullets, each a short noun phrase or a plain outcome: "Clean separation of tables", "Default table with frozen panes", "Cleaner logs", "Maintainable + extensible code", "Users are able to start new forms while offline", "No impact on users", "All ACs of SMM-359 are met." 2026: a **Criterion | How it is verified** table. Either works. Keep criteria concrete and checkable.

---

## 8. What he never does in an RFC body (and a generic drafter would)

Zero occurrences across ~12.7k words of his hand-written RFC prose:

- Em dashes, en dashes used as dashes, or the rhetorical "X, not Y" frame
- "TL;DR", "In summary", "To summarise", "Key takeaways", "In conclusion", or a closing recap. His RFCs end on Definition of success, or on Compatibility, and stop
- "Importantly", "Notably", "Crucially", "we believe", "It's worth noting"
- "genuinely", "battle-tested", "load-bearing", "belt-and-braces", "exactly the case", "the realistic shape", "Key Insight", "Precedent:" (all from the 2026 agent pages)
- "today" for the status quo. He writes "Currently" or "our current"
- A whole page in the third person about "the app" and "the phone" with no "we" and no "users"
- Question-form sub-headings in the main flow ("**Why store on the field?**", "**Why two sources?**" in SMM-1995). His questions sit in expand titles ("Why Immer?") or are one-line asides ("Wait.. what about the actual frozen panes functionality?")
- An Overview longer than four sentences, or one that carries numbers and history
- A preference stated as "We recommend..." followed by a paragraph that restates the table

---

## 9. Exemplars (verbatim)

His typos are kept in the quotes so the record stays exact. **Correct the spelling, apostrophes and capitals when drafting.** Don't copy "Ez." or "stuff around" into anything going to senior reviewers.

**R1. Overview: the problem stated flat** (SMM-1281, Feb 2025, Tier A)
> Our current upload system is too complex. It is quite opaque and it is hard to determine the root cause when failures/ errors happen. This has led to hard to resolve bugs and lots of support requests.

**R2. Overview: intent and scope** (SMM-1105, Dec 2024, Tier A)
> Being able to freeze the table header + certain rows and columns has been a highly requested feature on Dashpivot and SMM. Once this functionality has been introduced to DPW and a user creates a form with a table that has frozen panes, it needs to be shown to users on SMM. The purpose of this RFC is to flesh out what is required to freeze the table headers and the first column on SMM
>
> Following suit to DPW this RFC will only focus on pre-filled tables.

**R3. Overview: "In this RFC we..."** (SMM-1217, Jan 2025, Tier A)
> The Person Field implementation in SMM differs from DPM, as SMM users interact with forms and templates through links rather than a direct team association. The main implementation challenge is ensuring accurate user data population within the Person Field.
>
> In this RFC we will go over implementing user summaries as a task dependency, which allows us to leverage the existing task synchronisation mechanism to enable automatic updates when workspace/ team membership changes.

**R4. Overview he signed off** (SMM-2636, Oct 2026, Tier C. The structure is good. Note it has no "we".)
> A user fills in a form, taps Submit, and locks their phone. When they open the app later they expect the form to be done.
>
> Often it is not. The phone uploads the photos, the phone notices they all arrived, and the phone tells the server to finish. All three need the app running, and the moment a user locks their phone or switches apps, the operating system stops it within about thirty seconds.
>
> This RFC moves the end of a submission from the phone to the server. The app's job ends when the last photo has finished uploading.

**R5. Context: status quo, limitation, who asked** (SMM-1105, Tier A)
> We currently have no way to freeze table rows and columns. Which makes it difficult for our users to refer through large tables without constantly having to scroll back and forth. This makes for a poor user experience.
>
> This functionality has been requested by ABB.

**R6. Context: mechanism and consequence** (SMM-1300, May 2025, Tier A)
> Currently, our system prevents users from starting a new instance of a recurring template or single submission form until the previous form initiated through that link has been submitted. This limitation creates significant challenges for users working in areas with poor network connectivity, as many need to complete multiple instances of the same form while online and submit them all simultaneously when connection is available. This workflow restriction is causing friction and reducing efficiency for these users.

**R7. Context and problem for a small decision** ("Offline form limit complexity", Aug 2025, Tier A)
> **Context**
>
> With the implementation of offline form submissions, we no longer create the next task for ongoing forms via the API. Instead, we must ensure that the next task is created on the user's device when they submit the current task. Currently, this happens when the user presses the submit button on the form. However, when the offline form limit is reached, we can no longer create the next ongoing form on the user's device at submission time. In this scenario, we must wait for a task to submit successfully before creating the next ongoing task. This means that after every successful submission, we need to check whether the next ongoing task exists and create it if it doesn't.
>
> **Problem**
>
> Having two separate instances where ongoing tasks are created results in a disjointed flow and introduces non-determinism into the ongoing task creation process. This creates additional overhead for the QA team, who must ensure both scenarios work correctly during regression testing. A disjointed flow like this also increases code complexity, requiring engineers to understand multiple mental models to avoid introducing bugs.

**R8. Full options table, hand-written** (SMM-1423, May 2025, Tier A. Each line in a cell is a separate bold paragraph in the original.)

|   | **Option 1** | **Option 2** | **Option 3** | **Option 4** | **Option 5** |
|---|---|---|---|---|---|
| **Description** | **Use Recaptcha V2 exclusively** | **Use Recaptcha V2 exclusively for blacklisted regions** | **Increase the recaptcha v3 threshold** | **Implement IP based rate limiting** | **Re-enable SMS pump protection on twilio.** |
| **Pros** | **Robust protection** <br> **Stopped our attackers so we know it works.** <br> **No additional costs** <br> **Low implementation effort** | **Robust protection** <br> **Allows users from non blacklisted countries to experience the same seamless login flow.** | **Much better user experience** <br> **Very easy to implement** | **No change to user experience** <br> **Can be extended to all lambdas.** <br> **Robust protection** | **No change to user experience** <br> **Robust protection** |
| **Cons** | **Very poor UX** - Having to do a captcha challenge to login every single time is bound to annoy our users have now gotten used to the ease of recaptcha V3 | **High Implementation effort** <br> **We will need to maintain a list of blacklisted countries** | **Still leaves us open to some attacks** | **Massive implementation overhead** <br> **Will require additional infrastructure** - Will most likely require a new dynamoDB table so we can track the requests per IP | **Cost** - 500 USD/month - Will likely increase in the future. |
| **T-shirt size** | S | M | XS | L/XL | XS |

**R9. Full options table in the current format** (SMM-2636 DL 1, Tier C, signed off)

|  | **1: keep it on the phone** | **2: the server finishes** | **3: the app calls the server at Submit** |
|---|---|---|---|
| Description | Make uploading more reliable and leave the rest where it is. | The app writes a list of its files last. That file arriving tells the server to finish. | The app tells the server at Submit, and the server waits for the files itself. |
| Pros | :plus: No backend work <br> :plus: No new failure modes | :plus: Needs nothing from the app once the last file is up <br> :plus: Reuses the code that creates records today <br> :plus: The file list rides the upload queue, which already retries | :plus: The server is told explicitly, rather than working it out |
| Cons | :minus: Submissions still wait for someone to reopen the app <br> :minus: Leaves the original problem in place | :minus: The submission code has to be restructured so it can stop and pick up again, the largest task here <br> :minus: Every external call needs a repeat rule before it is safe | :minus: The call itself can fail when offline, and would need its own durable retry <br> :minus: Needs the app alive at that moment |
| Rating against criteria | :plus: Implementation cost · Cross-team dependency <br> :minus: Survives the app stopping (fails the one that matters most) | :plus: Survives the app stopping · Reach · Cross-team dependency · Ease of change <br> :minus: Implementation cost (the resumable handler is the largest single task) | :plus: Reach · Cross-team dependency <br> :minus: Survives the app stopping (the call needs a live app) · Implementation cost |
| Risks | None new. The existing failure rate continues, still unmeasured. | The server now owns a step the app used to own, so a defect there affects every submission rather than one phone. Mitigated by the journal, the lease and the sweep. | A retry layer for the call itself becomes a second thing to get right, duplicating what the upload queue already does. |

**R10. Preference statements**
> Given the above points for our current needs regular deeplinking will suffice. *(SMM-1363, Tier A)*

> Given the infrequent(?) nature of these attacks, we'll implement a measured first response by increasing our reCAPTCHA v3 threshold from 0.5 to 0.7. This represents a significant increase on Google's 0.1-1.0 scale, where 0.5 is the typical recommended threshold. *(SMM-1423, Tier A)*

> **Preferred: 2, the server finishes.** It is the only option that needs nothing from the app once the last file is uploaded. Dashpivot already does something similar for photo processing, though without the safety net this design adds. *(SMM-2636, Tier C, in a success panel)*

**R11. Known limits and caveats**
> - A simpler approach would be to create a `FrozenDefaultTableField` with the code from `FrozenTableField` copied over. But this would duplicate a very large amount of code. Any new functionality would need to be copied into two places.
>   - This approach will accrue some serious technical debt 💸
> - Disadvantages/ concerns of current approach
>   - Somewhat of an overhaul. However we can leverage the existing table field tests to minimise most of the uncertainty that comes with this approach.
>
> *(SMM-1187, Jan 2025, Tier A)*

> **Incomplete Data Set**: Since activities are fetched on demand, if the network connection fails the user will be left with an incomplete data set. *(SMM-1032, Sep 2024, Tier A)*

> **A big file has to finish in one go.** Since an interrupted Android upload starts over rather than resuming, a file too large to finish in the time the system allows will keep starting over and never complete. Stage 5 has to stop retrying at some point and tell the user to get on a better connection instead. *(SMM-2636, Tier C)*

**R12. Staging plan rows**

| **Summary** | **Description** | **Notes** | **Story points** |
|---|---|---|---|
| Add userSummaries as a task dependency for tasks | - Make the required changes in the dashpivot API so that templates with person fields will have userSummaries as a taskDependency the same way lists are. <br> - We will be using the teamId added to person fields in the previous ticket so this must happen after that <br> - This will also ensure that when a template is retrieved form the api user summaries are added to the task data <br> &nbsp;&nbsp;- Implementation details covered in “1.) Add userSummaries as a task dependency for tasks” above | This is heavily DP-API focused. We may need to schedule a ticket with them | 3 sp |

*(SMM-1217, Tier A)*

| **Summary** | **Release** | **Description** | **Story points** |
|---|---|---|---|
| SMM-1315 | 25.3 | - Remove the unnecessary complexity from the task upload service. Add better SoC and clearer responsibilities <br> - Implement new task-submit service <br> - Implement retry mechanism for asset uploads | 2 |

*(SMM-1281, Tier A)*

| **Summary** | **Description** |
|---|---|
| **1: stop the crash** | Configure the upload library at app startup rather than on first use. Ships on its own. SMM-738. |

*(SMM-2636, Tier C)*

---

## 10. Checklist before handing over RFC body text

- [ ] No em dashes and no rhetorical "X, not Y". Count "rather than": one at most.
- [ ] The Proposal is written with "we" as the subject ("We can", "We will need to"). The page mentions users, not only "the app".
- [ ] The Context opens on today's behaviour ("Currently," / "Our current"), with links to code, tickets or dashboards. The word "today" is not used for this.
- [ ] The Overview is 1 to 3 sentences ("This RFC proposes / explores / aims to"), with no numbers or history.
- [ ] Section headings carry the template's emoji only. Any added section copies ✨. Template instruction panels and empty checklists are deleted.
- [ ] Options table: a bold name in Description, fragments in Pros and Cons, a T-shirt size or a Rating and Risks row. The `Preferred: N, name.` panel is followed by exactly one deciding reason.
- [ ] Every number has a source link or a ticket key next to it. Estimates are labelled as estimates.
- [ ] Every unverified claim is marked where it appears ("(?)", "Not sure yet", "Suspicion here is", "Observed in a local trace", "rests on documentation rather than observation").
- [ ] Bold opens labels, not sentences, except for the one must-not-miss instruction and items in a Known limits list.
- [ ] The staging table has imperative Description bullets, frank Notes, story points and a TOTAL row.
- [ ] No closing summary. The page ends at Definition of success or Compatibility.
- [ ] Spelling, apostrophes and capitals are corrected. His typos in the exemplars are not reproduced.
