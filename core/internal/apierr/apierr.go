// Package apierr defines the error shape shared by the REST API and the C API
// (protocol §8): {"error":{"code":"…","message":"…"}}.
package apierr

import (
	"encoding/json"
	"errors"
	"net/http"
)

// Error is a protocol error. Status is the HTTP status for REST responses;
// C API-only codes use 0.
type Error struct {
	Status  int    `json:"-"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

// New returns an Error.
func New(status int, code, message string) *Error {
	return &Error{Status: status, Code: code, Message: message}
}

// REST codes (protocol §8).
func BadRequest(msg string) *Error { return New(http.StatusBadRequest, "bad_request", msg) }
func NotPaired() *Error {
	return New(http.StatusForbidden, "not_paired", "허용 목록에 없는 기기입니다.")
}
func PairCodeInvalid() *Error {
	return New(http.StatusForbidden, "pair_code_invalid", "페어링 코드가 없거나 맞지 않거나 만료되었습니다.")
}
func TokenInvalid() *Error {
	return New(http.StatusForbidden, "token_invalid", "세션 토큰이 맞지 않습니다.")
}
func BuildNotFound() *Error {
	return New(http.StatusNotFound, "build_not_found", "빌드가 없습니다.")
}
func BuildChanged() *Error {
	return New(http.StatusConflict, "build_changed", "게시 후 빌드 파일이 바뀌었습니다.")
}
func SessionExpired() *Error {
	return New(http.StatusGone, "session_expired", "세션이 만료되었거나 완료되었습니다.")
}
func NotDebugBuild(msg string) *Error {
	return New(http.StatusUnprocessableEntity, "not_debug_build", msg)
}
func TooManyAttempts() *Error {
	return New(http.StatusTooManyRequests, "too_many_attempts", "코드 시도 횟수를 넘었습니다. 새 코드를 여세요.")
}
func NotFound() *Error {
	return New(http.StatusNotFound, "not_found", "알 수 없는 경로입니다.")
}
func MethodNotAllowed() *Error {
	return New(http.StatusMethodNotAllowed, "method_not_allowed", "이 경로에서 지원하지 않는 메서드입니다.")
}
func Internal(msg string) *Error { return New(http.StatusInternalServerError, "internal", msg) }

// C API-only codes.
func InvalidConfig(msg string) *Error { return New(0, "invalid_config", msg) }
func NotRunning(msg string) *Error    { return New(0, "not_running", msg) }
func UnknownHandle() *Error           { return New(0, "unknown_handle", "알 수 없는 핸들입니다.") }
func PathOutsidePublishDir() *Error {
	return New(0, "path_outside_publish_dir", "IPA가 게시 폴더 안의 일반 파일이 아닙니다.")
}
func HashMismatch(msg string) *Error { return New(0, "hash_mismatch", msg) }

// From converts any error into an *Error (unknown errors become "internal").
func From(err error) *Error {
	var e *Error
	if errors.As(err, &e) {
		return e
	}
	return Internal(err.Error())
}

// JSON encodes err in the protocol error shape.
func JSON(err error) []byte {
	b, _ := json.Marshal(struct {
		Error *Error `json:"error"`
	}{From(err)})
	return b
}

// Write sends err as an HTTP JSON error response.
func Write(w http.ResponseWriter, err *Error) {
	status := err.Status
	if status == 0 {
		status = http.StatusInternalServerError
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(JSON(err))
}
