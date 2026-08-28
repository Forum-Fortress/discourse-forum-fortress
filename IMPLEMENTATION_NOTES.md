# Forum Fortress Discourse implementation notes

## Platform baseline

The plugin was built against the current official Discourse checkout at `e5aca7217abbc9ea113da2751a9720254b8b7440` (2026-08-25), the current official plugin skeleton, and maintained official plugins including `discourse-captcha`, `discourse-policy`, `poll`, `discourse-rss-polling`, and the current chat/admin implementations. The skeleton’s `plugin.rb`, `config/settings.yml`, Rails engine, admin route, admin configuration navigation, GJS templates, and lint configuration are the structural reference.

## Selected extension points

- `validate(:user, ...)` is used for new registrations. The current signup controller assigns registration IP data before saving the user, and model validation runs before activation/ordinary account use. The validator only acts on new, non-staff, non-staged, non-system users.
- `NewPostManager.add_handler(1)` is used for new content. This is before the default `PostCreator` path and before a post becomes public or is queued. The handler covers a new topic and a reply, skips personal messages, and uses the request IP/user agent that current `PostsController#create_params` deliberately exposes to spam-prevention plugins.
- `validate(:post, ...)` is used for persisted body edits, while `validate(:topic, ...)` covers first-post title edits. Both execute within `PostRevisor`'s transaction, so a block rolls back the complete revision. `post_created` and `post_edited` events are after-save notifications and therefore cannot safely block publication.
- Discourse saves a first-post body before applying a title change. A narrowly scoped, reload-safe `PostRevisor` prepend records only the post ID and whether the same revision contains a real title change in `RequestStore`; it does not alter fields or persistence. This lets the post validator defer a combined edit to the later topic validator, avoiding duplicate checks and avoiding a payload that combines the new body with the old title. Core currently exposes no pre-validation modifier carrying both revision fields.
- `validate(:user_profile, ...)` is used for existing `bio_raw` and `website` changes. The current `users_controller_update_user_params` modifier records the authenticated actor in request-local storage before `UserUpdater` saves `User` and `UserProfile`. This prevents staff-created/profile maintenance and out-of-band saves from being attributed to the target user. Username/name changes are handled by the `User` validator. Only fields changed in the current submission are sent. Discourse’s profile model has no clean signature equivalent, so signature protection is omitted.
- A Rails engine supplies admin-only JSON endpoints for a local status summary and an explicit connection test. The frontend uses the current `adminPlugins.show` plugin shell, an explicitly registered dashboard child route, `DButton`, GJS templates, and BEM-style SCSS. The plugin does not add another breadcrumb or page subheader inside the shell because current Discourse already renders those elements.
- The same admin-only engine exposes a portal-launch redirect. It requests the established short-lived `/v1/site/portal` handoff server-side, validates that the returned URL is HTTPS on a Forum Fortress-owned host, and never exposes the API key to the browser.
- Discourse has no callback for removal of a plugin directory; current core explicitly notes that enable-setting callbacks do not run for code installation/removal. A conventional `forum_fortress:uninstall` Rake task therefore performs authenticated `/v1/site/deprovision` first and removes the plugin's local site-setting overrides only after remote confirmation. An explicit force flag permits local-only cleanup during an outage. Disabling remains reversible and does not deprovision the site.

## Alternatives rejected

- `user_created`, `post_created`, and `post_edited` events were rejected for blocking because they run after persistence.
- Controller monkey patches and patches to `UsersController`/`PostsController` were rejected because current modifiers, model validators, and `NewPostManager` provide narrower extension points. The small `PostRevisor` context prepend is the sole exception, for the combined title/body ordering limitation described above.
- A client-side API client or browser-exposed API key was rejected. All credentials and transport state stay in server-side settings.
- A job-only design was rejected for the pre-save checks: an asynchronous decision would allow a registration/post to become accepted or public before Forum Fortress responds.
- A bespoke local spam score, review state, confidence threshold, or challenge flow was rejected because these are not part of the established Forum Fortress plugin contract.

## Discourse-specific behaviour

- Personal messages are skipped, including replies to a PM topic. This matches the existing integrations’ privacy boundary.
- Staff, system, bot, and staged users are skipped. Public activity from ordinary users is checked even when it later enters Discourse’s normal approval/review flow.
- Email-created content is checked when it uses `NewPostManager`; staged-user email flows are skipped with the staged-user rule.
- Admin status rendering does not perform network I/O. The connection test is explicit and calls health plus site status. Check failures are fail-open by default, matching the established safety philosophy; fail-closed is an administrator choice.
- The client sends the current common contract fields and event-specific public content/profile fields only. It uses generic `/v1/site/bootstrap` for Discourse, regional check endpoints, the configured global fallback policy, and `/v1/site/status` for the admin probe.
- Generic bootstrap accepts the current short-lived `bootstrap_token` authorization for domains already known to Forum Fortress. Discourse stores it as an ordinary server-side setting only until bootstrap succeeds; no Discourse-specific recovery endpoint or credential format was invented.
- Generic first-time bootstrap has a separate 30-second bound because provisioning may traverse an edge and the control plane. The API now replays a stable identity while an anonymous forum remains unconfirmed, and the scheduled ten-minute heartbeat retries bootstrap then sends an authenticated ping. Normal anti-spam checks retain the short administrator-configured budget.
- A cached preferred endpoint is only reused within a selected non-global region; changing the region cannot silently send checks to the previous region. Global fallback remains opt-in.
- Edit checks require the explicit acting user set by `PostRevisor`; direct model saves without that context are skipped. Staff/system/bot/staged actors are skipped even when they edit an ordinary user's content.
- Each logical check receives one `check_request_id`, reused across regional fallback and stale-identity recovery. Transport, payload construction, and state-persistence failures all follow the configured fail-open policy; nonessential endpoint-state writes cannot turn an allowed Forum Fortress response into a rejected Discourse action.
- Identity recovery distinguishes a stale site identifier from an invalid key: `stale_site` keeps the valid key while clearing only site metadata, whereas authentication/key failures clear the unusable credential before re-bootstrap.

## Validation still needed on the real test instance

1. Exercise normal signup, API signup, email-auth/approval, SSO/OAuth signup, and an administrator-created user to confirm the `User` validator is reached at the intended lifecycle point.
2. Exercise topic creation, replies, queued posts, email posts, API posts, PMs, system/bot posts, and staged users; confirm only the intended payloads reach Forum Fortress.
3. Exercise body-only edits, title-only edits, combined title/body edits, staff edits, deleted/recovered posts, and edits from plugins that call `PostRevisor` directly.
4. Exercise bio/website/name/username changes through the normal profile UI and API, including clearing a field, and confirm no rendered HTML or signature data is sent.
5. Complete a signed-in visual pass on the deployed admin page. The automated frontend acceptance test now verifies the plugin-root redirect, single-dashboard rendering, absence of a duplicate inner page header, protection coverage, and connection-test success state.
6. Verify the API response/endpoint behaviour against the live Forum Fortress test account, especially anonymous bootstrap, stale-key recovery, regional fallback, and fail-open/fail-closed error presentation.
