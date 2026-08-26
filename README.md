# Forum Fortress for Discourse

Forum Fortress is a native Discourse plugin that checks selected user-generated activity against the Forum Fortress anti-spam service. This repository contains the first Discourse implementation and is intended to be installed as a normal Discourse plugin.

> **Release status:** `0.1.0-alpha.1` is the first public alpha. Install it on a current, backed-up Discourse site and validate the protected flows before relying on it in production.

## Current coverage

- New account registration, before the `User` record is accepted.
- New public topics and replies, before `NewPostManager` creates the post.
- Public reply edits and first-post body/title edits, before the revision transaction commits.
- Username/name changes and the supported profile fields `bio_raw` and `website`.
- A native Forum Fortress dashboard showing enablement, local configuration, protection coverage, failure mode, an explicit connection test, and admin-only portal login.

Private messages are not sent to Forum Fortress. Staff, system, bot, and staged-user activity is skipped deliberately. Discourse has no direct equivalent of the Flarum signature field, so signature checks are not claimed here.

## Requirements

- A current supported Discourse installation. The implementation was researched against Discourse `main` at commit `e5aca7217abbc9ea113da2751a9720254b8b7440` on 2026-08-25.
- Outbound HTTPS access from the Discourse application to the Forum Fortress control and check endpoints.
- Forum Fortress account access or an existing Forum Fortress site API key. A blank key can be bootstrapped by the first connection test or protected request when the control plane permits anonymous site onboarding. An existing site can instead use a short-lived bootstrap token issued by Forum Fortress.

## Installation

On a standard self-hosted Docker installation, add the public repository to the `hooks.after_code` section of `/var/discourse/containers/app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/Forum-Fortress/discourse.git discourse-forum-fortress
```

Keep the existing `docker_manager` line and add only the Forum Fortress line beneath it. If the existing lines use `sudo -E -u discourse`, use the same prefix for this clone command. Then rebuild:

```sh
cd /var/discourse
./launcher rebuild app
```

This is Discourse's standard plugin installation method. Back up the site before rebuilding.

For a development checkout, a symlink is convenient:

```sh
ln -s /path/to/fortress/plugins/discourse-forum-fortress /path/to/discourse/plugins/discourse-forum-fortress
```

Restart a development instance or rebuild a production instance after adding or updating the plugin. Do not copy this plugin into Discourse core or patch core files.

## Uninstallation

Before removing the plugin directory, run its cleanup task inside the Discourse application container:

```sh
cd /var/discourse
./launcher enter app
cd /var/www/discourse
RAILS_ENV=production bundle exec rake forum_fortress:uninstall
exit
./launcher rebuild app
```

The task first asks Forum Fortress to deprovision the authenticated site, then removes all Forum Fortress site-setting overrides from every Discourse database. It treats an already removed site or an installation with no local identity as clean. If remote deprovisioning cannot be confirmed, it leaves the local identity in place so the task can be retried. To remove local settings despite a confirmed Forum Fortress outage, rerun with `FORUM_FORTRESS_FORCE_LOCAL_CLEANUP=1`, understanding that the remote site may then require manual removal.

After the task succeeds, remove the Forum Fortress `git clone` line from `containers/app.yml` and rebuild Discourse. Merely disabling the plugin is reversible and intentionally does not deprovision the Forum Fortress site.

## Configuration

After installation, open **Admin → Plugins → Forum Fortress → Dashboard**, or configure the `Forum Fortress` plugin settings directly.

1. Enable `forum_fortress_enabled`.
2. Leave `forum_fortress_api_key` blank for automatic bootstrap, or enter the key supplied by Forum Fortress. It is a server-only secret setting. If Forum Fortress already knows this domain and its existing key is unavailable, enter an issued short-lived token in `forum_fortress_bootstrap_token`; the plugin clears that token after bootstrap succeeds.
3. Select the API region. Keep global fallback disabled unless the site’s operating policy permits cross-region fallback.
4. Keep `forum_fortress_fail_open` enabled initially. Disable it only when the administrator explicitly wants a temporary Forum Fortress outage to reject registrations/posts.
5. Use **Test connection** to verify the health endpoint and the site status response.
6. Use **Open Forum Fortress portal** for an admin-only, short-lived portal login. Discourse requests the launch URL server-side and only redirects to validated Forum Fortress HTTPS hosts.

