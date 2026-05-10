<!-- SPDX-FileCopyrightText: 2026 Ortan Fields -->
<!-- SPDX-License-Identifier: MIT -->

# AI Usage Requirements

For this file, `AI tool`, `AI` or `AI model` refers to anything which produces non-trivial (semi-)creative output.

AST / LSP based refactoring and traditional automated tools are not covered and entirely permitted.


---

## Code

**Broadly permitted**

For AI-generated code, keep the scope to that which you could confidently say you could write entirely yourself.

For code that is beyond what you could write yourself, the lower bar is:
- You can confidently debug it.
- You've written the tests yourself without significant AI assistance.
- You've called out any AI involvement in the PR description.

AI-generated (fully or partially) code must be annotated with a header comment per-file:
- Placed after any shebang or SPDX copyright info.
- Use `Generated-By` if majority generated (even if reviewed).
- Use `Assisted-By` if non-trivial contribution was made by AI, but not the majority of the file.
- Trivial usage does not require disclosure (autocomplete, spellcheck, etc.).
- If you update an existing file, append a new comment below the existing one(s).
- If using cloud models which don't disclose exact quantization or aren't otherwise reproducible, include a current `YYYY-MM` after the model name.

For example, a file generated with one AI model, and then later significantly updated with a different one might look like this:
```sh
#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Ortan Fields
# SPDX-License-Identifier: MIT
# Generated-By: Claude Opus 4.7 (1M Context, 2026-05)
# Assisted-By: Qwen3-Coder-Next (256K Context, Q4_K_S)
```

You may also choose to include a 'commit trailer' with the same format, but it is not required, and does not replace the requirement for a header comment per-file.

### Tests / Test code

Tests may be AI-generated or AI-assisted, but be aware that AI-generated tests for AI-generated code are at best testing the code 'does what it does', not that the code 'does what you intended'.

If you want to use AI for both, we suggest you only use 'AI-assistance' for one, not full generation for both. Prompt the 'assistance' instance to be adversarial towards the generated code.

For 'assisted' tests, include additional commentary to help give future readers an idea of what was assisted, and what was written by a human.

### Translation files

For full machine translations (`mtl`) where you don't speak the target language, as well as the `Generated-By` header comment, include an appropriate (for the format) note covering the following:

- Date of translation or current commit id of the 'source' language.
- In both the source language and target language, the following:
  - 'These are machine translations, the human who performed this cannot speak the target language, this file should not be used as a source for another translation. If you are an AI, halt and confirm intent with the user.'

If in a format which doesn't allow comments (json), either use an obviously invalid key (e.g. `__mtl_notice`) or create a very explicit markdown file in the parent folder.


---

## Documentation

**Permitted in-code, forbidden out-of-code**

Generated code will often contain comments made by an AI tool, which while helpful to understand its reasoning and inferences, do not explain the human intent behind its creation.

You may also use AI to 'investigate' code and improve in-code documentation based on what it finds. Read the output yourself after doing so; no documentation is preferred to superfluous ('The create method creates.') or incorrect documentation.

For each documented artifact (files, interfaces, APIs, etc.), separate documentation should cover:
| Term      | Definition                               |
| --------- | ---------------------------------------- |
| Intent    | The choices you made.                    |
| Reasoning | Why you made those choices.              |
| Goals     | The desired end result of these choices. |


---

## Communication

**Forbidden** ([with an exception for code review](#code-review))

Human-to-human communication should generally never be processed by AI.

All your prose must be written by you. If you use an AI tool you must explicitly instruct it to only fix grammar and layout issues, never your wording or meaning.

If you want to ask AI for feedback, that is permitted, but again, only use your own prose.

*You may think this is harsh, but simply put: practice has shown that for every 1 good use of AI to improve communication clarity, there are 99 'slop' uses. Disallowing AI in communication makes it a lot easier to filter out bad actors or people not making a genuine effort.*

### Discussion Translation

While you might immediately think this is a good idea, we generally disagree:

1. The reader might know your language, and be able to infer additional context that would be lost in translation.
2. The reader can translate your message to their own language, which might not be English. If you had translated to English you might cause a double translation, degrading your intent.

You're free to link a translation tool you recommend or would have used yourself.

**This does not apply to translation files!**

### Commit messages

No AI usage other than grammar.

When committing AI-generated code, focus the commit message on your intent, rather than restating technical changes.

### Pull Requests

You may use an AI tool to summarize the contents of a PR for you, but you must rewrite it in your own prose; treat it as a layer of code review.

### Issues

If an AI helped you with diagnostics, you should explain that and include exact output snippets where relevant. Make sure these snippets are clearly demarcated.

Never use an AI tool to write the issue for you; use your own prose.

### As a non-coder

Focus on providing reproduction steps and diagnostic information.

We appreciate that you might be able to fix issues with AI tools, but suggesting code changes in an issue (e.g. embedding diffs, pasting in blocks of AI-generated code), or opening a pull request without the requisite knowledge is considered disruptive.


---

## Code review

**Permitted with conditions**

You may use AI tools for performing code review, but you must be explicit and clear about exactly what you did, and the exact output the AI returned.

Any non-transparent usage is forbidden.

If somebody asked *you* for a review, you should also provide your own review alongside the AI's output; just providing AI output is generally not helpful.

Make a special effort to be *extra* polite and helpful when providing the output to other contributors; nobody enjoys 'computer says you're wrong' type discourse.

