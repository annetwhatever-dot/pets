//go:build linux && cgo

package x11overlay

/*
#cgo linux LDFLAGS: -lX11
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	Display* display;
	int screen;
	Window window;
	GC gc;
	Visual* visual;
	int depth;
	unsigned long red_mask;
	unsigned long green_mask;
	unsigned long blue_mask;
	int byte_order;
	int x;
	int y;
} PetX11;

typedef struct {
	int event_type;
	int x;
	int y;
	int x_root;
	int y_root;
	unsigned int button;
} PetX11Event;

#define PET_EVENT_BUTTON_PRESS 1
#define PET_EVENT_BUTTON_RELEASE 2
#define PET_EVENT_MOTION 3
#define PET_EVENT_EXPOSE 4

static PetX11* pet_x11_open(int width, int height) {
	XInitThreads();
	Display* display = XOpenDisplay(NULL);
	if (!display) return NULL;
	int screen = DefaultScreen(display);
	Window root = RootWindow(display, screen);
	Visual* visual = DefaultVisual(display, screen);
	int depth = DefaultDepth(display, screen);

	XSetWindowAttributes attrs;
	attrs.override_redirect = True;
	attrs.background_pixel = WhitePixel(display, screen);
	attrs.event_mask = ExposureMask | StructureNotifyMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask;

	int x = DisplayWidth(display, screen) - width - 32;
	int y = DisplayHeight(display, screen) - height - 64;
	if (x < 0) x = 0;
	if (y < 0) y = 0;

	Window window = XCreateWindow(
		display, root, x, y, width, height, 0, depth, InputOutput, visual,
		CWOverrideRedirect | CWBackPixel | CWEventMask, &attrs
	);
	XStoreName(display, window, "Pi Pet");

	Atom state = XInternAtom(display, "_NET_WM_STATE", False);
	Atom above = XInternAtom(display, "_NET_WM_STATE_ABOVE", False);
	XChangeProperty(display, window, state, XA_ATOM, 32, PropModeReplace, (unsigned char*)&above, 1);

	GC gc = XCreateGC(display, window, 0, NULL);
	XMapRaised(display, window);
	XFlush(display);

	PetX11* pet = (PetX11*)calloc(1, sizeof(PetX11));
	pet->display = display;
	pet->screen = screen;
	pet->window = window;
	pet->gc = gc;
	pet->visual = visual;
	pet->depth = depth;
	pet->red_mask = visual->red_mask;
	pet->green_mask = visual->green_mask;
	pet->blue_mask = visual->blue_mask;
	pet->byte_order = ImageByteOrder(display);
	pet->x = x;
	pet->y = y;
	return pet;
}

static void pet_x11_close(PetX11* pet) {
	if (!pet) return;
	XFreeGC(pet->display, pet->gc);
	XDestroyWindow(pet->display, pet->window);
	XCloseDisplay(pet->display);
	free(pet);
}

static unsigned long pet_x11_white(PetX11* pet) { return WhitePixel(pet->display, pet->screen); }
static unsigned long pet_x11_black(PetX11* pet) { return BlackPixel(pet->display, pet->screen); }

static void pet_x11_clear(PetX11* pet) {
	XSetForeground(pet->display, pet->gc, pet_x11_white(pet));
	XFillRectangle(pet->display, pet->window, pet->gc, 0, 0, 240, 300);
}

static void pet_x11_raise(PetX11* pet) {
	XRaiseWindow(pet->display, pet->window);
	XFlush(pet->display);
}

static void pet_x11_move_by(PetX11* pet, int dx, int dy) {
	pet->x += dx;
	pet->y += dy;
	XMoveWindow(pet->display, pet->window, pet->x, pet->y);
	XFlush(pet->display);
}

static int pet_x11_next_event(PetX11* pet, PetX11Event* out) {
	if (!pet || XPending(pet->display) <= 0) return 0;
	XEvent event;
	XNextEvent(pet->display, &event);
	memset(out, 0, sizeof(PetX11Event));
	switch (event.type) {
	case ButtonPress:
		out->event_type = PET_EVENT_BUTTON_PRESS;
		out->x = event.xbutton.x;
		out->y = event.xbutton.y;
		out->x_root = event.xbutton.x_root;
		out->y_root = event.xbutton.y_root;
		out->button = event.xbutton.button;
		return 1;
	case ButtonRelease:
		out->event_type = PET_EVENT_BUTTON_RELEASE;
		out->x = event.xbutton.x;
		out->y = event.xbutton.y;
		out->x_root = event.xbutton.x_root;
		out->y_root = event.xbutton.y_root;
		out->button = event.xbutton.button;
		return 1;
	case MotionNotify:
		out->event_type = PET_EVENT_MOTION;
		out->x = event.xmotion.x;
		out->y = event.xmotion.y;
		out->x_root = event.xmotion.x_root;
		out->y_root = event.xmotion.y_root;
		return 1;
	case Expose:
		out->event_type = PET_EVENT_EXPOSE;
		return 1;
	default:
		return 1;
	}
}

static void pet_x11_draw_text(PetX11* pet, int x, int y, const char* text) {
	XSetForeground(pet->display, pet->gc, pet_x11_black(pet));
	XDrawString(pet->display, pet->window, pet->gc, x, y, text, strlen(text));
}

static XImage* pet_x11_create_image(PetX11* pet, int width, int height) {
	XImage* image = XCreateImage(pet->display, pet->visual, pet->depth, ZPixmap, 0, NULL, width, height, 32, 0);
	if (!image) return NULL;
	image->data = (char*)calloc(1, image->bytes_per_line * height);
	if (!image->data) {
		XDestroyImage(image);
		return NULL;
	}
	return image;
}

static char* pet_x11_image_data(XImage* image) { return image->data; }
static int pet_x11_image_bytes_per_line(XImage* image) { return image->bytes_per_line; }
static int pet_x11_image_bits_per_pixel(XImage* image) { return image->bits_per_pixel; }

static void pet_x11_put_image(PetX11* pet, XImage* image, int x, int y) {
	XPutImage(pet->display, pet->window, pet->gc, image, 0, 0, x, y, image->width, image->height);
	XFlush(pet->display);
}

static void pet_x11_destroy_image(XImage* image) {
	if (!image) return;
	if (image->data) {
		free(image->data);
		image->data = NULL;
	}
	XDestroyImage(image);
}
*/
import "C"

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"net"
	"time"
	"unsafe"

	"codex-pets/internal/overlay"
	"codex-pets/internal/protocol"
)

