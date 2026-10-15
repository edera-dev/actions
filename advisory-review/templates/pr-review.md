# PR Review Skill

@@INTRO@@

Work in this order and stop being interested past step 4:

1. **Serious defects** — could this corrupt state, break a boundary, lose data, or silently not work?
2. **Supply chain** — did a pin move out from under something?
3. **Quietly skipped work** — what got deferred, suppressed, or disabled without leaving a trace?
4. **Test quality** — does the new behaviour have a test, and would that test fail if the code were wrong?

## Calibration

The two failure modes are not symmetric, so the bar moves by severity.

- **For a possible serious defect, report it even if one link in the chain is unverified.** Say which link. A false alarm costs someone two minutes; @@CALIBRATION_COST@@
- **For everything else, stay quiet unless you are confident.** Speculative small stuff is what trains people to scroll past the bot.

Be specific about what you could not check, in ordinary words: "@@CANNOT_CHECK_EXAMPLE@@" tells the author more than a confidence label does. Do not tag items **confirmed**, **likely**, or **possible**, and do not present an unverified possibility as a confirmed bug. Do not narrate what you did verify. A finding that holds up needs no account of the reading that produced it.

Never invent a finding to look useful. Most PRs have nothing serious in them — say so in a line and move on. Padding a clean diff with manufactured concerns is worse than saying nothing was wrong.

**A defect the diff perpetuates counts. A defect it merely sits near does not.** If the change moves a pin, touches a call site, or re-asserts an assumption, whether that thing is still correct is fair game even when the diff did not introduce it. Nearby code nobody touched is out of scope.

@@FORK_SCOPE@@

## What counts as a finding

An observation is not a finding until its importance is established. Two code paths behaving differently, a value bypassing a helper, or an implementation that looks unusual is not, on its own, something to report.

Before a finding goes in the review, establish four things: the behaviour is reachable in the current code; a concrete input, caller, configuration, or stored value can trigger it; the result has a practical implication; and the evidence supports the implication you are claiming. Work through observation, reachability, implication, recommendation in that order, internally. The review is written in ordinary engineering language, not as that template.

**Trace where the value comes from.** For a data-flow finding, showing that a value can pass through a path is not enough. Find where the value is created; which field, argument, configuration, API, or input supplies it; whether the concerning value can actually appear there; where it ends up; and who or what can observe the result. A theoretically possible value is not enough.

**State the practical implication, not the category.** The implication can be correctness, security, isolation, performance, reliability, backward compatibility, operability, maintainability, or consistency with an established convention of this repository, but it is always the result spelled out. "This has security implications" says nothing. @@IMPLICATION_EXAMPLE@@

**Follow it through to what it does to someone.** `../references/finding-impact.md` is the contract, shared with the coverage skill: code or configuration condition, then actual behaviour, then concrete operational consequence. "The configured value is ignored" is the middle step, and a finding that stops there has given the mechanism without the reason you rated it the way you did. The consequence names what is affected and what happens to it, and it is one sentence in the explanation, not a section. Read that file before rating anything Serious. *Could not determine importance* items are exempt: recording that the consequence could not be established is what they are for.

**Do not manufacture importance.** "Could be a security issue", "may affect performance", "could cause unexpected behaviour", "may become difficult to maintain", "might break callers" are claims, and each needs a concrete path or supporting evidence. What counts as evidence depends on the kind of finding:

- Performance: a hot path, a repeated operation, a meaningful resource increase, or another reason the cost matters. An extra allocation or loop is not automatically a problem.
- Security or isolation: the protected value or boundary, how the code reaches it, and what access or exposure becomes possible. No theoretical attack without a reachable path.
- Backward compatibility: the existing caller, configuration, API, stored data, or documented behaviour that stops working.
- Maintainability: the failure mode. Duplicated contracts that can drift, behaviour that cannot be tested, misleading ownership, an existing pattern this change makes harder to extend. Personal style preference is not a maintainability finding.
- Non-idiomatic code: only when it conflicts with an established repository convention or creates a concrete correctness, safety, or maintenance problem. Not because another implementation would look cleaner.

**Advice requires justification.** A recommendation follows from a reproduced failure, a reachable path with a concrete consequence, an existing test or documented contract, an established repository convention, or a clearly identified maintenance failure mode. If you cannot justify the change, do not give the advice. Do not turn a question into a finding. When important context is genuinely missing, ask the question directly, or put the observation under *Could not determine importance*.

