//go:build !darwin

package host

func cloneFile(src, dst string) error { return copyFile(src, dst) }
