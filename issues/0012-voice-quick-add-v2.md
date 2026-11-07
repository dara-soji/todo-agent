---
id: 12
title: "Spec: voice quick-add (v2)"
labels: [ready-for-agent]
status: open
assignee:
blocked_by: []
---

Follows v1 (issue 11), which listed voice as out of scope. Capitalised terms (Task, Project, Now, Operation, Guardrail, Added panel …) carry their `CONTEXT.md` meaning.

## Problem Statement

Adding a Task means pressing ⌥Space and typing. Dara wants to capture a thought without switching to typing: press a key, say it, and have it land as a Task.

## Solution

Hold ⌥Space to talk. A quick tap still opens the typing box as today.

1. **Trigger.** Pressing ⌥Space starts buffering audio straight away. If the key is released within 300 ms, it is a tap: the buffer is discarded and the typing box opens. If it is held longer, recording continues (push-to-talk) and the first word is kept. Recording ends on key release.
2. **While talking.** A start sound plays. The existing quick-add box switches to a "Listening…" state with the live transcript under the destination Project heading.
3. **Speech-to-text.** Apple's on-device speech recognition runs in the system locale. Nothing is sent to a cloud speech service, and audio is never stored.
4. **After release.** Haiku (`claude-haiku-5-5`, the existing ClaudeClient and audit log) splits the transcript into one or more Task titles, removing filler ("um", "I need to"). It does **not** extract deadlines or effort. Tasks go to Now's confident Project, unless a Project is named out loud ("for the Acme deck, …"), in which case Haiku matches it against existing Projects. With no API key, offline, or on any Haiku failure, the result is a single Task with the verbatim transcript.
5. **Confirmation.** The Tasks are added immediately as **one** Operation through the normal Guardrail path. The existing Added panel lists every added Task, with one Undo that removes the whole batch and a Start button. There is no voice "start" command.
6. **Edge cases.**
   - If microphone or speech-recognition permission is denied, or on-device recognition is unavailable for the locale, holding ⌥Space opens the typing box with a one-line "Voice needs … → Open Settings" message.
   - If no speech is detected, nothing happens.
   - Recording stops automatically at 60 s.
   - The transcript is recorded in the Operation log.
7. **Bundle.** Add NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription to the generated Info.plist.

## Testing Decisions

Build test-first. Tap-vs-hold classification and Haiku split/fallback are pure logic and get unit tests with a fake clock and a fake model client. Batch add and batch Undo are tested in AssistantCore as one Operation.

## Out of Scope

- Wake word
- Cloud speech-to-text
- Extracting deadlines or effort from speech
- Starting a Task by voice
- A mic button inside the app

## Tickets

Published as GitHub issues labelled `ready-for-agent`:

1. #40 Hold ⌥Space to add one Task by voice
2. #41 Haiku splits one recording into several Tasks, with one Undo for the batch (blocked by #40)
3. #43 Name a Project out loud to send Tasks there (blocked by #41)
4. #42 Voice failure cases (blocked by #40)
