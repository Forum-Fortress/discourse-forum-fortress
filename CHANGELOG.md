# Changelog

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
