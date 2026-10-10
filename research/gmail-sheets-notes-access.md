# How can the assistant read Gmail, Google Sheets and notes?

Research for ticket [0003](../issues/wayfinder-v1-spec/0003-gmail-sheets-notes-access.md). Researched 2026-10-10 against Google, Apple and Anthropic primary docs. The Apple Notes scripting facts come from the dictionary on this Mac (macOS 15.7.9, `/System/Applications/Notes.app/Contents/Resources/Notes.sdef`).

> **Open question: which notes app?** Nobody has confirmed whether Dara uses Apple Notes, Google Keep or Google Docs. All three are covered below. The answer changes the notes recommendation a lot, so ask before the spec is finalised.

## TL;DR

| Service | Best path for v1 | Unattended? | Setup effort |
|---|---|---|---|
| Gmail | Our own Google OAuth client (desktop, loopback + PKCE), `gmail.readonly`, polling `history.list` | Yes, once the app is "In Production" (see the 7-day trap) | Medium: one Cloud project, consent screen, one browser sign-in |
| Google Sheets | Same OAuth client, `spreadsheets.readonly` now and `spreadsheets` later | Yes | Small, since it shares the Gmail setup |
| Apple Notes | AppleScript/JXA through Apple Events (`plaintext`, `body`, `modification date`) | Yes, while Dara is logged in, after a one-time Automation prompt | Small |
| Google Docs (as notes) | Same OAuth client, `documents.readonly` / Drive scopes | Yes | Small |
| Google Keep | **No viable path for a personal account.** The Keep API is for Workspace admins | n/a | n/a |

Claude connectors and Google's remote Workspace MCP servers are good for interactive use. Neither fits an always-on background scanner (details below).

---

## 1. Shared foundation: Google OAuth for a personal desktop app

These facts apply to Gmail, Sheets, Docs and Keep together.

