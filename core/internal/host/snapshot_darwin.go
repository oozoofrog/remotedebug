package host

import "golang.org/x/sys/unix"

// cloneFile makes dst an APFS clone of src, falling back to a copy when the
// volume cannot clone.
func cloneFile(src, dst string) error {
	if unix.Clonefile(src, dst, unix.CLONE_NOFOLLOW) == nil {
		return nil
	}
	return copyFile(src, dst)
}
