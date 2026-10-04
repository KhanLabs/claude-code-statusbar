---
name: handoff
description: Write a handoff note capturing the current work so the user can /clear and continue cheaply in a fresh context with /pickup.
argument-hint: "[optional focus, e.g. 'the login bug']"
disable-model-invocation: true
---

Write a handoff note so this work can continue in a fresh, cheap context after `/clear`.
Extra focus from the user (may be empty): $ARGUMENTS

## Where to save it

All handoffs live in one folder: `<HANDOFFS>\` (create it if missing). Finished ones go in its `archive\` subfolder.

- If this session was started from a handoff (via `/pickup` or "read <handoff file>"), **overwrite that same file**. Don't create a second one for the same work.
- Otherwise create a new file named `YYYY-MM-DD_HHmm_<topic-slug>.md`. Get the time from `Get-Date -Format 'yyyy-MM-dd_HHmm'`. The slug is 2-4 lowercase words joined by hyphens, naming the work, e.g. `statusline-setup` or `login-bug`.

## Contents

Keep it under 60 lines, plain and specific, with no code dumps. Point to files instead of pasting them. Start with this header, then exactly these sections:

```
# Handoff: <topic in a few words>
Project: <full current working directory>
Updated: <yyyy-MM-dd HH:mm>
Status: open
```

## Goal
One or two sentences: what we're trying to achieve.

## Done
What's finished and confirmed working.

## Files changed
Full absolute paths, one line each on what changed and why. List every file touched, because this machine may have no git to reconstruct changes from.

## Current state
What works, what's broken, and the exact last error message if there is one.

## Next steps
Numbered. Step 1 must be concrete enough to start on immediately.

## Decisions and reasons
Key choices made, including options that were rejected and the reason.

## What did not work
Things that failed or should be avoided, so they aren't repeated.

## Open questions
Anything waiting on the user.

## How to verify
Exact commands or checks that prove the work is correct.

## Reply

When the file is written, reply with only (filling in the slug):
"Saved handoffs\<file name>. Now run /clear, then /pickup <topic-slug>."
