# QuickCue sync readiness

Stage 21 does **not** claim that CloudKit sync is implemented or validated.
The current target has an empty entitlements file, and a personally sideloaded
IPA cannot prove CloudKit behavior on two devices. Local mode and the stage 20
backup/restore path remain independent and functional.

Before implementation, a release owner must provide and verify:

1. An Apple Team and provisioning profile with iCloud + CloudKit enabled.
2. A dedicated production/development CloudKit container and schema policy.
3. At least two signed physical-device installations using an accessible
   iCloud account. Simulator compilation is not acceptance evidence.
4. An explicit in-app opt-in disclosure naming text, profiles, attachments,
   photos, schedules and practice data. Keychain secrets, audio and diagnostics
   remain excluded.

The future implementation must keep stable record IDs and schema versions,
resolve edits with per-record revisions and timestamps, retain deletion
tombstones until all peers acknowledge them, queue bounded offline changes,
deduplicate retries, handle logout/quota/account changes, and transfer photos
separately with integrity checks. Historical SwiftData schemas must remain
frozen. Acceptance requires offline→online, concurrent edit, delete, retry,
logout, unavailable-cloud and large-photo tests on signed devices.
