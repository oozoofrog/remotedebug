# Store feedback diagnostics keys in the data protection keychain

## Context

The `AFDIAG1` header includes an eight-byte fingerprint of the recipient public key. The previous Mac app read every private key from its file-based keychain service before matching that fingerprint. Access to a single unrelated item could block an import. Legacy items contain an account label and a private key. Their attributes contain no public fingerprint.

## Decision

- Store each private key as a generic password in the data protection keychain. Limit access to RemoteDebug's provisioned, app-specific keychain access group. Debug and Developer ID builds MUST use the same group to share keys on the same macOS account.
- Store the fingerprint in the item's generic attribute. To open a file, match that attribute and read one private key. Verify the fingerprint against the derived public key before decryption.
- Keep file-based keychain migration separate from opening attachments. During explicit migration, copy each missing account, read back the copy, and compare public-key fingerprints. Preserve the original item to support recovery and rollback. If access is denied or a copy fails, retain the original. A retry skips verified copies. Creating a project key MUST preserve an existing legacy key when one is present. The migration also accepts app-specific legacy services ending in ` feedback diagnostics` when the account holds the 16-digit hexadecimal fingerprint. It validates that fingerprint before copying.
- Pass MCP imports to the running Mac app. Return only the saved record ID or a failure message. An authorized local agent can read the resulting record with `remotedebug_crash_logs`.

## Consequences

Existing attachments continue to require their original private keys. An unknown fingerprint performs no legacy key read. Migration may require one approval per pending legacy item. Rebuilds that retain the same access group use the migrated copy. The keychain group does not synchronize keys between Macs. Decrypted records follow the local crash and feedback store's existing retention rules.
