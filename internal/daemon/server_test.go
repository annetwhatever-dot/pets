package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	petoverlay "codex-pets/internal/overlay"
	"codex-pets/internal/protocol"
)

type testClient struct {
	conn   net.Conn
	reader *bufio.Reader
}

func newTestClient(t *testing.T, socketPath string) *testClient {
	t.Helper()
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial daemon: %v", err)
	}
	return &testClient{conn: conn, reader: bufio.NewReader(conn)}
}

func (c *testClient) close() {
	_ = c.conn.Close()
}

func (c *testClient) request(t *testing.T, id string, method string, payload any) protocol.Message {
	t.Helper()
	msg, err := protocol.NewRequest(id, method, payload)
	if err != nil {
		t.Fatalf("request message: %v", err)
	}
	line, err := protocol.EncodeLine(msg)
	if err != nil {
		t.Fatalf("encode request: %v", err)
	}
	if _, err := c.conn.Write(line); err != nil {
		t.Fatalf("write request: %v", err)
	}
	return c.read(t)
}

func (c *testClient) read(t *testing.T) protocol.Message {
	t.Helper()
	line, err := c.reader.ReadBytes('\n')
	if err != nil {
		t.Fatalf("read message: %v", err)
	}
	msg, err := protocol.DecodeLine(line)
	if err != nil {
		t.Fatalf("decode response: %v\n%s", err, line)
	}
	if msg.Error != nil {
		t.Fatalf("protocol error: %s: %s", msg.Error.Code, msg.Error.Message)
	}
	return msg
}

func startTestServer(t *testing.T) (string, context.CancelFunc) {
	t.Helper()
	socketDir, err := os.MkdirTemp("/tmp", "pi-pet-test-")
	if err != nil {
		t.Fatalf("temp socket dir: %v", err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(socketDir)
	})
	socketPath := filepath.Join(socketDir, "pi.sock")
	listener, err := ListenUnix(socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	server := NewServer(NewStore())
	errCh := make(chan error, 1)
	go func() {
		errCh <- server.Serve(ctx, listener)
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-errCh:
		case <-time.After(time.Second):
			t.Fatal("server did not stop")
		}
	})
	return socketPath, cancel
}

func TestPiExtensionDaemonOverlayStateFlow(t *testing.T) {
	socketPath, _ := startTestServer(t)
	overlay := newTestClient(t, socketPath)
	defer overlay.close()
	extension := newTestClient(t, socketPath)
	defer extension.close()

	subscribe := overlay.request(t, "sub", protocol.MethodStateSubscribe, nil)
	var initial protocol.Snapshot
	if err := json.Unmarshal(subscribe.Payload, &initial); err != nil {
		t.Fatalf("decode initial snapshot: %v", err)
	}
	if initial.Attention != protocol.AttentionIdle {
		t.Fatalf("initial attention = %s, want idle", initial.Attention)
	}

	extension.request(t, "s1", protocol.MethodSessionUpsert, protocol.SessionUpsert{
		SessionID:   "pi-session-1",
		CWD:         "/repo",
		Title:       "Implement feature",
		Status:      protocol.SessionRunning,
		SafeSummary: "agent running",
	})

	event := overlay.read(t)
	if event.Kind != protocol.KindEvent || event.Method != protocol.EventSnapshot {
		t.Fatalf("unexpected event: %+v", event)
	}
	var snapshot protocol.Snapshot
	if err := json.Unmarshal(event.Payload, &snapshot); err != nil {
		t.Fatalf("decode event snapshot: %v", err)
	}
	if snapshot.Attention != protocol.AttentionRunning {
		t.Fatalf("attention = %s, want running", snapshot.Attention)
	}
	if presentation := petoverlay.Present(snapshot); presentation.StateID != "running" {
		t.Fatalf("overlay state = %s, want running", presentation.StateID)
	}
	if len(snapshot.Sessions) != 1 || snapshot.Sessions[0].ID != "pi-session-1" {
		t.Fatalf("sessions = %+v", snapshot.Sessions)
	}
}

func TestToolUpdateMethodRefreshesRunningTool(t *testing.T) {
	socketPath, _ := startTestServer(t)
	extension := newTestClient(t, socketPath)
	defer extension.close()

	extension.request(t, "tool-start", protocol.MethodToolStart, protocol.ToolUpdate{
		SessionID:   "pi-session-1",
		ToolCallID:  "tool-1",
		ToolName:    "bash",
		SafeSummary: "bash started",
	})
	response := extension.request(t, "tool-update", protocol.MethodToolUpdate, protocol.ToolUpdate{
		SessionID:   "pi-session-1",
		ToolCallID:  "tool-1",
		ToolName:    "bash",
		SafeSummary: "bash running",
	})

	var snapshot protocol.Snapshot
	if err := json.Unmarshal(response.Payload, &snapshot); err != nil {
		t.Fatalf("decode tool update snapshot: %v", err)
	}
	if len(snapshot.Sessions) != 1 || len(snapshot.Sessions[0].Tools) != 1 {
		t.Fatalf("snapshot tools = %+v", snapshot.Sessions)
	}
	tool := snapshot.Sessions[0].Tools[0]
	if tool.State != protocol.ToolRunning || tool.SafeSummary != "bash running" {
		t.Fatalf("tool after update = %+v, want running progress summary", tool)
	}
}

func TestApprovalRequestBlocksUntilBrowserResponse(t *testing.T) {
	socketPath, _ := startTestServer(t)
	extension := newTestClient(t, socketPath)
	defer extension.close()
	browser := newTestClient(t, socketPath)
	defer browser.close()

	resultCh := make(chan protocol.Message, 1)
	go func() {
		resultCh <- extension.request(t, "approval", protocol.MethodApprovalRequest, protocol.ApprovalRequest{
			ApprovalID:     "approval-1",
			SessionID:      "pi-session-1",
			ToolCallID:     "tool-1",
			ToolName:       "bash",
			CommandSummary: "git status --short",
			Risk:           "read-only",
			TimeoutMillis:  5000,
		})
	}()

	deadline := time.After(1500 * time.Millisecond)
	for {
		snapshotResponse := browser.request(t, "snapshot", protocol.MethodSnapshotGet, nil)
		var snapshot protocol.Snapshot
		if err := json.Unmarshal(snapshotResponse.Payload, &snapshot); err != nil {
			t.Fatalf("decode snapshot: %v", err)
		}
		if len(snapshot.PendingApprovals) == 1 {
			break
		}
		select {
		case <-deadline:
			t.Fatal("approval request did not become pending")
		case <-time.After(20 * time.Millisecond):
		}
	}

	browser.request(t, "respond", protocol.MethodApprovalRespond, protocol.ApprovalDecision{
		ApprovalID: "approval-1",
		Decision:   protocol.ApprovalApproved,
		Reason:     "safe read",
	})

	select {
	case msg := <-resultCh:
		var decision protocol.ApprovalDecision
		if err := json.Unmarshal(msg.Payload, &decision); err != nil {
			t.Fatalf("decode decision: %v", err)
		}
		if decision.Decision != protocol.ApprovalApproved {
			t.Fatalf("decision = %s, want approved", decision.Decision)
		}
	case <-time.After(time.Second):
		t.Fatal("extension did not receive approval response")
	}
}
