# GCP Setup — GoogleChatSwiftUI

## Project coordinates

| | |
|---|---|
| Project name | GoogleChatSwiftUI |
| Project ID | `YOUR_PROJECT_ID` |
| Project number | `YOUR_NUMBER` |
| Organisation | your-domain.com (`YOUR_ORG_ID`) |
| Billing | Enabled (`YOUR_BILLING_ACCOUNT`) |
| Console | https://console.cloud.google.com/home/dashboard?project=YOUR_PROJECT_ID |

The project being org-parented is what makes an **Internal** OAuth consent screen possible.

---

## Done

### APIs enabled

```
chat.googleapis.com
workspaceevents.googleapis.com
pubsub.googleapis.com
people.googleapis.com
admin.googleapis.com
```

### Pub/Sub

| Resource | Value |
|---|---|
| Topic | `projects/YOUR_PROJECT_ID/topics/chat-events` |
| Subscription | `projects/YOUR_PROJECT_ID/subscriptions/chat-events-mac` |
| Type | Pull (no push endpoint — the Mac app pulls directly) |
| Ack deadline | 60 s |
| Retention | 24 h |
| Expiration | Never |

### IAM

| Principal | Role | On |
|---|---|---|
| `chat-api-push@system.gserviceaccount.com` | `roles/pubsub.publisher` | topic `chat-events` |
| `you@your-domain.com` | `roles/pubsub.subscriber` | subscription `chat-events-mac` |

The first grant is what lets Google Chat publish events into the topic. The second is what lets the desktop app pull them with your own OAuth token — no service-account key ever touches disk.

---

## Remaining — console only

Neither step below has a `gcloud` equivalent. There is no API for creating installed-app OAuth clients, and the consent screen is only configurable through the Google Auth Platform UI.

### 1. OAuth consent screen

https://console.cloud.google.com/auth/overview?project=YOUR_PROJECT_ID

- User type: **Internal**
- App name: `GoogleChatSwiftUI`
- User support email: `you@your-domain.com`
- Developer contact: `you@your-domain.com`

Add these scopes:

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

Internal mode means no Google verification review, no 100-user cap, and refresh tokens that do not expire after 7 days.

### 2. OAuth client

https://console.cloud.google.com/auth/clients?project=YOUR_PROJECT_ID

- Application type: **iOS** (this is correct for macOS too — it issues no client secret and supports the reverse-DNS redirect that `ASWebAuthenticationSession` handles natively)
- Bundle ID: `com.example.GoogleChatSwiftUI`

The resulting client ID looks like `YOUR_NUMBER-xxxxxxxx.apps.googleusercontent.com`. Its reversed form becomes the app's URL scheme:

```
com.googleusercontent.apps.YOUR_NUMBER-xxxxxxxx
```

Redirect URI used by the app:

```
com.googleusercontent.apps.YOUR_NUMBER-xxxxxxxx:/oauth2redirect
```

---

## Resolved

**The Chat API app-configuration page is _not_ required for user-auth calls.** Settled empirically on 2026-08-06: with only `chat.googleapis.com` enabled and a user OAuth grant, `spaces.list` returned 762 spaces. The Configuration tab is needed only for apps that receive interaction events (bots, slash commands, cards) — not for a user-auth client. No further console work needed.

**Whether `chat-api-push@system.gserviceaccount.com` is the right publisher principal.** The docs key this to the delivering application (Chat), not the auth method, so it should be correct. But there are unresolved community reports of `INVALID_PUBSUB_TOPIC` in adjacent scenarios. The real test is the first `subscriptions.create` call in Phase 6 — if it rejects the topic, the fix is a different principal grant, not a redesign.
