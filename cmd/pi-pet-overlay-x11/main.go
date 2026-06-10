package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"

	"codex-pets/internal/daemon"
	"codex-pets/internal/piinstall"
	"codex-pets/internal/x11overlay"
)

func main() {
	socketPath := flag.String("socket", daemon.DefaultSocketPath(), "Pi Pet daemon Unix socket path")
	installPiExtension := flag.Bool("install-pi-extension", false, "Install the Pi extension into ~/.pi/agent/extensions and exit")
	piExtensionSource := flag.String("pi-extension-source", "", "Pi extension source file for -install-pi-extension")
	piExtensionDir := flag.String("pi-extension-dir", "", "Pi extension install directory for -install-pi-extension")
	flag.Parse()

	if *installPiExtension {
		installedPath, err := piinstall.Install(piinstall.Options{
			SourcePath:     *piExtensionSource,
			DestinationDir: *piExtensionDir,
		})
		if err != nil {
			fmt.Fprintf(os.Stderr, "pi-pet-overlay-x11: install Pi extension: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Installed Pi extension to %s\n", installedPath)
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	listener, err := daemon.ListenUnix(*socketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pi-pet-overlay-x11: daemon listen: %v\n", err)
		os.Exit(1)
	}
	defer os.Remove(*socketPath)

	daemonErr := make(chan error, 1)
	server := daemon.NewServer(daemon.NewStore())
	go func() {
		daemonErr <- server.Serve(ctx, listener)
	}()

	overlayErr := make(chan error, 1)
	go func() {
		overlayErr <- x11overlay.Run(ctx, *socketPath)
	}()

	select {
	case err := <-overlayErr:
		stop()
		if !isExpectedShutdown(err) {
			fmt.Fprintf(os.Stderr, "pi-pet-overlay-x11: %v\n", err)
			os.Exit(1)
		}
	case err := <-daemonErr:
		stop()
		if !isExpectedShutdown(err) {
			fmt.Fprintf(os.Stderr, "pi-pet-overlay-x11: daemon: %v\n", err)
			os.Exit(1)
		}
	}
}

func isExpectedShutdown(err error) bool {
	return err == nil || errors.Is(err, context.Canceled) || errors.Is(err, net.ErrClosed)
}
