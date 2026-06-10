//go:build !linux || !cgo

package x11overlay

import (
	"context"
	"errors"
)

var ErrUnsupported = errors.New("Linux X11 overlay requires linux, cgo, and libX11 development headers")

func Run(context.Context, string) error {
	return ErrUnsupported
}

func Supported() bool {
	return false
}
