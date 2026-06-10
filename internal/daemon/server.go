package daemon

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"codex-pets/internal/protocol"
)

type Server struct {
	store *Store

	mu          sync.Mutex
	subscribers map[*subscriber]struct{}
}

type subscriber struct {
	write func(protocol.Message) error
}

func NewServer(store *Store) *Server {
	if store == nil {
		store = NewStore()
	}
	return &Server{
		store:       store,
		subscribers: map[*subscriber]struct{}{},
	}
}

func DefaultSocketPath() string {
	runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeDir == "" {
		runtimeDir = filepath.Join(os.TempDir(), fmt.Sprintf("codex-pets-%d", os.Getuid()))
	}
	return filepath.Join(runtimeDir, "pi-pet.sock")
}

func ListenUnix(path string) (net.Listener, error) {
	if path == "" {
		path = DefaultSocketPath()
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	_ = os.Chmod(path, 0o600)
	return listener, nil
}

func (s *Server) Serve(ctx context.Context, listener net.Listener) error {
	errCh := make(chan error, 1)
	go func() {
		errCh <- s.acceptLoop(listener)
	}()
	select {
	case <-ctx.Done():
		_ = listener.Close()
		if err := <-errCh; err != nil && !errors.Is(err, net.ErrClosed) {
			return err
		}
		return ctx.Err()
	case err := <-errCh:
		return err
	}
}

func (s *Server) acceptLoop(listener net.Listener) error {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return err
		}
		go s.handleConn(conn)
	}
}

func (s *Server) handleConn(conn net.Conn) {
	defer conn.Close()

	var writeMu sync.Mutex
	write := func(msg protocol.Message) error {
		line, err := protocol.EncodeLine(msg)
		if err != nil {
			return err
		}
		writeMu.Lock()
		defer writeMu.Unlock()
		_, err = conn.Write(line)
		return err
	}

	var sub *subscriber
	defer func() {
		if sub != nil {
			s.removeSubscriber(sub)
		}
	}()

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		msg, err := protocol.DecodeLine(scanner.Bytes())
		if err != nil {
			_ = write(protocol.NewErrorResponse("", "unknown", "bad_message", err.Error()))
			continue
		}
		if msg.Kind != protocol.KindRequest {
			_ = write(protocol.NewErrorResponse(msg.ID, msg.Method, "bad_kind", "only request messages are accepted"))
			continue
		}
		keepSub, err := s.handleRequest(msg, write, &sub)
		if err != nil {
			_ = write(protocol.NewErrorResponse(msg.ID, msg.Method, "request_failed", err.Error()))
		}
		if !keepSub && sub != nil {
			s.removeSubscriber(sub)
			sub = nil
		}
	}
}

