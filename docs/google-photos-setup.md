# Google Photos setup

lifejusthappening uploads straight into a `lifejusthappening` album in your Google Photos. Google doesn't hand out a shared key for that, so you create your own OAuth client once. It's free and takes about five minutes.

## 1. Create a project and enable the API

1. Open [Google Cloud Console](https://console.cloud.google.com/) and create a project, for example `lifejusthappening`.
2. Go to **APIs & Services → Library**, search for **Photos Library API** and click **Enable**.

## 2. Configure the consent screen

1. Go to **Google Auth Platform** (older consoles call it **OAuth consent screen**).
2. **Branding**: app name `lifejusthappening`, and your email as the support and developer contact.
3. **Audience**: if your account is a Google Workspace account (your own domain), pick **Internal** and you're done with this step: no test users, no publishing, tokens don't expire. For a plain @gmail.com account pick **External** and add yourself under **Test users**.
4. **Data access**: add the scopes `openid`, `.../auth/userinfo.email`, `.../auth/photoslibrary.appendonly` and `.../auth/photoslibrary.readonly.appcreateddata`.
5. External only: click **Publish app** so the status reads **In production**.

   Don't skip that on External. While the app is in *Testing*, Google expires your sign-in after 7 days and uploads stop until you sign in again. In production it keeps working. You don't need Google's verification for personal use; you'll just see a "Google hasn't verified this app" screen once when you sign in.

## 3. Create the client

1. Go to **Clients → Create client**.
2. Application type: **Desktop app**. Name it whatever you want.
3. Click **Download JSON**. You get a file like `client_secret_1234-abc.apps.googleusercontent.com.json`.

## 4. Connect the app

1. Either drop the downloaded file at `~/Library/Application Support/lifejusthappening/google-oauth-client.json` (the app picks it up within 30 seconds, moves it into its private credentials file and deletes the download), or open **Settings → Google Photos** from the menu bar and use **Import client JSON…**.
2. Click **Sign in with Google**. (`lifejusthappening --sign-in` does the same from the command line.)
3. Your browser opens.
4. On the "Google hasn't verified this app" screen, click **Advanced → Go to lifejusthappening**, then allow access.
5. The tab says you can close it, and the popover shows your account.

The first upload creates the album. Photos taken before you connected upload right away.

## What the app can see

It asks for `photoslibrary.appendonly` (add photos and create albums), `photoslibrary.readonly.appcreateddata` (find its own album again after a reinstall instead of creating a second one) and your email so it can show which account is connected. It can't see, change or delete anything it didn't create. Since April 2025 Google only lets apps touch albums they created themselves.

## Where things are stored

- **OAuth client and refresh token**: `~/Library/Application Support/lifejusthappening/google-credentials.json`, owner-only (0600).
- **Photos**: `~/Library/Application Support/lifejusthappening/Outbox/` holds a photo only until the upload succeeds, then deletes it. It only fills up while you're offline or not signed in.
- **Rejected photos**: if Google ever refuses a specific photo, it moves to `…/Rejected/` so it isn't lost, and the popover shows a count.

## Troubleshooting

- **"Google access expired or was revoked"**: sign in again. If this happens weekly, an External consent screen is still in *Testing* (see step 2.5).
- **"HTTP 403 … Photos Library API has not been used"**: the API isn't enabled on the project that owns your client (step 1.2).
- **You deleted the album in Google Photos**: the app creates a new one on the next upload.
