# auto-handoff (optional add-on)

When a chat gets long, this add-on does the `/handoff`, `/clear`, `/pickup` routine for you, without breaking into your work.

## What it does

It checks the size of the chat every 15 seconds.

1. **Below the limit** (300,000 tokens by default): nothing happens. The status line shows `ctx 120k/300k`.
2. **Over the limit while Claude is working:** it adds one short note asking Claude to pause at the next natural stopping point. Claude finishes the step it is on, saves its progress and ends its turn. Nothing is stopped or cut off. If the chat grows another 40,000 tokens, it sends one shorter reminder.
3. **Over the limit and Claude has stopped:** it waits 8 seconds, checks that your prompt box is empty, then runs `/handoff`, `/clear` and `/pickup` on the note that was just written.

It never interrupts a running turn, and it never acts while you are typing.

## Status

New (version 0.2.0). The size check and the status line have been run for real. The full routine (pause note, handoff, clear, pickup) was written in one sitting and is being tried for the first time, so expect to adjust it.

## What you need

- Claude Code 2.1.292 or newer. The add-on API it uses is early access and may change.
- The `/handoff` and `/pickup` skills from this repo (`skills/`), installed as in the main README.

## Install

1. Copy the `mods/auto-handoff` folder somewhere permanent, for example `C:\Users\<you>\claude-mods\auto-handoff`.
2. Start Claude Code with the folder named:

   ```
   claude --plugin-dir "C:\Users\<you>\claude-mods\auto-handoff"
   ```

   To load it every time, set the `CLAUDE_CODE_PLUGIN_DIRS` environment variable to that folder.
3. Send a message. After a few seconds the status line shows `ctx 5k/300k`. If it does not, the add-on did not load: run `claude plugin validate "C:\Users\<you>\claude-mods\auto-handoff"` and read the message.

## Settings

Set these under `pluginConfigs` in `settings.json`, or in the `/config` menu.

| Option | Default | Meaning |
|---|---|---|
| `thresholdTokens` | `300000` | The chat size at which the routine starts. |
| `handoffsDir` | empty | The folder `/handoff` writes to. Empty means the `handoffs` folder inside your Claude config folder (`CLAUDE_CONFIG_DIR`, or `~/.claude`). |

## Good to know

- **Auto-compact:** if you also set `autoCompactWindow` to 300000 (as `examples/settings.json` does), Claude Code may shrink the chat at about the same size and the add-on may not get its turn. Set `thresholdTokens` to about 250000 if you keep both.
- **`/clear` from an add-on:** the add-on asks Claude Code to run `/clear` for it. If your version refuses, you see a message; run `/clear` yourself and `/pickup` still follows by itself.
- **The status file:** the add-on writes `auto-handoff-status.json` (tokens, limit, phase) into your Claude config folder, so other tools can read it. Nothing else is written, and nothing leaves your computer.
- **Several handoffs open:** `/pickup` is given the name of the note that was just written, so it never stops to ask which one.
- **Undo:** remove the folder from `--plugin-dir` or `CLAUDE_CODE_PLUGIN_DIRS`.
