# Which macOS activity signals can we read?

Research for ticket [0002](../issues/wayfinder-v1-spec/0002-macos-activity-signals.md). Date: 2026-10-10.
Checked on the user's Mac: macOS 15.7 (Sequoia), Apple Silicon, Command Line Tools SDK.

Source key:
- **[SDK]**: headers in `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` (Apple's own API declarations, including availability and deprecation macros).
- **[sdef]**: the app's bundled AppleScript dictionary (`Contents/Resources/*.sdef`).
- **[measured]**: timed on this Mac.
- **[inferred]**: engineering judgement, not stated by a primary source. Check these in the prototype.

Apple's developer-doc pages render client-side and could not be fetched as text, so the SDK headers stand in for them.

## Summary table

| Signal | Mechanism | Permission | Latency | Cost |
|---|---|---|---|---|
| Active app | `NSWorkspace.didActivateApplicationNotification` | none | event-driven, instant | ~0 |
| Window title | Accessibility API (`AXFocusedWindow` → `AXTitle`) | Accessibility | <5 ms per query [inferred] | ~0 if read on app/title change |
| Window title (alt) | `CGWindowListCopyWindowInfo` → `kCGWindowName` | Screen Recording | ms | low; polling only |
| Chrome/Safari tab URL + title | AppleScript / Apple Events | Automation (per target app) | ~10–100 ms per call [inferred] | low at ≤1 call per switch |
| Chrome tab URL (alt) | Extension + Native Messaging | none from macOS; install an extension | event-driven | ~0 |
| VS Code project/file/branch | Window title (VS Code `window.title` setting) | Accessibility | as window title | ~0 |
| Rider project/file | Window title, plus `AXDocument` where exposed | Accessibility | as window title | ~0 |
| Git branch + recent commits | Read `.git/HEAD`, `.git/logs/HEAD`, or `git log` | none (file access) | ms | ~0 with FSEvents |
| Calendar events | EventKit `EKEventStore` | Calendars (full access) | ms, local store | ~0 with change notification |
| Idle time | `CGEventSourceSecondsSinceLastEventType` | none | µs | ~0 |
| Screenshot to Claude | ScreenCaptureKit `SCScreenshotManager` + Messages API | Screen Recording | capture: ms; API: seconds | ~$0.002–0.015 per shot |

## 1. Active app

- **Mechanism**: subscribe to `NSWorkspace.didActivateApplicationNotification` on `NSWorkspace.shared.notificationCenter`, not on the default center. The `userInfo[NSWorkspace.applicationUserInfoKey]` value is an `NSRunningApplication`, which gives `bundleIdentifier`, `localizedName` and `processIdentifier`. `NSWorkspace.shared.frontmostApplication` gives a one-off read. [SDK: AppKit `NSWorkspace.h`]
- **Permission**: none.
- **Latency**: push-based. It fires when the app switches.
- **Cost**: effectively zero, since no polling is needed.
- **Gotchas**: the notification reports app changes only, not window or tab changes inside an app. Those need the window-title signal below. The CLI `lsappinfo front` returns in about 10 ms [measured] and suits shell prototypes.

## 2. Active window title

### 2a. Accessibility API (recommended)

- **Mechanism**: `AXUIElementCreateApplication(pid)`, then `kAXFocusedWindowAttribute` (`"AXFocusedWindow"`), then `kAXTitleAttribute` (`"AXTitle"`). Some apps also expose `kAXDocumentAttribute` (`"AXDocument"`, a file URL) and `kAXURLAttribute`. To get changes pushed instead of polling, register an `AXObserver` for `kAXFocusedWindowChangedNotification` and `kAXTitleChangedNotification` on the frontmost app's pid, and re-attach whenever the active app changes. [SDK: HIServices `AXUIElement.h`, `AXAttributeConstants.h`, `AXNotificationConstants.h`]
- **Permission**: Accessibility. Check it with `AXIsProcessTrustedWithOptions`, and pass `kAXTrustedCheckOptionPrompt` to open the System Settings prompt. `AXIsProcessTrusted` has been deprecated since 10.9. [SDK]
- **Latency**: a synchronous cross-process call, usually a few ms. A hung target app can block the call until the AX messaging timeout, so set `AXUIElementSetMessagingTimeout` low (for example 0.25 s) and call it off the main thread. [SDK; timing inferred]
- **Cost**: negligible when driven by notifications.
- **Gotchas**:
  - Accessibility permission is broad: it also allows *controlling* the UI. This matters for the guardrail story later.
  - The grant is tied to the app's code signature. Rebuilding an unsigned or ad-hoc-signed dev build can silently invalidate the grant [inferred], so sign builds consistently.
  - Some Electron and Java apps expose titles inconsistently. Rider (Java/JetBrains Runtime) needs testing.

### 2b. CGWindowList (fallback)

- **Mechanism**: `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` returns one dictionary per window with `kCGWindowOwnerName`, `kCGWindowOwnerPID`, `kCGWindowLayer` and, "if present", `kCGWindowName`. [SDK: `CGWindow.h`]
- **Permission**: since macOS 10.15, `kCGWindowName` for other apps' windows is filled in only when the caller has Screen Recording permission (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`, both added in 10.15). [SDK for the preflight API; the name-redaction behaviour is widely documented, but the header text only says "if present"]
- **Gotchas**: it can only be polled (there's no notification), and Screen Recording is a heavier ask than Accessibility. Use it only if AX fails for an app.

## 3. Browser tab URL and title

### 3a. Apple Events / AppleScript (recommended for v1)

- **Chrome**: the `window` class has `active tab` ("Returns the currently selected tab"), and `tab` has `URL` ("The url visible to the user") and `title`. [sdef: `Google Chrome.app/Contents/Resources/scripting.sdef`]
  `tell application "Google Chrome" to get {URL, title} of active tab of front window`
- **Safari**: `window` has `current tab`, and `tab` has `URL` and `name`. [sdef: `Safari.app/Contents/Resources/Safari.sdef`]
  `tell application "Safari" to get {URL, name} of current tab of front window`
- **Permission**: Automation (TCC "Apple Events"), granted separately for each target app. The app needs an `NSAppleEventsUsageDescription` Info.plist string and, when sandboxed or hardened, the `com.apple.security.automation.apple-events` entitlement. Check without prompting with `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded:false)` (macOS 10.14+). [SDK: `AppleEvents.h`]
- **Latency**: an in-process `NSAppleScript` or `NSAppleEventDescriptor` call is typically tens of ms. Spawning `osascript` adds about 50–100 ms. [inferred] Trigger it on app activation or title change, not on a timer.
- **Cost**: low at event-driven rates.
- **Gotchas**:
  - Reading the URL and title does **not** need Chrome's "Allow JavaScript from Apple Events". That setting only gates `execute javascript`, which Chromium turned off by default. [chromium.org/developers/applescript]
  - A query that targets an app which isn't running will *launch* it. Guard every query with an `NSRunningApplication` check first.
  - Chromium-based browsers (Arc, Edge, Brave) each have their own dictionary and need their own Automation grant.
  - Private or incognito windows still answer, so the exclude list has to filter on URL and app.
  - For Google Sheets, the tab title carries the sheet name ("Budget - Google Sheets"), and the URL carries the spreadsheet ID. This is a strong Now signal.

### 3b. Chrome extension + Native Messaging (alternative)

- **Mechanism**: an extension listens to `tabs.onActivated` and `tabs.onUpdated` and sends each change to a host binary over stdio. Messages are length-prefixed JSON, at most 1 MB from the host to Chrome and 64 MiB from Chrome to the host. The host manifest lives in `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`, and `allowed_origins` must list exact extension IDs with no wildcards. [developer.chrome.com/docs/extensions/develop/concepts/native-messaging]
- **Pros**: changes are pushed, it needs no Automation prompt, and it can see richer context (for example the Sheets cell selection, via a content script).
- **Cons**: an extension has to be built and installed, and it works in Chrome only. Defer it unless 3a proves flaky.

## 4. VS Code / Rider: open project and file

- **VS Code**: the macOS window title defaults to `${activeEditorShort}${separator}${rootName}${separator}${profileName}`, with the separator `" — "`, which gives the file name and the workspace folder. VS Code also supports `${activeRepositoryBranchName}`, `${activeEditorLong}` (full path) and others. [VS Code source: `src/vs/workbench/browser/parts/titlebar/windowTitle.ts`, `workbench.contribution.ts`]
  **Recommendation**: set the user setting `"window.title": "${activeEditorLong}${separator}${rootName}${separator}${activeRepositoryBranchName}"`, which makes the window title carry the full path, project and branch. It is then read through the AX title signal, so it needs no extension.
- **Rider**: JetBrains windows title themselves as "project – file". Test whether `AXDocument` is exposed. A Rider plugin or the IDE's recent-projects file (`~/Library/Application Support/JetBrains/Rider<ver>/options/recentProjects.xml`) can fill gaps. [inferred; Rider is not installed on this Mac, so this is unverified]
- **Permission**: Accessibility (shared with signal 2a).
- **Gotchas**: a title-only approach misses unsaved scratch buffers and terminals inside the IDE. That's good enough for Now.

## 5. Git branch and recent commits

- **Mechanism**: once the repo root is known (from the IDE title or file path), read `.git/HEAD` for the branch (`ref: refs/heads/<name>`). For history, read the reflog at `.git/logs/HEAD`, which records branch tip moves *and* branch switches with timestamps, or run `git log -n 5 --format=...`. [git-scm.com/docs/git-reflog]
- **Change detection**: FSEvents (`FSEventStreamCreate`) on `.git/HEAD` and `.git/logs/` pushes updates for checkout and commit.
- **Permission**: none for repos outside TCC-protected folders. Repos under `~/Documents`, `~/Desktop` or `~/Downloads` trigger a one-time "Files and Folders" consent [inferred from TCC behaviour]. Note that this project lives in `~/Documents`.
- **Latency/cost**: a file read takes µs and `git log` a few ms. Zero cost when idle.
- **Gotchas**: worktrees use a `.git` *file* that points at the real gitdir, so resolve it. Spawn `git` only on change, never on a timer.

## 6. Calendar events

- **Mechanism**: EventKit. Call `EKEventStore.requestFullAccessToEvents` (macOS 14+; the old `requestAccessToEntityType:` is deprecated as of 14.0). Then call `predicateForEvents(withStart:end:calendars:)` and `events(matching:)` for "now ± 2 h". Subscribe to `EKEventStoreChangedNotification` for updates, which also fires when access changes. [SDK: `EKEventStore.h`]
- **Permission**: Calendars full access, with the Info.plist key `NSCalendarsFullAccessUsageDescription`. Write-only access would not let the app read events.
- **Latency/cost**: it queries a local store, so ms with no network. Google Calendar events show up only if the Google account is added in macOS Internet Accounts. Otherwise use the Google Calendar API (ticket 0003 territory).
- **Gotchas**: recurring events are expanded by the predicate, which is good. Keep the query window small for speed.

## 7. Idle time

- **Mechanism**: `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, kCGAnyInputEventType)` gives the seconds since the last keyboard or mouse input (macOS 10.4+). [SDK: `CGEventSource.h`] The same value is exposed as `HIDIdleTime` (in ns) on `IOHIDSystem` in IORegistry, which is readable from shell via `ioreg -c IOHIDSystem` (verified on this Mac [measured]).
- **Permission**: none for reading the idle duration. (Reading the event *contents* through an event tap would need Input Monitoring. This app doesn't need that.)
- **Latency/cost**: µs. Poll every 30–60 s, or check on demand.
- **Gotchas**: pair it with `NSWorkspace.screensDidSleepNotification`, `willSleepNotification` and the screen-lock distributed notification so that away time is handled cleanly. Reading or watching a video produces long idle stretches that aren't absence, so use idle together with the active app.

## 8. Occasional screenshot to the Claude API

- **Capture**: use ScreenCaptureKit `SCScreenshotManager` (`captureImage(contentFilter:configuration:)`). `CGWindowListCreateImage` is marked `SCREEN_CAPTURE_OBSOLETE(10.5, 14.0, 15.0)`, meaning it is obsoleted on macOS 15. [SDK: `CGWindow.h`, `ScreenCaptureKit/SCScreenshotManager.h`] Capture only the frontmost window, through an `SCContentFilter` on that window, to reduce privacy exposure and tokens.
- **Permission**: Screen Recording. On Sequoia, macOS re-prompts the user periodically to confirm continued screen-recording access for non-Apple apps [inferred; widely reported, not verified from Apple docs]. Expect this friction.
- **Token cost** (Anthropic vision docs): tokens are about `ceil(w/28) × ceil(h/28)`, with a cap at the model's limit. A 1920×1080 capture costs about **1,560 tokens** on standard-tier models (downsized to 1456×819) and about **2,691 tokens** on high-res-tier models (Claude 4.7+). A 1000×1000 image costs about 1,296 tokens. [platform.claude.com/docs/en/build-with-claude/vision]
- **Dollar cost**: the docs give about $1.30 per 1,000 1-MP images on Haiku 4.5 ($1/M input) and about $6.48 per 1,000 on Opus 5 ($5/M input). A downscaled single window (about 1 MP) plus a short prompt and a ~100-token summary out costs roughly **$0.0015–0.002 per shot on Haiku** and **~$0.008–0.015 on Opus**. At "only when unsure", say 20 shots a day, that is about **$0.04/day on Haiku**. [doc figures; output-token share inferred from published pricing]
- **Latency**: capture takes tens of ms [inferred]. An API round-trip with one image and a short answer is typically 1–4 s on a small model [inferred, not documented]. This is fine for an async refinement, but not for the instant Now display.
- **Gotchas**:
  - Downscale to ≤1568 px on the long edge before sending. Larger images are only resized server-side and still cost upload bandwidth.
  - Apply the exclude list *before* capture, using the frontmost bundle ID and URL.
  - Never write the image to disk, which matches the map's privacy rule. Images sent to the API are not used for training, according to the same doc.

## Permission budget

| Permission | Unlocks | Ask when |
|---|---|---|
| none | active app, idle, git (outside protected folders) | always |
| Accessibility | window titles, so IDE file/project/branch and Sheets/Gmail tab titles | onboarding: this is the core signal |
| Calendars (full) | events now and next | onboarding |
| Automation → Chrome, Safari | tab URL | first time each browser is frontmost |
| Screen Recording | screenshots (and CGWindow titles) | only when the user enables "look when unsure" |

## Recommendation: minimal always-on signal set

1. **Active app**, from the NSWorkspace activation notification. Free, with no permission.
2. **Focused window title**, through an AX observer on the frontmost app. One Accessibility grant covers VS Code (set `window.title` to include the path and branch), Rider, Sheets and Gmail tab titles, and Notes.
3. **Calendar now/next**, from EventKit with a change notification.
4. **Idle time**, from `CGEventSourceSecondsSinceLastEventType` polled each minute, plus sleep and lock notifications.

Read on demand (event-triggered, not always-on): **browser URL** via Apple Events when a browser becomes frontmost, and **git branch/reflog** via FSEvents once a repo is known. Keep the **screenshot** as the rare "unsure" fallback with a window-only capture, a small model and no disk writes. This confirms the map's charting decision, with one refinement: Screen Recording is *not* needed for window titles if the app uses Accessibility.

Open items to verify in a prototype: AX title exposure in Rider; Sequoia's Screen Recording re-prompt cadence; real API latency for one image on Haiku.
