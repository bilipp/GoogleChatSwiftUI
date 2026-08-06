# GoogleChatSwiftUI — Implementation Plan

A native macOS Google Chat client built with SwiftUI and the official Google Workspace REST APIs.

**Decisions locked in:**

| Decision | Choice |
|---|---|
| Platform | macOS only, 26.5+ (no iOS/iPadOS/visionOS) |
| Scope | Full client — read *and* write |
| Realtime | Workspace Events API → Cloud Pub/Sub → in-app pull |
| OAuth consent | **Internal** (your-domain.com org, super-admin available) |
| Distribution | Local only, run from Xcode |

---

## 1. What the Google Chat API can and cannot do

This shapes everything below. Verified against current docs (August 2026).

### Supported with user OAuth

- **Spaces** — list/get/create/update/delete, plus user-defined *sections* for sidebar organisation
- **Messages** — list (paginated, threaded), get, create, update (edit), delete
- **Reactions** — create, list, delete; custom emoji supported
- **Memberships** — list, get, create (invite), update, delete
- **Attachments** — upload (`media.upload`) and download (`media.download`)
- **Read state** — get/update per-space and per-thread read state for the calling user
- **Pins** — list and manage pinned messages

### Hard limitations — design around these

1. **No websocket, no streaming endpoint.** The only push mechanism is the Workspace Events API delivering to a Cloud Pub/Sub topic. This is why Pub/Sub is in the architecture at all.
2. **No typing indicators.** Not exposed by any API, at any auth level. The "X is typing…" affordance in real Google Chat cannot be replicated.
3. **No presence / online status.** Same story.
4. **User auth only sees the calling user's spaces.** `spaces.list` returns spaces you're a member of. Org-wide listing needs `spaces.search` with admin privileges — out of scope.
5. **Read state is self-only.** You can read and set *your* read state; you cannot see whether others have read a message. No read receipts.
6. **DM membership events are delayed.** For user subscriptions, membership events in a DM only fire after the first message is posted.
7. **Sender identity is thin.** `Message.sender` gives a user resource name and display name — no avatar URL. Profile photos require the **People API** or **Admin SDK Directory API** as a separate lookup.
8. **Card messages are read-mostly.** Bot messages carry `cardsV2` payloads. Rendering these faithfully is a meaningful chunk of work (Phase 7); we cannot author cards as a user.

**Net effect:** this app can be a very good Google Chat client, but presence, typing indicators, and read receipts are permanently absent. Everything else is reachable.

---

## 2. Architecture

Swift 6 language mode, strict concurrency, no third-party dependencies. Layers are one-directional — UI never touches the network, sync never touches SwiftUI.

```
┌───────────────────────────────────────────────────┐
│  App        Scenes, Commands, Settings, Notifs    │
├───────────────────────────────────────────────────┤
│  Features   SpaceList · MessageList · Composer    │
│             ThreadPane · Inspector  (@Observable) │
├───────────────────────────────────────────────────┤
│  Sync       SyncEngine · Backfill · Reconciler    │
├───────────────────────────────────────────────────┤
│  Store      SwiftData models + ModelActor         │
├─────────────────────┬─────────────────────────────┤
│  ChatAPI            │  Events                     │
│  typed REST client  │  Subscriptions + PubSub pull│
├─────────────────────┴─────────────────────────────┤
│  GoogleAuth  PKCE · Keychain · token refresh      │
└───────────────────────────────────────────────────┘
```

### Module responsibilities

**GoogleAuth**
- OAuth 2.0 Authorization Code + PKCE via `ASWebAuthenticationSession`
- iOS-type OAuth client (no client secret), reverse-DNS redirect
  `com.googleusercontent.apps.<CLIENT_ID>:/oauth2redirect`
- `actor TokenStore` — Keychain-backed, `kSecAttrAccessibleAfterFirstUnlock`
- Single-flight refresh: concurrent 401s coalesce into one refresh round-trip
- Publishes an `AuthState` the UI observes (signed out / signing in / active / needs re-consent)