- **Flow.** Installed or desktop apps use the authorization-code flow with **PKCE (S256)** in the system browser, with a **loopback redirect** (`http://127.0.0.1:<random port>`). Custom URI schemes are "no longer supported due to the risk of app impersonation", and the manual copy-paste (OOB) flow is deprecated. [OAuth for native apps](https://developers.google.com/identity/protocols/oauth2/native-app)
- **Background use.** Installed apps always get a refresh token. With offline access, the app can mint new access tokens "even when the user isn't present". Store the refresh token securely (on a Mac, the Keychain). Incremental authorization isn't supported for installed apps, so request every scope up front and check which ones were actually granted. [same page](https://developers.google.com/identity/protocols/oauth2/native-app)
- **The 7-day trap.** If an External-audience project stays in **"Testing"** status, its refresh tokens **expire after 7 days** (basic identity scopes excepted). An unattended assistant would quietly lose access every week. Fix: move the consent screen to **"In Production"**. [OAuth 2.0 overview](https://developers.google.com/identity/protocols/oauth2)
- **Verification.** Gmail read scopes are *restricted* and Sheets/Docs scopes are *sensitive*. Normally both need Google verification, and restricted scopes also need a security assessment if data is stored or sent through servers ([Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)). However, **personal use** (fewer than 100 users, "for you and a limited group") is exempt from verification. Dara clicks through an "unverified app" warning once. [When verification is not needed](https://support.google.com/cloud/answer/13464323)
- **Net setup effort:** create one Google Cloud project, enable the Gmail, Sheets and Docs APIs, configure the consent screen (External, In Production, unverified), create a *Desktop* OAuth client, then do one browser sign-in. That's about 20–30 minutes once. It's a good fit for the `wizard` skill.

## 2. Gmail

### Option A: Gmail API with our own OAuth client (recommended)

- **Scopes** ([source](https://developers.google.com/workspace/gmail/api/auth/scopes)):
  - Read: `gmail.readonly` (restricted). `gmail.metadata` (restricted) gives headers and labels only, with no body, so it's too thin for "spot important info".
  - Later, labelling or archiving: `gmail.modify` (restricted).
  - Later, drafting: `gmail.compose` (restricted).
  - Sending: `gmail.send` (sensitive).
  - Avoid `https://mail.google.com/`. It allows permanent deletion, which the Guardrail tiers forbid without asking.
- **Quotas** ([source](https://developers.google.com/workspace/gmail/api/reference/quota)): 6,000 units per user per minute. Costs: `messages.list` 5, `messages.get` 20, `history.list` 2, `watch` 100. Polling every few minutes uses a tiny share of this.
- **Change detection, two ways:**
  - **Polling (recommended).** Save a `historyId` and call `history.list` from it. If the id is too old you get an HTTP 404, which means doing a full re-sync. History is "typically" kept for at least a week. [Sync guide](https://developers.google.com/workspace/gmail/api/guides/sync)
  - **Push.** This needs a Cloud Pub/Sub topic, and `watch` must be renewed at least every 7 days (daily is recommended). Notifications can be delayed or dropped. Google itself recommends **polling for installed apps**. [Push guide](https://developers.google.com/workspace/gmail/api/guides/push)
- **Unattended:** yes. A login item or launch agent polls with the stored refresh token.

### Option B: Google's remote Gmail MCP server

- Endpoint `gmailmcp.googleapis.com/mcp/v1`. Its tools read (`search_threads`, `get_thread`, `get_message`, …) and write drafts and labels (`create_draft`, `label_thread`, …). It has **no send tool**. [Configure Workspace MCP servers](https://developers.google.com/workspace/guides/configure-mcp-servers)
- Drawbacks:
  - It's in **Developer Preview**: you must join the Workspace Developer Preview Program.
  - It needs a Cloud project and a *Web* OAuth client.
  - The page doesn't say whether consumer gmail.com accounts are supported.
- Unattended: only through an MCP client that runs headless, such as `claude -p --mcp-config ...` ([headless docs](https://code.claude.com/docs/en/headless)). Every scan becomes an LLM agent run. That costs more and is less predictable than a plain API poll.

### Option C: Claude's Gmail connector (claude.ai / Claude Desktop)

- It can search and read mail, draft, send, reply and forward, and manage labels. Sending asks for approval by default. It's available on all plans. [Google Workspace connectors](https://support.claude.com/en/articles/10166901-use-google-workspace-connectors)
- **It only works inside a chat** ("Ask Claude a question that requires access to your Gmail…"). It has no background or scheduled mode, so it can't feed an always-on Task importer. Setup is minimal (one click to connect). Good for "help me reply to this" during the day, not for scanning.

### Option D: Community MCP servers (e.g. Gmail / Workspace MCP on GitHub)

- These wrap the same Gmail API, so you still need your own OAuth client and the same 7-day and verification rules apply.
- They're unaudited third-party code holding a restricted-scope token. They add little over Option A.

## 3. Google Sheets

### Option A: Sheets API with the same OAuth client (recommended)

- **Scopes** ([source](https://developers.google.com/workspace/sheets/api/scopes)):
  - `spreadsheets.readonly` and `spreadsheets` are both *sensitive*.
  - `drive.file` is non-sensitive and recommended, but it only covers files the app created or that the user opened with it (e.g. through a picker).
  - `drive` and `drive.readonly` are *restricted*.
  - Scopes apply to whole files and can't be limited to one tab.
- **Quotas** ([source](https://developers.google.com/workspace/sheets/api/limits)): 60 reads and 60 writes per user per minute, with no daily cap. A batch request counts as one request. Exceeding the quota returns a 429, so back off and retry. Requests longer than 180 s time out.
- **Finding sheets:** listing which spreadsheets exist needs the Drive API. `drive.readonly` is restricted, but it's still covered by the personal-use exemption. Alternatively, Dara could register specific sheet URLs with the assistant, and then the Sheets scope alone is enough.
- **Unattended:** yes.

### Option B: Google's remote Sheets MCP server

- `sheetsmcp.googleapis.com/mcp/v1`. Its tools are `get_spreadsheet` and `get_values`, plus the writes `update_values`, `update_formulas`, `update_spreadsheet` and `insert_dimension`. It uses the same quotas as the API. Same Developer Preview caveats as for Gmail. [source](https://developers.google.com/workspace/guides/configure-mcp-servers)

### Option C: Claude's Drive connector

- It reads Sheets. Live editing of Sheets beside the chat and creating new Sheets are **in beta**, on web Chrome or on Claude Desktop with the built-in browser on. It's interactive only. [source](https://support.claude.com/en/articles/10166901-use-google-workspace-connectors)
- Useful for the later "Acting layer" ("organise this sheet with me"), but not as a background Source.

## 4. Notes (unconfirmed which app)

### 4a. Apple Notes: AppleScript / JXA via Apple Events (recommended if Apple Notes)

- **What the dictionary exposes** (from `Notes.sdef` on this Mac):
  - Objects: `account` → `folder` → `note` → `attachment`.
  - `note` properties: `name`, `id`, `container`, `body` (HTML, **read/write**), `plaintext` (**read-only**), `creation date`, `modification date`, `password protected`, `shared`.
  - Commands: `show` and `open note location`.
  - Writing means `make new note` or setting `body` to HTML.
- **Permission:** the app must declare `NSAppleEventsUsageDescription`. Apple warns that automating an app can indirectly expose data the app keeps private. The user approves once under System Settings → Privacy & Security → Automation. [Apple docs](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)
- **Limits:**
  - Password-protected notes can't be read; detect them through `password protected`.
  - Bodies are HTML.
  - Scanning many notes is slow, so poll by `modification date` and cache by `id`.
  - Notes.app is launched if it isn't already running.
  - There's no change notification, so you have to poll.
- **Unattended:** yes, while Dara's user session is logged in. It can run from a login item or launch agent ([SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)). It won't work at the login window.
- **Reads iCloud and "On My Mac" notes alike**, because it goes through the app.

### 4b. Apple Notes: reading the local database directly (not recommended)

- The Notes store is an SQLite database inside `~/Library/Group Containers/group.com.apple.notes/`. Note bodies are stored compressed and protobuf-encoded.
- **None of this is documented by Apple.** The format changes between macOS versions, and reading it needs Full Disk Access, a much broader grant than Automation.
- It's read-only in practice: writing to it risks corrupting iCloud sync. The only advantage is speed for very large libraries. (I didn't verify the path's contents here because this research had no file-access grant for it.)

### 4c. Apple Notes: community MCP servers

- Several exist (e.g. "apple-notes-mcp" listings). They wrap the same AppleScript calls, so the same permission and limits apply.
- Fine for interactive Claude Desktop use. For the background importer, calling AppleScript directly is simpler and needs no extra code to audit.

### 4d. Google Keep: no practical access for a personal account

- The Keep API is described as letting "enterprise administrators manage Google Keep notes". Its auth is domain-wide delegation, either through a service account or an OAuth client that an admin approves. [Keep API guide](https://developers.google.com/workspace/keep/api/guides)
- It has scopes `keep` and `keep.readonly`, and methods `notes.list/get/create/delete` plus permissions. There is **no update method**. [Discovery doc](https://keep.googleapis.com/$discovery/rest?version=v1)
- A gmail.com account has no Admin console, so it can't grant this. Google has no Keep MCP server ([source](https://developers.google.com/workspace/guides/configure-mcp-servers)), and Claude has no Keep connector.
- If Dara uses Keep, the realistic choices are:
  - Move the notes that matter to Apple Notes or Google Docs.
  - Treat Keep as out of scope for v1.
  - Use UI automation through screenshots, which is fragile and belongs in the Acting layer.

### 4e. Google Docs as notes

- The Docs API uses the same OAuth client. Scopes: `documents.readonly` and `documents` (sensitive), `drive.file` (non-sensitive, recommended), `drive` and `drive.readonly` (restricted). [Docs scopes](https://developers.google.com/workspace/docs/api/auth)
- Find changed docs through Drive (`files.list` by `modifiedTime`, which needs Drive read).
- Remote Docs MCP: `docsmcp.googleapis.com` with `read_doc` and `update_doc` (Developer Preview).
- Unattended: yes.

## 5. Comparison: can it run in the background?

| Path | Unattended background | Read | Write | Notes |
|---|---|---|---|---|
| Own Google OAuth + APIs | **Yes** | Yes | Yes (scope-dependent) | Must be "In Production" to avoid 7-day expiry; personal-use exempt from verification |
| Google remote Workspace MCP | Only through a headless agent run | Yes | Drafts and labels, Sheets/Docs edits; **no Gmail send** | Developer Preview; consumer-account support unstated |
| Claude connectors (Gmail, Drive) | **No**, chat-bound | Yes | Gmail send with approval; Sheets edit in beta | Zero setup; great for the interactive Acting layer |
| Community MCP servers | Through a headless agent run | Yes | Varies | Unaudited code holding sensitive tokens |
| Apple Notes via AppleScript | **Yes** while logged in | Yes | Yes (`body`, `make new note`) | One Automation prompt; locked notes unreadable |
| Apple Notes SQLite | Yes | Yes | No (unsafe) | Undocumented; needs Full Disk Access |
| Google Keep API | No (consumer) | Admin only | Admin only | Workspace-admin feature only |

## 6. Recommendation

1. **Build one Google integration of our own.** Use a Desktop OAuth client with loopback + PKCE. Put the project In Production but unverified (personal-use exemption) and keep the refresh token in the Keychain.
2. **Gmail in v1:** request `gmail.readonly` only and poll `history.list` every few minutes. Skip Pub/Sub. Add `gmail.compose` or `gmail.modify` only when the Acting layer is specified, and keep send behind the "always ask" Guardrail.
3. **Sheets in v1:** request `spreadsheets.readonly`. Dara registers the sheets that matter, so Drive-wide scopes aren't needed. Upgrade to `spreadsheets` for the Acting layer.
4. **Notes:**
   - If Dara uses **Apple Notes**: read with AppleScript/JXA and poll by modification date.
   - If Dara uses **Google Docs**: add `documents.readonly` to the same client.
   - If Dara uses **Google Keep**: say plainly that there's no API path, and propose moving the notes or leaving Keep out of v1.
   - **Confirm which app before writing the spec.**
5. **Use Claude connectors and MCP servers for the interactive side**, not as the background Source importer. That covers "help me reply" and "tidy this sheet" in Claude Desktop. Revisit Google's remote MCP servers when they leave Developer Preview.