The site ID, preferred endpoint, and endpoint state are hidden server-side settings maintained by the plugin. No API key is serialized to browser settings or exposed to frontend JavaScript.

## API and failure behaviour

The plugin uses the established Forum Fortress contract: `/v1/site/bootstrap`, the `register`, `topic`, `reply`, `topic_edit`, `reply_edit`, and `profile_edit` check routes, and `/v1/site/status`, with the existing `allow`/`review`/`block` decision semantics. As in the established integrations, `review` is accepted by the synchronous gate. The plugin does not create local scoring, confidence thresholds, or shadow decisions. A stable per-check request ID is reused across endpoint retries so Forum Fortress can deduplicate one logical check.

Checks are synchronous where Discourse needs a decision before saving a registration or public post. Ordinary checks use the configured bounded timeout and regional candidates. First-time bootstrap has a separate 30-second bound so edge-to-control provisioning can complete without lengthening normal posting requests. With fail-open enabled, network, timeout, malformed-response, and service errors allow the Discourse action to continue; the error is reduced to a sanitized code in hidden state and a generic application log entry. With fail-open disabled, the action receives a localized temporary-unavailable validation error.

## Privacy and data handling

Only fields already used by the Forum Fortress forum integrations are sent: the site domain and platform metadata; registration/profile identity fields; account age and post count; request IP and user agent for new posts when Discourse supplies them; public post content; and external links extracted from that content. Profile edits include only the supported fields changed in that submission. Private-message content, arbitrary Discourse metadata, and rendered profile HTML are not sent.

The plugin does not add application-log entries containing raw emails, IP addresses, user agents, post bodies, links, or API keys. The API key uses Discourse's ordinary server-only secret site-setting mechanism. Administrators should review their Forum Fortress account’s retention and privacy settings separately.

## Updating and compatibility

Back up the site and run `./launcher rebuild app`; the normal rebuild process fetches the current plugin source. Update the plugin together with the Discourse version it targets, then re-run the admin connection test. This alpha targets current Discourse APIs and does not promise compatibility with older releases. Review `IMPLEMENTATION_NOTES.md` before upgrading across a major Discourse change.

## Development and testing

From the Discourse checkout with this plugin linked into `plugins/`:

```sh
bundle exec rake "plugin:spec[discourse-forum-fortress]"
bundle exec rake "plugin:qunit[discourse-forum-fortress]"
```

The RSpec suite uses fake settings and transport objects for the API client and decision mapping, plus focused protection and payload tests. The QUnit suite covers the current admin-plugin route and dashboard interaction. When Chromium runs inside a restricted container, set `DISCOURSE_DISABLE_BROWSER_SANDBOX=1` for the QUnit command. Run the suites through Discourse’s Docker development container for the real Rails environment:

```sh
cd /path/to/discourse
ln -s /path/to/discourse-forum-fortress plugins/discourse-forum-fortress
d/boot_dev --init
d/mailhog
d/rails s
```

In a second terminal, start the current Ember development bundle:

```sh
cd /path/to/discourse
d/dev --only ember
```

The official development scripts bind the web app to `127.0.0.1:3000` and the local MailHog/Mailpit-compatible inbox to `127.0.0.1:8025`; do not pass `--net-public` when testing locally. The SMTP sink listens on port `1025`, so no public web server, DNS name, or email provider is required. Open `http://127.0.0.1:3000` and `http://127.0.0.1:8025` to inspect the installation. Run `d/rspec plugins/discourse-forum-fortress/spec` or `d/rake plugin:spec[discourse-forum-fortress]` for the plugin suite, and stop the container with `d/shutdown_dev` when finished. Real Forum Fortress connection tests still require outbound HTTPS access to the configured Forum Fortress API; the automated suite remains offline and uses test doubles.

## Known first-release limitations

- No private-message checks, signature checks, moderation-queue synchronization, or post-creation telemetry reports.
- Staged-user and automated/system flows are intentionally excluded and need a real site review if a deployment wants different policy.
- OAuth/SSO and unusual import/API creation paths should be exercised on the eventual test instance.
- Out-of-band model saves with no explicit acting user are deliberately skipped. Queued-post approval and non-standard plugins that bypass `NewPostManager` or `PostRevisor` need integration validation.
- The local Docker workflow validates current core boot, route discovery, plugin loading, the Ember bundle, the dashboard route/rendering, the admin status request, connection-test presentation, and the plugin RSpec suite. A signed-in visual pass and live portal handoff should still be repeated after each deployment.
