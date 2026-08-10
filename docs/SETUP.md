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

One topic for the project, then **one subscription per person**.

```bash
gcloud pubsub topics create chat-events

# Lets Google Chat publish events into the topic
gcloud pubsub topics add-iam-policy-binding chat-events \
  --member="serviceAccount:chat-api-push@system.gserviceaccount.com" \
  --role="roles/pubsub.publisher"
```

`chat-api-push@system.gserviceaccount.com` is the principal Google Chat publishes as —
it is keyed to the delivering application, not to your auth method, so it is the same
for everyone.

The topic name is hard-coded in `OAuthConfiguration`, so use it exactly or change it
there too.

### One subscription per person

Run this once for each person who will use the app, including yourself. The name is
derived from the local part of their address, lowercased, with anything that is not a
letter or digit flattened to a dash — so `p.bischoff@innoloft.com` gets
`chat-events-p-bischoff`. `OAuthConfiguration.subscriptionID(for:)` is the authority on
the spelling, and `EventQueueNamingTests` pins it.

```bash
PERSON=p.bischoff@innoloft.com
QUEUE=chat-events-p-bischoff

gcloud pubsub subscriptions create "$QUEUE" \
  --topic=chat-events \
  --ack-deadline=60 \
  --message-retention-duration=24h \
  --expiration-period=never

# Lets that person's app pull with their own OAuth token
gcloud pubsub subscriptions add-iam-policy-binding "$QUEUE" \
  --member="user:$PERSON" \
  --role="roles/pubsub.subscriber"
```

`--expiration-period=never` is not optional. A subscription created without it is deleted
after 31 days without a pull, so anyone who takes a month off comes back to an app that
syncs on ⌘R and never arrives on its own — a failure that looks nothing like its cause.

| Resource | Value |
|---|---|
| Topic | `projects/YOUR_PROJECT_ID/topics/chat-events` |
| Subscription | `projects/YOUR_PROJECT_ID/subscriptions/chat-events-<person>` |
| Type | Pull — the Mac app pulls directly, so there is no push endpoint to host |
| Ack deadline | 60 s |
| Retention | 24 h |
| Expiration | Never |

The per-person grant is what lets the desktop app pull with that person's own OAuth
token, which is why no service-account key ever touches disk. It is also the whole
permission each colleague needs: `roles/pubsub.subscriber` on their own subscription,
and nothing on the project.

> [!IMPORTANT]
> **Why not one shared subscription.** A Pub/Sub subscription is a single queue, and it
> distributes its backlog across whoever is pulling it. Chat publishes every
> subscriber's events into the one topic, so two people sharing a subscription do not
> each receive the stream — they split it, at random, and each silently misses about
> half of their own messages. Manual refresh hides it, so it presents as unreliable
> realtime rather than as a setup mistake. Hence one queue per person.

If someone's subscription is missing, or they hold no grant on it, the app says which
queue it wanted and stays usable on manual refresh rather than failing opaquely.

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
https://www.googleapis.com/auth/userinfo.email
```

`directory.readonly` is not optional in practice: Chat never returns display names, so
without it every DM is titled "Direct message" and every sender reads "Unknown".
`pubsub` is what lets the app pull events directly instead of standing up a server.
`userinfo.email` names the subscription that person pulls from (§2) — without it the app
cannot tell which queue is theirs, and says so instead of guessing.

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

Everything that differs per person lives in one gitignored file:

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
```

```
APP_BUNDLE_ID = com.yourname.GoogleChatSwiftUI
DEVELOPMENT_TEAM = YOURTEAMID

GOOGLE_OAUTH_CLIENT_ID = YOUR_NUMBER-YOUR_SUFFIX.apps.googleusercontent.com
GOOGLE_OAUTH_REDIRECT_SCHEME = com.googleusercontent.apps.YOUR_NUMBER-YOUR_SUFFIX
GCP_PROJECT_ID = YOUR_PROJECT_ID
```

`APP_BUNDLE_ID` should match the bundle ID registered with the OAuth client in §3.2, but
nothing enforces it: the redirect URI is bound to the *client ID*, not to the bundle ID,
and the bundle ID is never sent — the authorization request and the token exchange carry
`client_id`, `redirect_uri`, `code` and `code_verifier` and nothing else. Nor does the
callback depend on it, because `ASWebAuthenticationSession` intercepts the custom scheme
in-process rather than having the OS route it to a registered handler. So a mismatch is
untidy rather than fatal. The tests target appends `Tests`.

`DEVELOPMENT_TEAM` may be left empty, which signs to run locally — see
[Building without an Apple Developer team](#building-without-an-apple-developer-team).

### How it reaches the binary

| File | Role |
|---|---|
| `Config/Base.xcconfig` | Placeholder defaults, then `#include? "Secrets.xcconfig"` — the `?` is what lets a checkout without one still build |
| `Config/Secrets.xcconfig` | Yours, gitignored, overrides the defaults |
| `Config/Info.plist` | `$(VAR)` references that Xcode substitutes at build time, merged into the generated Info.plist |
| `OAuthConfiguration` | Reads the three keys back out of `Bundle.main` |

An unconfigured build is a working build: it runs, and the sign-in screen explains what
is missing instead of sending placeholders to Google and returning `invalid_client`.

Despite the file's name, none of these values is a secret — installed-app clients are
issued without one on purpose. See [RFC 8252 §8](https://datatracker.ietf.org/doc/html/rfc8252#section-8).
It is gitignored so the repository stays free of one person's project, not because
publishing the values would be a leak.

## 5. Building without an Apple Developer team

Leaving `DEVELOPMENT_TEAM` empty builds and runs fine — Xcode falls back to the ad-hoc
"Sign to Run Locally" identity, and the sandbox entitlements the app needs
(`app-sandbox`, `network.client`, `files.user-selected.read-write`) all survive. This is
the right setting for anyone who is not a member of the team that owns the app.

The one consequence is worth knowing before it looks like a bug: **an ad-hoc build asks
you to sign in again after every rebuild.** An ad-hoc signature's designated requirement
is the binary hash alone —

```
$ codesign -d -r- "Google Chat.app"
# designated => cdhash H"9dc8fe99677e00a637e28866fd5f502a76f9bfe6"
```

— with no identifier and no team in it, so recompiling produces a different identity as
far as the keychain is concerned, and the OAuth tokens saved under the previous hash can
no longer be read. A team-signed build's requirement is identifier-plus-team and stays
stable across rebuilds, so it keeps its tokens.

Signing in again takes a few seconds and costs nothing else: nothing is lost but the
token, and the local cache is rebuilt on the next sync either way.

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
