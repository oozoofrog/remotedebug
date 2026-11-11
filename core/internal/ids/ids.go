// Package ids generates pairing codes, session tokens and short identifiers.
package ids

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"strings"
)

// crockford is the Crockford base32 alphabet (no I, L, O, U).
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// PairCodeLen is the number of characters in a pairing code.
const PairCodeLen = 8

// NewPairCode returns an 8-character Crockford base32 code (40 bits of entropy).
func NewPairCode() string {
	var b [PairCodeLen]byte
	rand.Read(b[:])
	for i := range b {
		b[i] = crockford[b[i]&31] // 256 % 32 == 0, so this is uniform
	}
	return string(b[:])
}

// DisplayPairCode formats a code as K7M2-9QXD.
func DisplayPairCode(code string) string {
	if len(code) != PairCodeLen {
		return code
	}
	return code[:4] + "-" + code[4:]
}

// NormalizePairCode removes hyphens/spaces, upper-cases the input and applies
// Crockford decoding aliases (O→0, I/L→1). It returns "" if the result is not
// a well-formed code.
func NormalizePairCode(in string) string {
	var sb strings.Builder
	for _, r := range strings.ToUpper(in) {
		switch r {
		case '-', ' ':
			continue
		case 'O':
			r = '0'
		case 'I', 'L':
			r = '1'
		}
		if !strings.ContainsRune(crockford, r) {
			return ""
		}
		sb.WriteRune(r)
	}
	if sb.Len() != PairCodeLen {
		return ""
	}
	return sb.String()
}

// PairCodeEqual compares a stored code with user input in constant time.
func PairCodeEqual(stored, input string) bool {
	n := NormalizePairCode(input)
	return n != "" && subtle.ConstantTimeCompare([]byte(stored), []byte(n)) == 1
}

// NewToken returns 32 random bytes encoded as unpadded base64url (43 chars).
func NewToken() string {
	var b [32]byte
	rand.Read(b[:])
	return base64.RawURLEncoding.EncodeToString(b[:])
}

// NewID returns prefix + 8 random hex characters, e.g. "s_52d9a07e".
func NewID(prefix string) string {
	var b [4]byte
	rand.Read(b[:])
	return prefix + hex.EncodeToString(b[:])
}

// BuildID returns "b_" + first 8 hex chars of sha256(bundleId + "\n" + ipaSHA256).
func BuildID(bundleID, ipaSHA256 string) string {
	sum := sha256.Sum256([]byte(bundleID + "\n" + ipaSHA256))
	return "b_" + hex.EncodeToString(sum[:])[:8]
}

// HostID derives a stable host id from the node's StableID.
func HostID(stableID string) string {
	sum := sha256.Sum256([]byte("rd-host\n" + stableID))
	return "h_" + hex.EncodeToString(sum[:])[:8]
}
