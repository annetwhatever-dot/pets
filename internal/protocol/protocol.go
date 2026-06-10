package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

const Version = 1

const (
	KindRequest  = "request"
	KindResponse = "response"
	KindEvent    = "event"
)

const (
	MethodHello            = "hello"
	MethodSnapshotGet      = "snapshot.get"
	MethodStateSubscribe   = "state.subscribe"
	MethodSessionUpsert    = "session.upsert"
	MethodSessionRemove    = "session.remove"
	MethodToolStart        = "tool.start"
	MethodToolUpdate       = "tool.update"
	MethodToolEnd          = "tool.end"
	MethodApprovalRequest  = "approval.request"
	MethodApprovalRespond  = "approval.respond"
	MethodPetSelect        = "pet.select"
	MethodInstalledPetsSet = "pets.installed.set"
	MethodCatalogSet       = "catalog.cache.set"

	EventSnapshot = "state.snapshot"
)

const (
	ClientPiExtension = "pi-extension"
	ClientOverlay     = "overlay"
	ClientBrowser     = "browser"
	ClientMock        = "mock"
)

type Message struct {
	Version int             `json:"version"`
	Kind    string          `json:"kind"`
	ID      string          `json:"id,omitempty"`
	Method  string          `json:"method"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Error   *Error          `json:"error,omitempty"`
}

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func NewRequest(id string, method string, payload any) (Message, error) {
	return newMessage(KindRequest, id, method, payload, nil)
}

func NewResponse(id string, method string, payload any) (Message, error) {
	return newMessage(KindResponse, id, method, payload, nil)
}

func NewErrorResponse(id string, method string, code string, message string) Message {
	return Message{
		Version: Version,
		Kind:    KindResponse,
		ID:      id,
		Method:  method,
		Error: &Error{
			Code:    code,
			Message: message,
		},
	}
}

func NewEvent(method string, payload any) (Message, error) {
	return newMessage(KindEvent, "", method, payload, nil)
}

func newMessage(kind string, id string, method string, payload any, msgErr *Error) (Message, error) {
	raw, err := MarshalPayload(payload)
	if err != nil {
		return Message{}, err
	}
	return Message{
		Version: Version,
		Kind:    kind,
		ID:      id,
		Method:  method,
		Payload: raw,
		Error:   msgErr,
	}, nil
}

func MarshalPayload(payload any) (json.RawMessage, error) {
	if payload == nil {
		return nil, nil
	}
	if raw, ok := payload.(json.RawMessage); ok {
		return raw, nil
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	return json.RawMessage(data), nil
}

func DecodePayload[T any](msg Message) (T, error) {
	var out T
	if len(msg.Payload) == 0 {
		return out, nil
	}
	if err := json.Unmarshal(msg.Payload, &out); err != nil {
		return out, err
	}
	return out, nil
}

func EncodeLine(msg Message) ([]byte, error) {
	if err := ValidateMessage(msg); err != nil {
		return nil, err
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return nil, err
	}
	data = append(data, '\n')
	return data, nil
}

func DecodeLine(line []byte) (Message, error) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return Message{}, errors.New("empty protocol line")
	}
	var msg Message
	if err := json.Unmarshal(line, &msg); err != nil {
		return Message{}, err
	}
	if err := ValidateMessage(msg); err != nil {
		return Message{}, err
	}
	return msg, nil
}

func ValidateMessage(msg Message) error {
	if msg.Version != Version {
		return fmt.Errorf("unsupported protocol version %d", msg.Version)
	}
	switch msg.Kind {
	case KindRequest:
		if strings.TrimSpace(msg.ID) == "" {
			return errors.New("request id is required")
		}
	case KindResponse:
		if strings.TrimSpace(msg.ID) == "" {
			return errors.New("response id is required")
		}
	case KindEvent:
	default:
		return fmt.Errorf("unsupported message kind %q", msg.Kind)
	}
	if strings.TrimSpace(msg.Method) == "" {
		return errors.New("method is required")
	}
	return nil
}

type Hello struct {
	Client string `json:"client"`
	Name   string `json:"name,omitempty"`
	PID    int    `json:"pid,omitempty"`
}

type SessionStatus string

const (
	SessionIdle         SessionStatus = "idle"
	SessionThinking     SessionStatus = "thinking"
	SessionRunning      SessionStatus = "running"
	SessionDone         SessionStatus = "done"
	SessionFailed       SessionStatus = "failed"
	SessionDisconnected SessionStatus = "disconnected"
)

type AttentionState string

const (
	AttentionIdle             AttentionState = "idle"
	AttentionThinking         AttentionState = "thinking"
	AttentionRunning          AttentionState = "running"
	AttentionDone             AttentionState = "done"
	AttentionFailed           AttentionState = "failed"
	AttentionApprovalRequired AttentionState = "approval_required"
)

type ToolState string

const (
	ToolRunning ToolState = "running"
	ToolDone    ToolState = "done"
	ToolFailed  ToolState = "failed"
)

type Session struct {
	ID          string        `json:"id"`
	CWD         string        `json:"cwd,omitempty"`
	Title       string        `json:"title,omitempty"`
	Status      SessionStatus `json:"status"`
	SafeSummary string        `json:"safeSummary,omitempty"`
	Tools       []ToolRun     `json:"tools,omitempty"`
	StartedAt   time.Time     `json:"startedAt"`
	UpdatedAt   time.Time     `json:"updatedAt"`
}

type ToolRun struct {
	ID          string    `json:"id"`
	SessionID   string    `json:"sessionId"`
	Name        string    `json:"name"`
	State       ToolState `json:"state"`
	SafeSummary string    `json:"safeSummary,omitempty"`
	StartedAt   time.Time `json:"startedAt"`
	EndedAt     time.Time `json:"endedAt,omitempty"`
}

type SessionUpsert struct {
	SessionID   string        `json:"sessionId"`
	CWD         string        `json:"cwd,omitempty"`
	Title       string        `json:"title,omitempty"`
	Status      SessionStatus `json:"status"`
	SafeSummary string        `json:"safeSummary,omitempty"`
}

type SessionRemove struct {
	SessionID string `json:"sessionId"`
}

type ToolUpdate struct {
	SessionID   string    `json:"sessionId"`
	ToolCallID  string    `json:"toolCallId"`
	ToolName    string    `json:"toolName"`
	State       ToolState `json:"state,omitempty"`
	SafeSummary string    `json:"safeSummary,omitempty"`
}

type ApprovalState string

const (
	ApprovalPending  ApprovalState = "pending"
	ApprovalApproved ApprovalState = "approved"
	ApprovalDenied   ApprovalState = "denied"
	ApprovalExpired  ApprovalState = "expired"
)

type ApprovalRequest struct {
	ApprovalID     string `json:"approvalId"`
	SessionID      string `json:"sessionId"`
	ToolCallID     string `json:"toolCallId,omitempty"`
	ToolName       string `json:"toolName"`
	CommandSummary string `json:"commandSummary,omitempty"`
	Risk           string `json:"risk,omitempty"`
	TimeoutMillis  int    `json:"timeoutMillis,omitempty"`
}

type PendingApproval struct {
	ID             string        `json:"id"`
	SessionID      string        `json:"sessionId"`
	ToolCallID     string        `json:"toolCallId,omitempty"`
	ToolName       string        `json:"toolName"`
	CommandSummary string        `json:"commandSummary,omitempty"`
	Risk           string        `json:"risk,omitempty"`
	State          ApprovalState `json:"state"`
	CreatedAt      time.Time     `json:"createdAt"`
	UpdatedAt      time.Time     `json:"updatedAt"`
}

type ApprovalDecision struct {
	ApprovalID string        `json:"approvalId"`
	Decision   ApprovalState `json:"decision"`
	Reason     string        `json:"reason,omitempty"`
}

type PetRef struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	Source      string `json:"source"`
	Path        string `json:"path,omitempty"`
	License     string `json:"license,omitempty"`
	Attribution string `json:"attribution,omitempty"`
}

type InstalledPetsSet struct {
	Pets []PetRef `json:"pets"`
}

type PetSelect struct {
	PetID string `json:"petId"`
}

type CatalogCache struct {
	Provider  string    `json:"provider"`
	UpdatedAt time.Time `json:"updatedAt"`
	Pets      []PetRef  `json:"pets"`
	Error     string    `json:"error,omitempty"`
}

type Snapshot struct {
	Attention        AttentionState          `json:"attention"`
	Sessions         []Session               `json:"sessions"`
	PendingApprovals []PendingApproval       `json:"pendingApprovals"`
	SelectedPetID    string                  `json:"selectedPetId,omitempty"`
	InstalledPets    []PetRef                `json:"installedPets"`
	Catalogs         map[string]CatalogCache `json:"catalogs"`
	UpdatedAt        time.Time               `json:"updatedAt"`
}

func NormalizeStatus(status SessionStatus) SessionStatus {
	switch status {
	case SessionIdle, SessionThinking, SessionRunning, SessionDone, SessionFailed, SessionDisconnected:
		return status
	default:
		return SessionIdle
	}
}

func NormalizeToolState(state ToolState) ToolState {
	switch state {
	case ToolRunning, ToolDone, ToolFailed:
		return state
	default:
		return ToolRunning
	}
}

func NormalizeDecision(state ApprovalState) (ApprovalState, bool) {
	switch state {
	case ApprovalApproved, ApprovalDenied:
		return state, true
	default:
		return "", false
	}
}