func Run(ctx context.Context, socketPath string) error {
	x11 := C.pet_x11_open(C.int(windowWidth), C.int(windowHeight))
	if x11 == nil {
		return errors.New("could not open X11 display")
	}
	defer C.pet_x11_close(x11)

	snapshots := make(chan protocol.Snapshot, 8)
	go subscribeSnapshots(ctx, socketPath, snapshots)

	presentation := overlay.Presentation{StateID: "idle", Bubble: "Waiting for Pi Pet daemon"}
	var sheet *spriteSheet
	var frame int
	ticker := time.NewTicker(180 * time.Millisecond)
	defer ticker.Stop()
	eventTicker := time.NewTicker(16 * time.Millisecond)
	defer eventTicker.Stop()
	drag := dragInteraction{stateID: "running-right"}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case snapshot := <-snapshots:
			next := overlay.Present(snapshot)
			if next.SelectedPetPath != presentation.SelectedPetPath {
				sheet = loadSpriteSheet(next.SelectedPetPath)
				frame = 0
			}
			presentation = next
			render(x11, dragPresentation(presentation, drag), sheet, frame)
		case <-eventTicker.C:
			if processX11Events(x11, &drag, sheet != nil) {
				render(x11, dragPresentation(presentation, drag), sheet, frame)
			}
		case <-ticker.C:
			frame++
			render(x11, dragPresentation(presentation, drag), sheet, frame)
		}
	}
}

func processX11Events(x11 *C.PetX11, drag *dragInteraction, hasPet bool) bool {
	changed := false
	for {
		var event C.PetX11Event
		if C.pet_x11_next_event(x11, &event) == 0 {
			return changed
		}
		switch event.event_type {
		case C.PET_EVENT_BUTTON_PRESS:
			if event.button == 1 && hasPet && containsPetBodyPoint(int(event.x), int(event.y)) {
				drag.active = true
				drag.lastRootX = int(event.x_root)
				drag.lastRootY = int(event.y_root)
				drag.stateID = "running-right"
				changed = true
			}
		case C.PET_EVENT_MOTION:
			if !drag.active {
				continue
			}
			rootX := int(event.x_root)
			rootY := int(event.y_root)
			dx := rootX - drag.lastRootX
			dy := rootY - drag.lastRootY
			if dx == 0 && dy == 0 {
				continue
			}
			drag.stateID = dragStateForDelta(dx, drag.stateID)
			drag.lastRootX = rootX
			drag.lastRootY = rootY
			C.pet_x11_move_by(x11, C.int(dx), C.int(dy))
			changed = true
		case C.PET_EVENT_BUTTON_RELEASE:
			if drag.active && event.button == 1 {
				drag.active = false
				changed = true
			}
		case C.PET_EVENT_EXPOSE:
			changed = true
		}
	}
}

func dragPresentation(presentation overlay.Presentation, drag dragInteraction) overlay.Presentation {
	if !drag.active {
		return presentation
	}
	presentation.StateID = drag.stateID
	return presentation
}

func subscribeSnapshots(ctx context.Context, socketPath string, out chan<- protocol.Snapshot) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		conn, err := net.Dial("unix", socketPath)
		if err != nil {
			sleepOrDone(ctx, 2*time.Second)
			continue
		}
		if err := writeRequest(conn, "state.subscribe", map[string]any{}); err != nil {
			conn.Close()
			sleepOrDone(ctx, 2*time.Second)
			continue
		}
		scanner := bufio.NewScanner(conn)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for scanner.Scan() {
			snapshot, ok := decodeSnapshot(scanner.Bytes())
			if !ok {
				continue
			}
			select {
			case out <- snapshot:
			case <-ctx.Done():
				conn.Close()
				return
			}
		}
		conn.Close()
		sleepOrDone(ctx, 2*time.Second)
	}
}

