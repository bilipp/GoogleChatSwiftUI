# Google Cloud setup

Everything the app needs from Google Cloud, in the order it has to happen. The
README's [Getting started](../README.md#getting-started) section is the short
version; this is the same ground with the reasoning attached.

Throughout, substitute your own values for `YOUR_PROJECT_ID`, `you@your-domain.com`,
and the bundle identifier.

## Prerequisite: an org-parented project

Create the project **inside a Google Workspace organisation**. That is what makes an
**Internal** OAuth consent screen available, which in turn buys:

- No Google verification review, even for sensitive scopes
- No 100-test-user cap
- **Refresh tokens that do not expire after 7 days** — the External/Testing behaviour
  that would otherwise force a weekly re-login

A personal Gmail account cannot do this. It is the one hard requirement.

```bash
gcloud config set project YOUR_PROJECT_ID
```

---

## 1. Enable APIs

```bash
gcloud services enable \
  chat.googleapis.com \
  workspaceevents.googleapis.com \
  pubsub.googleapis.com \
  people.googleapis.com \
  admin.googleapis.com
```

| API | Why |
|---|---|
| `chat.googleapis.com` | The Chat REST API itself |
| `workspaceevents.googleapis.com` | Event subscriptions |
| `pubsub.googleapis.com` | Event delivery transport |
| `people.googleapis.com` | Resolving sender names and avatars |
| `admin.googleapis.com` | Directory fallback for org user lookup |

## 2. Provision Pub/Sub

The topic and subscription names are hard-coded in `OAuthConfiguration`, so either use
these exactly or change them there too.

```bash
gcloud pubsub topics create chat-events

gcloud pubsub subscriptions create chat-events-mac \
  --topic=chat-events \
  --ack-deadline=60 \
  --message-retention-duration=24h
```

| Resource | Value |
|---|---|
| Topic | `projects/YOUR_PROJECT_ID/topics/chat-events` |
| Subscription | `projects/YOUR_PROJECT_ID/subscriptions/chat-events-mac` |
| Type | Pull — the Mac app pulls directly, so there is no push endpoint to host |
| Ack deadline | 60 s |
| Retention | 24 h |
| Expiration | Never |

### IAM

```bash
# Lets Google Chat publish events into the topic
gcloud pubsub topics add-iam-policy-binding chat-events \
  --member="serviceAccount:chat-api-push@system.gserviceaccount.com" \
  --role="roles/pubsub.publisher"

# Lets the app pull them with your own OAuth token
gcloud pubsub subscriptions add-iam-policy-binding chat-events-mac \
  --member="user:you@your-domain.com" \
  --role="roles/pubsub.subscriber"
```

`chat-api-push@system.gserviceaccount.com` is the principal Google Chat publishes as —
it is keyed to the delivering application, not to your auth method, so it is the same
for everyone. The second grant is what lets the desktop app pull with your own OAuth
token, which is why no service-account key ever touches disk.

---

## 3. OAuth — console only

Neither step below has a `gcloud` equivalent. There is no API for creating installed-app
OAuth clients, and the consent screen is only configurable through the Google Auth
Platform UI.

### 3.1 Consent screen

[console.cloud.google.com/auth/overview](https://console.cloud.google.com/auth/overview)

- User type: **Internal**
- App name, support email, developer contact: your own

Add these scopes:

```
https://www.googleapis.com/auth/chat.spaces
https://www.googleapis.com/auth/chat.messages
https://www.googleapis.com/auth/chat.messages.reactions
https://www.googleapis.com/auth/chat.memberships
https://www.googleapis.com/auth/chat.users.readstate
https://www.googleapis.com/auth/chat.users.sections
https://www.googleapis.com/auth/chat.customemojis.readonly
https://www.googleapis.com/auth/directory.readonly
https://www.googleapis.com/auth/pubsub
https://www.googleapis.com/auth/userinfo.profile
```

`directory.readonly` is not optional in practice: Chat never returns display names, so
without it every DM is titled "Direct message" and every sender reads "Unknown".
`pubsub` is what lets the app pull events directly instead of standing up a server.

### 3.2 OAuth client

[console.cloud.google.com/auth/clients](https://console.cloud.google.com/auth/clients)

- Application type: **iOS** — correct for macOS too. It issues no client secret and
  supports the reverse-DNS redirect that `ASWebAuthenticationSession` handles natively.
- Bundle ID: whatever you will set as `PRODUCT_BUNDLE_IDENTIFIER` in Xcode

The resulting client ID looks like `YOUR_NUMBER-YOUR_SUFFIX.apps.googleusercontent.com`,
and its reversed form becomes the app's URL scheme:

```
com.googleusercontent.apps.YOUR_NUMBER-YOUR_SUFFIX
```

Redirect URI used by the app:

```
com.googleusercontent.apps.YOUR_NUMBER-YOUR_SUFFIX:/oauth2redirect
```

The scheme is deliberately **not** registered in `CFBundleURLTypes`, so no outside
browser can hand an authorization code to the app.

## 4. Point the app at the project

Fill in the three placeholders in
[`GoogleChatSwiftUI/GoogleAuth/OAuthConfiguration.swift`](../GoogleChatSwiftUI/GoogleAuth/OAuthConfiguration.swift):

```swift
static let clientID = "YOUR_NUMBER-YOUR_SUFFIX.apps.googleusercontent.com"
static let redirectScheme = "com.googleusercontent.apps.YOUR_NUMBER-YOUR_SUFFIX"
static let gcpProjectID = "YOUR_PROJECT_ID"
```

Then set `PRODUCT_BUNDLE_IDENTIFIER` in Xcode to the bundle ID you registered above.

There is no client secret to fill in and none is missing — installed-app clients are
issued without one on purpose. See [RFC 8252 §8](https://datatracker.ietf.org/doc/html/rfc8252#section-8).

---

## Settled questions

**The Chat API app-configuration page is _not_ required for user-auth calls.**
Established empirically: with only `chat.googleapis.com` enabled and a user OAuth grant,
`spaces.list` returned 762 spaces. The Configuration tab matters only for apps that
receive interaction events — bots, slash commands, cards. A user-auth client needs no
console work beyond the consent screen and the client itself.

**`chat-api-push@system.gserviceaccount.com` is the right publisher principal.**
There are community reports of `INVALID_PUBSUB_TOPIC` in adjacent scenarios, but the
grant above is what a working subscription uses. If `subscriptions.create` ever rejects
the topic, the fix is a different principal grant, not a redesign.
