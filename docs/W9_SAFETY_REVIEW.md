# W9 safety review: Ask Mochi controls the PC

2026-11-09. This reviews the Windows port of the Mac's `MacActions.swift` (opening apps and links, bringing windows forward, music keys, volume and the user's own automations) before any code is written. It compares against the Mac's `AssistantController.performTool` and the Windows brain as it is today (`core/ask_brain.dart`, `core/ask_mochi.dart`, `core/brain_session.dart`).

## What exists today

- **On the Mac:** the brain's tools are `open_url` (http/https), `open_app`, `list_apps`, `focus_window`, `show_project`, `media`, `set_volume`, `run_shortcut` and `list_shortcuts`. All of them run at once, with no card. Only `SendMessage` to a Claude session gets a card. Accessibility permission gates window picking and the music keys.
- **On Windows:** the brain has `mochi`, `claude_sessions` and `open_url` (https only, through `rundll32 url.dll,FileProtocolHandler`, with no shell involved). The quick commands for music, volume and apps reply "I can't do that on Windows yet."
- **Already in place on Windows:** `Read` is allowed only for files handed over with the request now running. `SendMessage` always gets a card. The brain has no Bash, Write, Edit or WebFetch.

## Who could misuse these tools

1. **Text the user didn't write.** The brain reads copied text (X15), dropped files, text and links (X13/X14), the screen picture (X17) and web search results. Any of these can carry instructions. The system prompt tells the brain to ignore them, but that is not a guarantee. So **every tool must stay safe even when an attacker chooses its arguments.**
2. **A paired phone.** A phone sends requests over Mochi Link (end-to-end encrypted). Someone holding an unlocked, paired phone gets these tools. This is the same on the Mac.
3. **The brain looping or getting it wrong**, for example by opening 30 tabs.
4. **Privacy.** Window titles and the app list would go to Anthropic if the brain saw them.

## Rules that hold for every PC action (the same as the Mac, or stricter)

| Rule | How |
|---|---|
| Never typing, clicking or keys into another app | The brain gets no tool for typing, clicking or keys. Music uses the Global System Media Transport Controls (`TryTogglePlayPauseAsync`, `TrySkipNextAsync` and `TrySkipPreviousAsync` on the current session; `media.cpp` already holds the manager). Only when no session exists does Mochi send `SendInput` with the three fixed media keys (`VK_MEDIA_PLAY_PAUSE`, `VK_MEDIA_NEXT_TRACK`, `VK_MEDIA_PREV_TRACK`), never anything else. |
| The brain's words never reach a command line, a path or ShellExecute | `open_app`: the name is matched **on the PC** against the Start menu's apps (`shell:AppsFolder`, which covers both Store and desktop apps), and Mochi launches only the entry it found: no arguments, never the `runas` verb, so an app that needs admin rights shows Windows' own UAC prompt. |
| No uninstallers, installers or scripts | Mochi leaves entries out of the list when their name contains uninstall, setup, installer, repair, reset or remove, or when their target ends in .bat, .cmd, .ps1, .vbs, .js, .wsf, .hta, .msi or .reg. |
| Links | `open_url` stays https only, through `rundll32 url.dll` with no shell, as it works today. This is stricter than the Mac, which also allows http. |
| Window titles stay on the PC | `focus_window` and `show_project` match titles on the PC, and the reply never includes a title. They only restore and raise a window: they never close, move or minimise one. `show_project` matches the project's folder name against window titles and doesn't launch editors with paths, unlike the Mac. |
| `list_apps` shows names only | The display names of the programs with taskbar windows, never their titles. |
| Volume stays in range | Mochi sets the default output's level through Core Audio (`IAudioEndpointVolume`), always between 0 and 100. |
| Automations: only the ones the user picked | `run_task` runs a Task Scheduler task **only from a `\Mochi\` folder the user creates themselves**. That folder is the allow-list, like the Mac's Shortcuts being the user's own. Mochi never runs a task from another folder or by path, and never creates or changes tasks. `list_tasks` lists only that folder. Power Automate isn't part of W9. |
| At most 5 actions per request | A sixth PC action in the same request is refused ("That's a lot at once, ask me again"). Mochi's own tricks and the lists don't count toward the 5. |
| Logs | Logs keep only the tool's name and whether it worked, never app names, titles, links or task names. |
| One switch | Settings › Assistant › "Let Mochi use my PC" (open apps and links, bring windows forward, music and volume), on by default like the Mac. When it's off, the brain doesn't get these tools and the quick commands say it's off. |
| Quick commands need no card | "open Slack", "pause" or "volume 30" are the user's own words, parsed on the PC with no brain involved, so they run at once, as on the Mac. |
| Phones | A phone gets the same tools, as on the Mac. |

## Decision: no cards, like the Mac

The user decided on 2026-11-09: **PC actions run at once, with no card, exactly as on the Mac.** The Sprint 2 plan's "a card before every action" is dropped. Every rule above still applies (the allow-list, no typing into other apps, at most 5 actions per request, the `\Mochi\` task folder, titles staying on the PC). Messages to Claude sessions (`SendMessage`) keep their card, and `Read` keeps its gate.

Other options the user was offered:
- Cards only where the risk is: running a task, raising the volume above 80%, and opening an app or a link when the request carries text the user didn't write.
- A card before every action.
