# Changelog

## 1.0.4 - 2026-10-14

- Require three cleanup-certified BLOCKs within 24 hours and five or fewer
  actual forum posts in cleanup mode, including topic starters and restricted
  categories but excluding private messages and whispers; preserve the
  two-event, ten-post suspension-only mode.
- Keep cleanup evidence separate from suspension-only evidence.
- Repair the native topic query and exclude restricted categories, whispers,
  private messages, topic starters and other authors from reply cleanup.
- Commit native suspension/deletion and their durable receipts together; bind
  cleanup to the recorded native suspension timestamps, expiry, actor and staff
  history identity. Preserve moderator replacements and restored posts, and
  refuse cleanup based on legacy receipts without native ban identity.
- Lock and recheck the native account row before suspension and each deletion.
- Verify actual Discourse 2026.9.0 with 130 private RSpec examples, public 1.0.2
  upgrades preserving identity and selected ban-only mode, native uninstall,
  real Sidekiq queue and concurrent workers, rollback and moderator restoration.

## 1.0.3 - Unreleased (included in 1.0.4)

- Add an opt-in action to suspend a confirmed repeat spammer and soft-delete
  only their existing public replies through Discourse's native moderator
  service. Topic first posts, private messages, and other users' content are
  preserved; native staff logs and restore controls remain available.
- Keep the existing suspension-only setting unchanged for upgraded sites and
  keep new installations Off. Persist separate suspension, evidence, and
  cleanup receipts so interrupted cleanup can resume without repeating a ban.

## 1.0.2 - 2026-10-12

- Add optional, default-off native seven-day suspension after two independent
  high-confidence spam BLOCKs within 24 hours.
- Background job rechecks local settings and account eligibility, using local
  Redis deduplication and safe actor attribution.
- Existing site identities, routing and BLOCK decisions are unchanged.
  Account deletion and content purging remain out of scope.

## 1.0.1 - 2026-09-28

- Apply the upstream Syntax Tree format to the API client for green public CI.
- Keep runtime behaviour unchanged from 1.0.

## 1.0 - 2026-09-25

- First stable release of the Discourse plugin.
- Harden request routing, offline bootstrap recovery, failover boundaries,
  distributed identity recovery, and first-post edit validation for production
  use.
- Keep the plugin package and customer-facing release metadata aligned at 1.0.

## 0.2.0-alpha.2 - 2026-09-18

- Route lifecycle and bootstrap requests through the resilient public API path.

## 0.2.0-alpha.1 - 2026-09-11

- Use deterministic GeoDNS routing for every API operation: global requests
  fall back from `api.ffapi.net` to `fortress.ffapi.net`, while regional
  requests remain locked unless global fallback is enabled.
- Replace unauthenticated health probing with an authenticated heartbeat and
  limit standard-plan attempts to hourly while retaining ten-minute
  Pro/MultiMod check-ins.

## 0.1.0-alpha.3 - 2026-09-07

- First release licensed as free and open-source software under
  `GPL-2.0-or-later`; add the complete GPLv2 text, project notice and
  contribution terms while keeping hosted-service access separate.

- Exclude private messages and access-restricted category content from external
  topic, reply, body-edit, title-edit, and combined-edit checks.
- Resolve requested, default, current, and pending destination categories
  conservatively; skip external content checks when visibility is unresolved or
  either side of a content-bearing move is restricted.
- Preserve one request for eligible combined title/body edits and avoid adding
  checks for category-only moves.
- Add private transport-level privacy regression coverage and apply the configured
  Syntax Tree formatting to the two files that failed the `0.1.0-alpha.2` public
  CI run.
- Clarify synchronous timeouts, fail-open defaults, decision handling,
  moderation-queue limitations, identity data, and supported Discourse versions.

## 0.1.0-alpha.2 - 2026-08-28

- Start every normal request at the selected GeoDNS hostname and keep fallback
  success non-sticky so the next request immediately fails back to GeoDNS.
- Recover lost bootstrap responses from a ten-minute background heartbeat,
  including quiet forums with no protected traffic.
- Repair key-only identities through authenticated site status and immediately
  confirm a recovered bootstrap identity through site ping.
- Restore prior credentials when stale-identity recovery is interrupted.

## 0.1.0-alpha.1 - 2026-08-26

- First public alpha for current Discourse.
- Protects registrations, public topics and replies, supported public-content edits, and supported profile changes.
- Adds a native Discourse admin dashboard, connection test, regional routing controls, and secure portal login.
- Uses bounded synchronous checks with fail-open behaviour enabled by default.
- Excludes private messages and staff, system, bot, and staged-user activity.