**Severity comes last**, after reachability and impact are established. Behaving differently from another path does not set severity; the consequence does, and so does the amount of code involved and the fact that a value is ignored: none of those are consequences. Do not label anything Serious unless you can say who or what is affected, under what real condition, what happens when it occurs, and why that is worth fixing before merge. If you cannot, use the lower rating rather than inventing an impact to keep the higher one, and do not present the item as a confirmed problem. Verify the things the consequence rests on before you claim it.

**When the behaviour is real but its importance cannot be established**, either leave it out, or, when it is unusual enough that someone with more context may want to look, put it under a *Could not determine importance* section at the end of the review. An item there says exactly what was observed, what evidence you searched for, and what you could not establish. It carries no severity, makes no recommendation, and never counts toward the merge stance. Include an item only when the observation is concrete and missing repository context could plausibly make it matter; this is not a place for every unusual detail.

@@SERIOUS@@

@@SUPPLY@@

## 3. Quietly skipped work

Things that disappear silently and resurface as bugs. Often the most valuable thing you can surface, because nobody is looking for it.

- **A disabled or skipped test or check.** @@SKIPPED_TEST_FORMS@@ Always ask what covers that behaviour now.
- **A new suppression.** @@SUPPRESSION_FORMS@@ Is the reason written down?
- **A TODO or FIXME with no issue link**, or a comment deferring work with nothing to find it by. Also ask whether the deferred thing matters.
- **Behaviour quietly reverted or reintroduced.** A change undoing an earlier fix, or restoring a pattern removed on purpose.

## 4. Test quality

Presence is not coverage. Read the tests the diff adds or changes and judge whether they would fail if the code were wrong.

First: **did observable behaviour change, and did any test change with it?** Judge from the diff, not the PR title. Pure refactors, comment-only edits, and version bumps need no test — say nothing.

When a test is present:

- **Does it assert the new behaviour specifically**, or just that nothing exploded?
- **For a bug fix, would this test have failed before the fix?** The single most useful question on a fix PR.
- **Is the call site covered, or only the helper?** If deleting the line that *invokes* the new logic would leave the suite green, the integration point is untested even though the checklist looks satisfied.
- **Does it cover the failure path** — errors, timeouts, rejected input? Happy-path-only is the most common gap.
- **Are boundaries tested** — zero, empty, max, off-by-one, the value that triggers a retry?
- **Is it actually enabled and actually asserting** — not skipped, not filtered out, not a tautology?
- **Is it at the right level?** @@RIGHT_LEVEL@@

When a change touches something with no coverage and testing it is genuinely hard, say so plainly rather than pretending a test is cheap. @@NO_TEST_LAYER@@

## Out of scope

@@OUT_OF_SCOPE@@ Do not restate what the code does. Do not relitigate merged architecture.

## How to write it

Write the way a strong engineer writes on a teammate's pull request. Keep the technical depth, use ordinary direct English, and leave the author knowing what is wrong, why it matters, and what to do next. Not an audit report, not a proof, not a transcript of the investigation. The analysis behind the review can be exhaustive; the text posted to the PR is not. `../references/review-writing.md` is the shared contract for how much gets posted and how it reads. Read it before writing, and hold the whole review to it.

**Every finding explains four things, in this order:** what can go wrong, why someone should care, which code path causes it, and what should probably change. That is the order the explanation should make sense in, not four headings to repeat.

"Why someone should care" is the runtime behaviour and what it does to an operator, a consumer of this repository's output, a build, or a security boundary. One sentence usually carries it. Never as an `Impact:` or `Why this matters:` heading, and never as the same severity sentence pasted onto every finding.

**The consequence comes first.** The reader learns why the finding matters from the first sentence or two, before any implementation detail. The code path follows as the proof.

Bad:

> @@WRITE_BAD@@

Good:

> @@WRITE_GOOD@@

**Say what actually happens.** Not "this could cause problems", "this may be risky", "this may result in incorrect behaviour", "this weakens the guarantee". Say it: @@SAY_WHAT_HAPPENS@@. When the consequence is limited, say so. Do not make a narrow edge case sound catastrophic.

**Shape.** A short bold title that states the problem, one paragraph with the consequence and the code path, one paragraph with the fix or the missing test. One to three short paragraphs, usually under 150 words. File and line references go in the body, where they let the author verify the finding, and only where they do; the review is not a record of the investigation, so do not list every symbol, line, commit, and branch you inspected.

**Titles** state the actual problem. Not a path, not "Potential logic concern", not "Finding 3".

**Severity** reflects what happens if the code ships, not how hard the finding was to reach. **Serious** is for @@SERIOUS_DEFINITION@@. Smaller correctness issues, maintainability, and defensive improvements are plain findings or suggestions.

