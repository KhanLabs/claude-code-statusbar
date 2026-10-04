---
name: pickup
description: Resume work from a saved handoff note (written by /handoff). Lists open handoffs, loads the chosen one, and archives finished ones. Use when the user says /pickup, "continue from the handoff", or "read the handoff".
argument-hint: "[topic slug or part of a file name; empty = list open handoffs] | done"
---

Handoffs live in `<HANDOFFS>\`, named `YYYY-MM-DD_HHmm_<topic-slug>.md`. Finished ones are in `archive\` there.
User argument (may be empty): $ARGUMENTS

## If the argument is `done`
The handoff loaded earlier in this session is finished. Move it into `archive\` (use `Move-Item -LiteralPath`), then reply with one line naming it. If none was loaded this session, ask which one.

## Otherwise, pick the handoff
List the `.md` files directly in the handoffs folder (not `archive\`), newest first.
- **Argument given:** use the file whose name contains it. If several match, use the newest and say so. If none match, also check `archive\`, then say what you found.
- **No argument, one open handoff:** use it.
- **No argument, several:** show a short numbered list (date, topic, project folder from each file's header) and ask which one. Stop there.
- **None at all:** say there are no open handoffs.

## Load it
Read the whole file. Remember its path: if `/handoff` runs again later this session, it overwrites this file.
If its `Project:` differs from the current working directory, mention that briefly.
Reply with a 2-4 line summary (goal, current state, next step 1), then start on next step 1 unless it waits on the user's answer to an open question.

When all the next steps are done and the user is happy, ask once if it should be archived. On yes, do what `done` does.
