# Source authentication

Use your GoToSocial server's settings panel to create and authorize a managed
application. This keeps the sign-in flow on your own server.

1. Sign in at your server's `/settings` page and open **Applications**.
2. Create an application named `gotosocial-to-mastodon`.
3. Set the scopes to `read:accounts read:statuses` (or `read`).
4. Add the settings-panel callback shown by your server. Its form is
   `https://YOUR_SERVER/settings/user/applications/callback`; use your actual host.
5. Open the application's details, request a token and authorize it. Copy the
   resulting **user access token**, not the client ID, client secret or temporary
   authorization code.

Paste it into the exporter's hidden prompt, or store it in a file readable only
by you and pass `--token-file`. An environment variable named `GTS_TOKEN` is also
supported. Revoke the application's token when the export is finished.

The application and token must belong to the exact source instance. The exporter
checks account ownership with `verify_credentials`. It never needs your password,
prints no token and saves none in the archive.

Older server settings may differ; consult the official
[GoToSocial authentication guide](https://docs.gotosocial.org/en/latest/api/authentication/).
The current settings workflow is documented under
[Applications](https://docs.gotosocial.org/en/latest/user_guide/settings/#applications).