func writeRequest(conn net.Conn, method string, payload map[string]any) error {
	message := map[string]any{
		"version": 1,
		"kind":    "request",
		"id":      "x11-1",
		"method":  method,
		"payload": payload,
	}
	data, err := json.Marshal(message)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = conn.Write(data)
	return err
}

func decodeSnapshot(line []byte) (protocol.Snapshot, bool) {
	var envelope struct {
		Method  string          `json:"method"`
		Payload json.RawMessage `json:"payload"`
	}
	if err := json.Unmarshal(line, &envelope); err != nil {
		return protocol.Snapshot{}, false
	}
	if envelope.Method != "state.snapshot" && envelope.Method != "state.subscribe" {
		return protocol.Snapshot{}, false
	}
	var snapshot protocol.Snapshot
	if err := json.Unmarshal(envelope.Payload, &snapshot); err != nil {
		return protocol.Snapshot{}, false
	}
	return snapshot, true
}

func sleepOrDone(ctx context.Context, duration time.Duration) {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
	case <-timer.C:
	}
}

func render(x11 *C.PetX11, presentation overlay.Presentation, sheet *spriteSheet, frame int) {
	C.pet_x11_clear(x11)
	if sheet != nil {
		frameImage := sheet.frame(presentation.StateID, frame)
		putImage(x11, frameImage, (windowWidth-spriteWidth)/2, 76)
	} else {
		cText := C.CString("Pi Pet")
		C.pet_x11_draw_text(x11, 60, 150, cText)
		C.free(unsafe.Pointer(cText))
	}

	if presentation.Bubble != "" {
		drawCString(x11, 12, 26, presentation.Bubble)
	}
	if len(presentation.ActiveSessionIDs) > 0 {
		drawCString(x11, 12, 282, "Active Pi sessions: "+countText(len(presentation.ActiveSessionIDs)))
	}
	C.pet_x11_raise(x11)
}

func drawCString(x11 *C.PetX11, x int, y int, text string) {
	for _, line := range wrapText(text, 32, 2) {
		cText := C.CString(line.text)
		C.pet_x11_draw_text(x11, C.int(x), C.int(y+line.index*14), cText)
		C.free(unsafe.Pointer(cText))
	}
}

func putImage(x11 *C.PetX11, img image.Image, x int, y int) {
	ximg := C.pet_x11_create_image(x11, C.int(img.Bounds().Dx()), C.int(img.Bounds().Dy()))
	if ximg == nil {
		return
	}
	defer C.pet_x11_destroy_image(ximg)

	bytesPerLine := int(C.pet_x11_image_bytes_per_line(ximg))
	bitsPerPixel := int(C.pet_x11_image_bits_per_pixel(ximg))
	bytesPerPixel := bitsPerPixel / 8
	if bytesPerPixel < 2 {
		return
	}
	buf := unsafe.Slice((*byte)(unsafe.Pointer(C.pet_x11_image_data(ximg))), bytesPerLine*img.Bounds().Dy())
	order := int(x11.byte_order)

	bounds := img.Bounds()
	for py := 0; py < bounds.Dy(); py++ {
		for px := 0; px < bounds.Dx(); px++ {
			pixel := nativePixel(color.NRGBAModel.Convert(img.At(bounds.Min.X+px, bounds.Min.Y+py)).(color.NRGBA), x11)
			offset := py*bytesPerLine + px*bytesPerPixel
			writePixel(buf[offset:], pixel, bytesPerPixel, order)
		}
	}
	C.pet_x11_put_image(x11, ximg, C.int(x), C.int(y))
}

func nativePixel(c color.NRGBA, x11 *C.PetX11) uint64 {
	if c.A < 255 {
		c.R = uint8((uint16(c.R)*uint16(c.A) + 255*uint16(255-c.A)) / 255)
		c.G = uint8((uint16(c.G)*uint16(c.A) + 255*uint16(255-c.A)) / 255)
		c.B = uint8((uint16(c.B)*uint16(c.A) + 255*uint16(255-c.A)) / 255)
	}
	return componentPixel(c.R, uint64(x11.red_mask)) |
		componentPixel(c.G, uint64(x11.green_mask)) |
		componentPixel(c.B, uint64(x11.blue_mask))
}

func componentPixel(value uint8, mask uint64) uint64 {
	if mask == 0 {
		return 0
	}
	shift := trailingZeros(mask)
	maxValue := mask >> shift
	return ((uint64(value) * maxValue) / 255) << shift
}

func trailingZeros(value uint64) uint {
	var shift uint
	for value&1 == 0 {
		shift++
		value >>= 1
	}
	return shift
}

func writePixel(dst []byte, pixel uint64, bytesPerPixel int, byteOrder int) {
	if byteOrder == int(C.MSBFirst) {
		for i := 0; i < bytesPerPixel; i++ {
			dst[i] = byte(pixel >> uint((bytesPerPixel-1-i)*8))
		}
		return
	}
	for i := 0; i < bytesPerPixel; i++ {
		dst[i] = byte(pixel >> uint(i*8))
	}
}