**ChatAPI**
- Hand-written typed client over Chat REST v1. No generated SDK — the surface we need is small and the generated Objective-C-era clients are unpleasant in Swift 6.
- `Codable` DTOs mirroring the REST schema exactly, mapped to domain models at the boundary
- `AsyncSequence`-based pagination so callers write `for try await page in client.messages(in: space)`
- Central error mapping; exponential backoff with jitter on 429/500/503, honouring `Retry-After`
- Quota-aware: Chat API limits are per-user-per-minute, so the client serialises bursts

**Events**
- Creates a Workspace Events subscription targeting `//chat.googleapis.com/spaces/-`
  (all spaces the user belongs to — one subscription, not one per space)
- Event types subscribed:
  `google.workspace.chat.message.v1.created` / `.updated` / `.deleted`
  `google.workspace.chat.reaction.v1.created` / `.deleted`
  `google.workspace.chat.membership.v1.created` / `.updated` / `.deleted`
  `google.workspace.chat.space.v1.updated`
- Pulls from Cloud Pub/Sub via REST `projects.subscriptions.pull` using the *user's* OAuth token, in a loop. No backend, no public endpoint, no service-account key on disk.
- **Renewal is mandatory.** Subscriptions expire; Google emits lifecycle events 12 h and 1 h before expiry. A background task renews via `subscriptions.patch` with `ttl: 0` (= extend to max). Belt-and-braces timer in addition to lifecycle events.
- Handles suspension (revoked scopes, deleted topic) by surfacing a re-auth prompt

**Store**
- SwiftData, `VersionedSchema` from the very first commit — retrofitting versioned schemas after shipping is the classic data-loss trap
- Models: `CachedSpace`, `CachedMessage`, `CachedMember`, `CachedUser`, `CachedReaction`, `CachedAttachment`, `SpaceReadState`, `SyncCursor`
- All writes through a `@ModelActor` on a background context; the UI reads via `@Query` on the main context
- Messages keyed by their Chat resource `name` — the natural dedupe key across pagination and events

**Sync**
- **Backfill**: paginated history walk per space, persisting a cursor so relaunch resumes rather than restarts
- **Live**: event stream applied incrementally
- **Reconcile**: on wake-from-sleep or network return, re-fetch the head of each active space to close gaps the event stream may have dropped. Events are best-effort, not a guaranteed log — the app must never trust them as the sole source of truth.

**Features / App**
- `NavigationSplitView`: sidebar (sections → spaces/DMs) │ message list │ `Inspector` (space details, members, pinned)
- Composer backed by `NSViewRepresentable` over `NSTextView` — needed for @-mention autocomplete, paste-to-attach, and correct multiline behaviour that `TextEditor` can't deliver
- `MenuBarExtra` with unread count
- `UNUserNotificationCenter` notifications for mentions and DMs
- Full `Commands` menu: ⌘N new message, ⌘F search, ⌘⇧A mark all read, ⌘1…9 jump to space
- Liquid Glass treatment per macOS 26 HIG

---

## 3. Google Cloud setup

Project: **GoogleChatSwiftUI** — project ID `YOUR_PROJECT_ID`, number `YOUR_NUMBER`, parented to the your-domain.com organisation (`YOUR_ORG_ID`), billing enabled.

Current status and the remaining manual steps live in [`SETUP.md`](SETUP.md).

### 3.1 Enable APIs

| API | Why |
|---|---|
| `chat.googleapis.com` | The Chat REST API itself |
| `workspaceevents.googleapis.com` | Event subscriptions |
| `pubsub.googleapis.com` | Event delivery transport |
| `people.googleapis.com` | Resolving sender names + avatars |
| `admin.googleapis.com` | Directory fallback for org user lookup |

### 3.2 OAuth consent screen — Internal

