# Forum Fortress for Discourse

[![Discourse Plugin CI](https://github.com/Forum-Fortress/discourse-forum-fortress/actions/workflows/discourse-plugin.yml/badge.svg)](https://github.com/Forum-Fortress/discourse-forum-fortress/actions/workflows/discourse-plugin.yml)

Forum Fortress is a native Discourse plugin that checks selected user-generated activity against the Forum Fortress anti-spam service. This repository contains the first Discourse implementation and is intended to be installed as a normal Discourse plugin.

> **Release status:** Public alpha. Install on a current, backed-up Discourse site and validate the protected flows before relying on it in production.

## Current coverage

- New account registration, including the identity data described below, before the `User` record is accepted.
- New topics and replies in categories without read restrictions, before `NewPostManager` creates the post.
- Reply edits and first-post body/title edits in categories without read restrictions, before the revision transaction commits.
- Username/name changes and the supported profile fields `bio_raw` and `website`; these checks include account identity data as well as the fields changed in that submission.
- A native Forum Fortress dashboard showing enablement, local configuration, protection coverage, failure mode, an explicit connection test, and admin-only portal login.

Private messages and content in access-restricted categories are not sent to Forum Fortress. For a category-and-content edit, the check is skipped if either the current category or intended destination is restricted. If the plugin cannot establish the effective category safely, it skips the external content check without rejecting the Discourse action. Category-only moves do not create a content check.

Here, “without read restrictions” describes the category’s Discourse access setting; it does not claim that anonymous visitors can read the content. An otherwise unrestricted category on a site with `login_required` enabled is still eligible for checks. Staff, system, bot, and staged-user activity is skipped deliberately. Discourse has no direct equivalent of the Flarum signature field, so signature checks are not claimed here.

## Requirements

- A current supported Discourse installation. The plugin declares its minimum supported Discourse version in `plugin.rb`.
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
          - git clone https://github.com/Forum-Fortress/discourse-forum-fortress.git
```

Keep the existing `docker_manager` line and add only the Forum Fortress line beneath it. If the existing lines use `sudo -E -u discourse`, use the same prefix for this clone command. Then rebuild:

```sh
cd /var/discourse
./launcher rebuild app
```

This is Discourse's standard plugin installation method. Back up the site before rebuilding.

For a development checkout, clone this repository and symlink it into the
Discourse plugin directory:

```sh
cd /path/to
git clone https://github.com/Forum-Fortress/discourse-forum-fortress.git
ln -s /path/to/discourse-forum-fortress /path/to/discourse/plugins/discourse-forum-fortress
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
5. Use **Test connection** to verify an authenticated heartbeat and site status response.
6. Use **Open Forum Fortress portal** for an admin-only, short-lived portal login. Discourse requests the launch URL server-side and only redirects to validated Forum Fortress HTTPS hosts.

The site ID and endpoint state are hidden server-side settings maintained by the plugin. The legacy preferred-endpoint setting is retained only for offline issuer pinning; normal requests always start at the selected GeoDNS hostname. No API key is serialized to browser settings or exposed to frontend JavaScript.

## API and failure behaviour

The plugin uses the established Forum Fortress contract: `/v1/site/bootstrap`, the `register`, `topic`, `reply`, `topic_edit`, `reply_edit`, and `profile_edit` check routes, and `/v1/site/status`. `allow` continues the Discourse action, `block` adds a validation error, and the recognised legacy `review` decision is allowed through this synchronous gate. The plugin does not put `review` decisions into Discourse’s native review queue and does not synchronize either moderation system. Unknown decisions are treated as service failures. The plugin does not create local scoring, confidence thresholds, or shadow decisions. A stable per-check request ID is reused across endpoint retries so Forum Fortress can deduplicate one logical check.

Protected actions wait synchronously for a decision before their Discourse save can complete; checks are not asynchronous or zero-latency. The normal total timeout is configurable from 1 to 30 seconds and defaults to 5 seconds. Each regional check attempt is capped at 1 second within that total budget. First-time bootstrap has a separate 30-second total bound so edge-to-control provisioning can complete without lengthening normal posting requests. A ten-minute scheduled job retries incomplete bootstrap state; authenticated heartbeat attempts are limited to hourly on standard plans and every ten minutes on Pro or MultiMod. Global requests start at `api.ffapi.net` and retry `fortress.ffapi.net` only after failure. Regional requests remain locked unless global fallback is enabled, when they may also try both global hosts. The plugin does not probe health routes or fetch an endpoint catalogue. With fail-open enabled by default, network, timeout, malformed-response, and service errors allow the Discourse action to continue; the error is reduced to a sanitized code in hidden state and a generic application log entry. With fail-open disabled, the action receives a localized temporary-unavailable validation error.

## Privacy and data handling

Only fields already used by the Forum Fortress forum integrations are sent: the site domain and platform metadata; registration/profile identity fields (including username and email); account age and post count; request IP and user agent for new posts when Discourse supplies them; eligible submitted post content; and external links extracted from that content. Registration can include display name, bio, website, registration IP and email before the account is accepted. Profile checks include the account identity fields plus only the supported profile fields changed in that submission. Private-message content, content in access-restricted categories, arbitrary Discourse metadata, and rendered profile HTML are not sent.

The plugin does not add application-log entries containing raw emails, IP addresses, user agents, post bodies, links, or API keys. The API key uses Discourse's ordinary server-only secret site-setting mechanism. Forum Fortress is an external service dependency; administrators should review [Privacy and network access](https://forumfortress.com/docs/privacy-network/) and the [Privacy Policy](https://forumfortress.com/privacy/) before enabling it.

## Updating and compatibility

Back up the site and run `./launcher rebuild app`; the normal rebuild process fetches the current plugin source. Update the plugin together with the Discourse version it targets, then re-run the admin connection test. The plugin targets current supported Discourse releases and declares a minimum of Discourse `2026.8.0`; older releases are not supported. Review the changelog and release notes before upgrading across a major Discourse change.

## Public CI and release validation

Public GitHub Actions uses the standard Discourse plugin workflow. It runs the repository's JavaScript, stylesheet, type, Ruby and formatting checks, then installs the plugin against current Discourse core to validate database creation and migrations, Zeitwerk eager loading and reloading, and boot compatibility. Comprehensive behavioural, security and service-integration regression tests remain private and are not represented by the public CI badge. Because this repository does not publish those RSpec or QUnit suites, those workflow stages are skipped.

## Known first-release limitations

- No private-message checks, signature checks, moderation-queue synchronization, or post-creation telemetry reports.
- Staged-user and automated/system flows are intentionally excluded and need a real site review if a deployment wants different policy.
- OAuth/SSO and unusual import/API creation paths should be exercised on the eventual test instance.
- Out-of-band model saves with no explicit acting user are deliberately skipped. Queued-post approval and non-standard plugins that bypass `NewPostManager` or `PostRevisor` need integration validation.
- A signed-in visual pass and live portal handoff should still be repeated after each deployment.

## License

The Forum Fortress plugin is free and open-source software licensed under the
GNU General Public License, version 2 or later (`GPL-2.0-or-later`). See
`LICENSE` for the complete licence and `NOTICE` for the copyright, service and
trademark boundary.

The Forum Fortress hosted service is separate and is governed by its service
terms. The plugin licence does not provide a subscription, credentials, access
to private backend code, or permission to imply that a fork is an official
Forum Fortress release.

Contributions are submitted under `GPL-2.0-or-later`; contributors retain their
copyright. This project does not require a contributor licence agreement or
copyright assignment. See `CONTRIBUTING.md`.
