# Held changes (not active in app)

These edits were **removed from the running codebase** so you can test/compare,
but kept here so you can restore them anytime.

## Files

| File | Description |
|------|-------------|
| `nominee-submit-and-diagnostics.patch` | Nominee kyc-post: all step fields as blank strings, multipart empty send, payload diagnostics logs |

## What the patch includes (older experiment — do not apply as-is)

- `buildNomineeKycPostV2Body` — sent **all** step fields blank (91 keys); backend still routed to `additional_nominee`
- Full blank payload is **not** the legacy web behaviour

## Active fix (in app now)

- Pehle jaisa: `filterKycPostV2BodyForStep` — sirf filled + visible fields
- `syncExtraNomineeSubmitPayload` — 100% par `extra_nominee: ''` force
- `filterKycPostV2BodyForStep` — `extra_nominee` empty string allow
- Multipart: `shouldSendEmptyNomineeKycPostField` — sirf `extra_nominee`, `total_nominee_percentage`, etc. blank bhejte hain (saari nominee2 keys nahi)

## Restore (when you need it again)

From repo root:

```bash
git apply docs/held/nominee-submit-and-diagnostics.patch
```

If apply fails due to drift:

```bash
git apply --3way docs/held/nominee-submit-and-diagnostics.patch
```

## Revert again (disable without deleting hold)

```bash
git checkout -- lib/pages/home_page.dart lib/utils/field_validators.dart
# then re-save patch if you changed those files:
# git diff lib/pages/home_page.dart lib/utils/field_validators.dart > docs/held/nominee-submit-and-diagnostics.patch
```

## Note

Guardian PAN/Aadhaar validation fix (`_guardianBlockVisibleForSlot`, etc.) was **not** in this patch;
it remains in `lib/utils/field_validators.dart` from an earlier commit. Say if you want that held separately too.