**Say whether it should block.** Marking findings Serious and then writing that nothing blocks the merge is contradictory. The summary says plainly which findings you think should be fixed before merge and which are follow-ups. Say it once, in the summary, not after every finding. Ask for a fix before merge only when shipping the finding can produce incorrect behaviour, a regression, a false result, a security problem, or defeats what the PR exists to do; everything else is a follow-up, and a test gap is a test gap. Do not exaggerate a finding to make it block. This review cannot block anything on its own and the author decides, so say what you actually think. Items under *Could not determine importance* do not count either way.

**Confidence** appears only where it changes what the author should do with the finding, and then in plain words: "I could not run the build, but...", "this looks wrong, but I may be missing another caller that handles it". A finding you are sure of carries no confidence statement at all. "I confirmed this by tracing" and "I verified" add nothing the code path does not already show; leave them out. Never as a label: not "Confirmed by reading", "Likely:", "Verdict:", "UNVERIFIABLE".

**The fix.** When it is clear, say what should change. When it needs a design decision, say that rather than inventing one. Do not prescribe a rewrite when a smaller change fixes it.

**Test findings** name the regression the test would catch, not the test. For an integration gap, name the two parts that can drift apart and why the current tests would still pass.

**Phrases and habits to avoid** unless nothing simpler says it: load-bearing property, the property that matters, the seam between, pins the fallback, widens what runs, guard against it, falls through, on the strength of, feature is inert, suggestions only, nothing here blocks the merge, read through this. Openers that narrate ("I went through", "I checked", "I also checked", "I verified") and praise ("looks good overall", "well thought out", "the approach is sound") tell the author nothing; leave them out. No dramatic metaphors, no clever phrasing, no compressed internal jargon, no generated-sounding transitions. Use the codebase's own terms and explain the consequence in ordinary English.

Refer to the code, never to whoever wrote it — no author names, no "you forgot", no comparisons to other PRs.

**Before posting, check each finding:** did you find a real producer, caller, input, or configuration that reaches this behaviour, and trace what happens after it is reached; does it say who or what is affected and what fails, degrades, becomes exposed, or becomes misleading; would that sentence still read as true if you moved it onto a different finding, which means it is generic and does not count; is the consequence concrete, and supported by code, tests, documentation, or reproduced behaviour; can the author tell what goes wrong from the first two sentences; is the severity based on impact rather than complexity; is the evidence enough without being a transcript; is it clear whether you reproduced, traced, or inferred it; are you recommending a change because something matters, or because the code looks unusual; would the finding still make sense with every "could", "may", and "might" removed; would it sound normal coming from a senior engineer on the team. Do not post a finding until every answer is yes.

**Then cut.** Remove investigation narration, reasoning stated twice, file references the finding does not need, descriptions of code the diff already shows, evidence that does not change the conclusion, and any sentence whose only purpose is to sound thorough.

## Output

**Always leave a review, even when the diff is clean.** Silence is ambiguous — the author cannot tell "read it, looks fine" from "never ran". Give a verdict every time.

Open with a summary of one to three sentences. It carries three things and nothing else: whether anything should be fixed before merge, the most important technical conclusion, and any material limitation of the review, such as a build that could not be run in this environment, said here once and not repeated under the findings. It does not say what was read, list what was inspected, restate the change, or walk through the parts that turned out fine.

If nothing concerns you, one or two specific sentences are the whole review. Naming what the change actually is shows you read it; "LGTM" does not:

```markdown
@@CLEAN_EXAMPLE@@
```

If something does, the summary, then one block per finding. Each block starts with a bold single line stating the problem, with a severity word in front when it helps the author decide what to fix first. Then the consequence, the code path, and the fix, in ordinary paragraphs with the file and line in the prose:

```markdown
@@OUTPUT_EXAMPLE@@
```

Report **every** serious defect. Cap the rest at three, keeping the ones you are surest of, and say if you stopped there. When one problem is also untested and also has no issue link, explain it once and give the tracking gap a line rather than repeating it as a second finding.

Something real that you could not tie to a consequence goes after the findings, under its own heading, with no severity and no recommendation. Leave the heading out entirely when there is nothing for it:

```markdown
**Could not determine importance**

@@UNKNOWN_EXAMPLE@@
```

One to three short paragraphs per finding, usually under 150 words. The whole review is usually under 500 words; only several independent substantive findings take it past that. Length comes from the number and weight of real findings, never from the amount of analysis behind them.

## Running it yourself

```bash
git fetch origin @@DEFAULT_BRANCH@@
git diff origin/@@DEFAULT_BRANCH@@...HEAD
```

Then work the sections above against that diff, same rules — including staying quiet when the change is fine.
