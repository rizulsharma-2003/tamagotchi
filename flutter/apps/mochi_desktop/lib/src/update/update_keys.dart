// The release key's PUBLIC half, compiled into Mochi for Windows: every update's manifest must carry its signature.
//
// scripts/release-windows.sh fills this in on its first run, when it makes the key pair on the release Mac (the private
// half goes straight into that Mac's Keychain, service "mochi-windows-update-signing", and is never printed, written to
// the repo or put in the app). Later runs check that this still matches the Keychain's key. Empty: this build can't
// verify updates, so it never installs one.

/// base64url, 32 bytes.
const String windowsUpdatePublicKey = '';
