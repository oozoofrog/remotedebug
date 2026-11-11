package node

import (
	"os"
	"sync"
)

// rotatingFile is the logPath writer. When a write would grow the file past
// max bytes, the file is renamed to <path>.1 (replacing an older one) and a
// new file is started, so logs use at most about 2*max bytes.
type rotatingFile struct {
	mu   sync.Mutex
	path string
	max  int64
	f    *os.File // nil after a failed reopen: writes are dropped
	size int64
}

func openRotatingFile(path string, max int64) (*rotatingFile, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return nil, err
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	return &rotatingFile{path: path, max: max, f: f, size: fi.Size()}, nil
}

func (r *rotatingFile) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f != nil && r.size > 0 && r.size+int64(len(p)) > r.max {
		r.f.Close()
		os.Rename(r.path, r.path+".1")
		r.f, _ = os.OpenFile(r.path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		r.size = 0
	}
	if r.f == nil {
		return len(p), nil
	}
	n, err := r.f.Write(p)
	r.size += int64(n)
	return n, err
}

func (r *rotatingFile) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil {
		return nil
	}
	err := r.f.Close()
	r.f = nil
	return err
}
