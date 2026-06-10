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
)

func main() {
	socketPath := flag.String("socket", daemon.DefaultSocketPath(), "Unix domain socket path")
	flag.Parse()

	listener, err := daemon.ListenUnix(*socketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pi-pet-daemon: listen: %v\n", err)
		os.Exit(1)
	}
	defer os.Remove(*socketPath)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	fmt.Printf("pi-pet-daemon listening on %s\n", *socketPath)
	server := daemon.NewServer(daemon.NewStore())
	if err := server.Serve(ctx, listener); err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, net.ErrClosed) {
		fmt.Fprintf(os.Stderr, "pi-pet-daemon: %v\n", err)
		os.Exit(1)
	}
}