func (s *Server) handleRequest(
	msg protocol.Message,
	write func(protocol.Message) error,
	sub **subscriber,
) (bool, error) {
	switch msg.Method {
	case protocol.MethodHello:
		payload, err := protocol.DecodePayload[protocol.Hello](msg)
		if err != nil {
			return true, err
		}
		if payload.Client == "" {
			payload.Client = protocol.ClientMock
		}
		return true, writeResponse(write, msg, map[string]any{"ok": true, "server": "pi-pet-daemon", "version": protocol.Version})
	case protocol.MethodSnapshotGet:
		return true, writeResponse(write, msg, s.store.Snapshot())
	case protocol.MethodStateSubscribe:
		if *sub == nil {
			created := &subscriber{write: write}
			*sub = created
			s.addSubscriber(created)
		}
		return true, writeResponse(write, msg, s.store.Snapshot())
	case protocol.MethodSessionUpsert:
		payload, err := protocol.DecodePayload[protocol.SessionUpsert](msg)
		if err != nil {
			return true, err
		}
		snapshot := s.store.UpsertSession(payload)
		s.broadcast(snapshot)
		return true, writeResponse(write, msg, snapshot)
	case protocol.MethodSessionRemove:
		payload, err := protocol.DecodePayload[protocol.SessionRemove](msg)
		if err != nil {
			return true, err
		}
		snapshot := s.store.RemoveSession(payload)
		s.broadcast(snapshot)
		return true, writeResponse(write, msg, snapshot)
	case protocol.MethodToolStart:
		payload, err := protocol.DecodePayload[protocol.ToolUpdate](msg)
		if err != nil {
			return true, err
		}
		snapshot := s.store.ToolStart(payload)
		s.broadcast(snapshot)
		return true, writeResponse(write, msg, snapshot)
	case protocol.MethodToolUpdate:
		payload, err := protocol.DecodePayload[protocol.ToolUpdate](msg)
		if err != nil {
			return true, err
		}
		snapshot := s.store.ToolUpdate(payload)
		s.broadcast(snapshot)
		return true, writeResponse(write, msg, snapshot)
	case protocol.MethodToolEnd:
		payload, err := protocol.DecodePayload[protocol.ToolUpdate](msg)
		if err != nil {
			return true, err
		}
		snapshot := s.store.ToolEnd(payload)
		s.broadcast(snapshot)
		return true, writeResponse(write, msg, snapshot)
	case protocol.MethodApprovalRequest:
		payload, err := protocol.DecodePayload[protocol.ApprovalRequest](msg)
		if err != nil {
			return true, err
		}
		_, decisions, snapshot := s.store.AddApproval(payload)
		s.broadcast(snapshot)
		decision := s.waitForApproval(payload, decisions)
		if decision.Decision == protocol.ApprovalExpired {
			if ok, snapshot := s.store.ExpireApproval(decision.ApprovalID); ok {
				s.broadcast(snapshot)
			}
		}
		return true, writeResponse(write, msg, decision)
	case protocol.MethodApprovalRespond:
		payload, err := protocol.DecodePayload[protocol.ApprovalDecision](msg)
		if err != nil {
			return true, err
		}
		decision, ok, snapshot := s.store.ResolveApproval(payload)
		if !ok {
			return true, write(protocol.NewErrorResponse(msg.ID, msg.Method, "approval_not_found", "approval is not pending"))
		}
		s.broadcast(snapshot)
		return true, writeResponse(write, msg, decision)
	case protocol.MethodPetSelect:
		payload, err := protocol.DecodePayload[protocol.PetSelect](msg)
		if err != nil {
			return true, err
		}
		snapshot := s.store.SelectPet(payload)
		s.broadcast(snapshot)
		return true, writeResponse(write, msg, snapshot)
	case protocol.MethodInstalledPetsSet:
		payload, err := protocol.DecodePayload[protocol.InstalledPetsSet](msg)
		if err != nil {
			return true, err
		}
		snapshot := s.store.SetInstalledPets(payload)
		s.broadcast(snapshot)
		return true, writeResponse(write, msg, snapshot)
	case protocol.MethodCatalogSet:
		payload, err := protocol.DecodePayload[protocol.CatalogCache](msg)
		if err != nil {
			return true, err
		}
		snapshot := s.store.SetCatalog(payload)
		s.broadcast(snapshot)
		return true, writeResponse(write, msg, snapshot)
	default:
		return true, write(protocol.NewErrorResponse(msg.ID, msg.Method, "unknown_method", "method is not supported"))
	}
}

func (s *Server) waitForApproval(input protocol.ApprovalRequest, decisions <-chan protocol.ApprovalDecision) protocol.ApprovalDecision {
	timeout := 10 * time.Minute
	if input.TimeoutMillis > 0 {
		timeout = time.Duration(input.TimeoutMillis) * time.Millisecond
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case decision, ok := <-decisions:
		if ok {
			return decision
		}
	case <-timer.C:
	}
	id := input.ApprovalID
	if id == "" {
		id = input.SessionID + ":" + input.ToolCallID
	}
	return protocol.ApprovalDecision{ApprovalID: id, Decision: protocol.ApprovalExpired, Reason: "approval timed out"}
}

func (s *Server) addSubscriber(sub *subscriber) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.subscribers[sub] = struct{}{}
}

func (s *Server) removeSubscriber(sub *subscriber) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.subscribers, sub)
}

func (s *Server) broadcast(snapshot protocol.Snapshot) {
	event, err := protocol.NewEvent(protocol.EventSnapshot, snapshot)
	if err != nil {
		return
	}
	s.mu.Lock()
	subscribers := make([]*subscriber, 0, len(s.subscribers))
	for sub := range s.subscribers {
		subscribers = append(subscribers, sub)
	}
	s.mu.Unlock()
	for _, sub := range subscribers {
		if err := sub.write(event); err != nil {
			s.removeSubscriber(sub)
		}
	}
}

func writeResponse(write func(protocol.Message) error, request protocol.Message, payload any) error {
	response, err := protocol.NewResponse(request.ID, request.Method, payload)
	if err != nil {
		return err
	}
	return write(response)
}

func ReadMessage(r io.Reader) (protocol.Message, error) {
	reader := bufio.NewReader(r)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		return protocol.Message{}, err
	}
	return protocol.DecodeLine(line)
}