Because the project sits in the your-domain.com org and you're super-admin, the consent screen is set to **Internal**. This is worth a lot:

- No Google verification review, even for sensitive scopes
- No 100-test-user cap
- **Refresh tokens don't expire after 7 days** — the External/Testing mode behaviour that would otherwise force a weekly re-login

### 3.3 OAuth client — console-only step

There is no `gcloud` command that creates an installed-app OAuth client. This one is manual; I'll walk you through it with exact values. Client type **iOS**, bundle ID `com.example.GoogleChatSwiftUI`.

### 3.4 Scopes requested

```
https://www.googleapis.com/auth/chat.spaces
https://www.googleapis.com/auth/chat.messages
https://www.googleapis.com/auth/chat.messages.reactions
https://www.googleapis.com/auth/chat.memberships
https://www.googleapis.com/auth/chat.users.readstate
https://www.googleapis.com/auth/chat.users.sections
https://www.googleapis.com/auth/chat.customemojis.readonly
https://www.googleapis.com/auth/pubsub
https://www.googleapis.com/auth/userinfo.profile
```

`pubsub` is what lets the desktop app pull events directly with your own credentials instead of standing up a server.

### 3.5 Pub/Sub

- Topic `chat-events`
- Pull subscription `chat-events-mac` (ack deadline 60 s, 24 h retention)
- Grant `roles/pubsub.publisher` on the topic to `chat-api-push@system.gserviceaccount.com` — this is the principal Google Chat publishes as
- Grant `roles/pubsub.subscriber` on the subscription to `you@your-domain.com`

### 3.6 Chat API app configuration

The Chat API console page has an app-configuration tab (name, avatar, description). Whether it's mandatory for pure user-auth calls is ambiguous in the docs — I'll verify empirically with a live API call and configure it only if the API rejects us without it.

---

## 4. Xcode project changes

Current state: Xcode 26.6, Swift 6.3 toolchain, `objectVersion = 77` with file-system synchronized groups (so new `.swift` files on disk join the target automatically — no pbxproj surgery).

Required changes:

1. **`SWIFT_VERSION = 5.0` → `6.0`.** The project is on the Swift 5 language mode; the plan assumes strict concurrency. `SWIFT_APPROACHABLE_CONCURRENCY` is already on, which softens the migration.
2. **Network entitlement.** `ENABLE_APP_SANDBOX = YES` is set but there's no outgoing-network entitlement — every API call would fail. Needs `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`.
3. **Keychain access** for token storage.
4. **`CFBundleURLTypes`** registering the reverse-DNS OAuth redirect scheme.
5. **Delete the template `Item.swift`** and its SwiftData wiring once real models land.

---

## 5. Delivery phases

Each phase ends at something runnable, not a half-integrated layer.

Status as of 2026-08-06: phases 0–6 complete, 7 and 8 partial.

| # | Phase | Outcome |
|---|---|---|
| 0 | **Foundations** | Swift 6 mode, entitlements, URL scheme, folder structure, template cruft removed. Builds clean. |
| 1 | **GCP + Sign-in** | APIs enabled, Pub/Sub provisioned, OAuth client created. App shows a Sign in with Google button; completing it persists a token and displays your profile. |
| 2 | **Chat API client** | Typed client + DTOs + pagination + retry. Covered by tests against recorded fixtures. A debug screen lists your spaces. |
| 3 | **Cache + sync** | SwiftData schema, ModelActor writes, **strictly lazy** per-space backfill with cursors. History survives relaunch and loads offline. |
| 4 | **Core UI** | NavigationSplitView, **activity-filtered sidebar with search**, message list with threading, day separators, sender grouping. Read-only but genuinely usable. |
| 5 | **Writes** | Composer, send, edit, delete, reply-in-thread, mark-as-read. Optimistic local echo with rollback on failure. |
| 6 | **Realtime** | Subscription creation, Pub/Sub pull loop, renewal, wake/network reconciliation. Messages appear within ~1 s without a refresh. |
| 7 | **Rich content** | Reactions incl. custom emoji, attachment up/download, @-mention autocomplete and rendering, link previews, `cardsV2` rendering, pins. |
| 8 | **Polish** | Notifications, MenuBarExtra unread count, menu commands and shortcuts, search, space/member management, accessibility pass, Liquid Glass styling. |

