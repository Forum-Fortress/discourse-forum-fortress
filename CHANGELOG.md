# Changelog

## 0.1.0-alpha.2 - 2026-08-28

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