---

## 6. Risks

| Risk | Mitigation |
|---|---|
| Event stream drops messages — it's best-effort, not a durable log | Never treat events as the only source of truth; reconcile heads on wake, network return, and window focus |
| Subscription expiry silently kills realtime | Renew on lifecycle events *and* on an independent timer; surface a visible "reconnecting" state |
| Chat API per-user quota throttling during initial backfill | Serialise backfill, respect `Retry-After`, backfill lazily per-space on first open rather than all spaces up front |
| `cardsV2` rendering is a deep well | Render a faithful subset (text, images, buttons, decorated text); fall back to a readable summary card for anything unsupported |
| Sandbox blocks OAuth or Pub/Sub in ways only visible at runtime | Entitlements land in Phase 0, exercised end-to-end in Phase 1 before any UI is built on top |
| Google Workspace admin policy blocks the Chat app for the org | You're super-admin — resolvable, but worth testing early rather than at Phase 6 |

---

## 7. Scale finding — 762 spaces

Measured on the real account in Phase 2. This is an order of magnitude more than a
naive design assumes, and it forces two decisions:

- **Backfill is strictly lazy.** Per-space, on first open, never up front. Eagerly
  walking history for 762 spaces would burn per-user quota for hours.
- **The sidebar filters by default.** Showing recently-active spaces only, with search
  across all 762. A flat list of that length is unusable, and most entries are dormant
  DMs that have not seen a message in years.

## 8. Remaining work

- **`cardsV2` rendering** — bot messages currently read "Card message"
- **Attachment upload** — download works; upload does not
- **Message search** — Chat has no search endpoint, so this must be local over cached history
- **Pins**
- **Menu-bar space selection** — clicking a conversation there activates the window but does not select the space; needs cross-scene selection state
- Multi-account support is out of scope for v1; the auth layer keeps it possible without redesign

## 9. API facts established the hard way

Each of these cost a wrong assumption first, and each shaped the design:

| Finding | Consequence |
|---|---|
| Chat never populates `displayName` — not on memberships, not on `Message.sender` | All names and photos come from the People API with `directory.readonly`; Chat IDs (`users/123`) map to People IDs (`people/123`) |
| The `Space` resource has no avatar, icon, or emoji field | Spaces get generated tiles; the custom images on chat.google.com are unreachable |
| `emojiReactionSummaries` gives counts but never says whether *you* reacted | Toggling lists a message's reactions first to find your own resource name |
| Read state is a timestamp, with no unread count | Counts are derived from cached history; unbackfilled spaces get a dot, not a wrong number |
| Chat API app configuration is *not* required for user-auth calls | No console work beyond consent screen + client — see [`SETUP.md`](SETUP.md) |
| Drive-hosted attachments carry no `attachmentDataRef` | They open in a browser; there is no media resource to download |
| Annotation `startIndex` units are unspecified (code points vs UTF-16) | Mentions are highlighted by name match, not by offset |
| Subscription max TTL is undocumented and varies with `includeResource` | Renewal patches `ttl: 0` ("extend to maximum") on a timer, so the value never needs knowing |

## 10. Project-wide gotcha

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes **every** unannotated type, extension, and closure main-actor isolated. Any `Codable` DTO, protocol conformance, or callback used off the main actor needs explicit `nonisolated`. This has bitten four times in different disguises, and only sometimes produces a compile error — `async` calls cross actors silently, so the failure mode is usually decoding on the main thread rather than a diagnostic.
