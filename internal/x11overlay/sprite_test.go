package x11overlay

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadSpriteSheetAndFrameSelection(t *testing.T) {
	dir := t.TempDir()
	frameWidth := 4
	frameHeight := 3
	atlas := image.NewNRGBA(image.Rect(0, 0, frameWidth*8, frameHeight*9))
	for row := 0; row < 9; row++ {
		for col := 0; col < 8; col++ {
			fill := color.NRGBA{R: uint8(row * 20), G: uint8(col * 25), B: uint8(row + col), A: 255}
			drawCell(atlas, col*frameWidth, row*frameHeight, frameWidth, frameHeight, fill)
		}
	}
	writePNG(t, filepath.Join(dir, "spritesheet.png"), atlas)
	writePetJSON(t, dir, "spritesheet.png", frameWidth, frameHeight)

	sheet := loadSpriteSheet(dir)
	if sheet == nil {
		t.Fatal("expected PNG spritesheet to load")
	}
	if sheet.frameWidth != frameWidth || sheet.frameHeight != frameHeight {
		t.Fatalf("frame size = %dx%d, want %dx%d", sheet.frameWidth, sheet.frameHeight, frameWidth, frameHeight)
	}

	frame := sheet.frame("waiting", 2)
	if got := frame.Bounds().Dx(); got != spriteWidth {
		t.Fatalf("frame width = %d, want %d", got, spriteWidth)
	}
	if got := frame.Bounds().Dy(); got != spriteHeight {
		t.Fatalf("frame height = %d, want %d", got, spriteHeight)
	}
	want := color.NRGBA{R: 120, G: 50, B: 8, A: 255}
	if got := color.NRGBAModel.Convert(frame.At(spriteWidth/2, spriteHeight/2)).(color.NRGBA); got != want {
		t.Fatalf("waiting frame sample = %+v, want %+v", got, want)
	}

	wrapped := sheet.frame("waving", 5)
	wrappedWant := color.NRGBA{R: 60, G: 25, B: 4, A: 255}
	if got := color.NRGBAModel.Convert(wrapped.At(spriteWidth/2, spriteHeight/2)).(color.NRGBA); got != wrappedWant {
		t.Fatalf("wrapped waving frame sample = %+v, want %+v", got, wrappedWant)
	}
}

func TestLoadSpriteSheetRejectsWebPForCurrentLinuxRenderer(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "spritesheet.webp"), []byte("RIFF\x00\x00\x00\x00WEBP"), 0o600); err != nil {
		t.Fatal(err)
	}
	writePetJSON(t, dir, "spritesheet.webp", 192, 208)

	if sheet := loadSpriteSheet(dir); sheet != nil {
		t.Fatalf("expected Linux X11 renderer to reject WebP until a native decoder is added, got %+v", sheet)
	}
}

func TestStateRowsPlaceholderScalingAndTextWrapping(t *testing.T) {
	cases := map[string]struct {
		row    int
		frames int
	}{
		"idle":          {0, 6},
		"running-right": {1, 8},
		"running-left":  {2, 8},
		"waving":        {3, 4},
		"jumping":       {4, 5},
		"failed":        {5, 8},
		"waiting":       {6, 6},
		"running":       {7, 6},
		"review":        {8, 6},
		"unknown":       {0, 6},
	}
	for state, want := range cases {
		row, frames := stateRow(state)
		if row != want.row || frames != want.frames {
			t.Fatalf("stateRow(%q) = (%d, %d), want (%d, %d)", state, row, frames, want.row, want.frames)
		}
	}

	tiny := &spriteSheet{image: image.NewNRGBA(image.Rect(0, 0, 1, 1)), frameWidth: 4, frameHeight: 4}
	placeholder := tiny.frame("review", 0)
	if placeholder.Bounds().Dx() != spriteWidth || placeholder.Bounds().Dy() != spriteHeight {
		t.Fatalf("placeholder bounds = %v, want %dx%d", placeholder.Bounds(), spriteWidth, spriteHeight)
	}
	if got := color.NRGBAModel.Convert(placeholder.At(0, 0)).(color.NRGBA); got != (color.NRGBA{R: 240, G: 244, B: 248, A: 255}) {
		t.Fatalf("placeholder color = %+v", got)
	}

	src := image.NewNRGBA(image.Rect(0, 0, 2, 2))
	src.Set(0, 0, color.NRGBA{R: 1, A: 255})
	src.Set(1, 0, color.NRGBA{G: 2, A: 255})
	src.Set(0, 1, color.NRGBA{B: 3, A: 255})
	src.Set(1, 1, color.NRGBA{R: 4, G: 5, B: 6, A: 255})
	scaled := scaleNearest(src, src.Bounds(), 4, 4)
	if got := color.NRGBAModel.Convert(scaled.At(3, 3)).(color.NRGBA); got != (color.NRGBA{R: 4, G: 5, B: 6, A: 255}) {
		t.Fatalf("scaled bottom-right = %+v", got)
	}

	lines := wrapText("Approval needed for git push origin main now", 18, 2)
	if len(lines) != 2 {
		t.Fatalf("wrapped lines = %d, want 2", len(lines))
	}
	if lines[0].text != "Approval needed" || lines[0].index != 0 {
		t.Fatalf("first line = %+v", lines[0])
	}
	if lines[1].index != 1 || len(lines[1].text) > 18 {
		t.Fatalf("second line = %+v", lines[1])
	}
	if countText(1) != "1" || countText(2) != "many" {
		t.Fatalf("unexpected count labels: %q %q", countText(1), countText(2))
	}
}

func TestDragInteractionHelpers(t *testing.T) {
	points := []struct {
		x    int
		y    int
		want bool
	}{
		{x: 0, y: 0, want: true},
		{x: windowWidth / 2, y: windowHeight / 2, want: true},
		{x: windowWidth - 1, y: windowHeight - 1, want: true},
		{x: -1, y: 0, want: false},
		{x: 0, y: -1, want: false},
		{x: windowWidth, y: 0, want: false},
		{x: 0, y: windowHeight, want: false},
	}
	for _, point := range points {
		if got := containsPetBodyPoint(point.x, point.y); got != point.want {
			t.Fatalf("containsPetBodyPoint(%d, %d) = %v, want %v", point.x, point.y, got, point.want)
		}
	}

	if got := dragStateForDelta(8, "running-left"); got != "running-right" {
		t.Fatalf("right drag state = %q", got)
	}
	if got := dragStateForDelta(-8, "running-right"); got != "running-left" {
		t.Fatalf("left drag state = %q", got)
	}
	if got := dragStateForDelta(0, "running-left"); got != "running-left" {
		t.Fatalf("zero-delta drag state should preserve previous, got %q", got)
	}
	if got := dragStateForDelta(0, ""); got != "running-right" {
		t.Fatalf("zero-delta default drag state = %q", got)
	}
}

func drawCell(img *image.NRGBA, x int, y int, width int, height int, fill color.NRGBA) {
	for py := y; py < y+height; py++ {
		for px := x; px < x+width; px++ {
			img.SetNRGBA(px, py, fill)
		}
	}
}

func writePNG(t *testing.T, path string, img image.Image) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err := png.Encode(file, img); err != nil {
		t.Fatal(err)
	}
}

func writePetJSON(t *testing.T, dir string, spritePath string, frameWidth int, frameHeight int) {
	t.Helper()
	data := []byte(`{
  "slug": "test-pet",
  "displayName": "Test Pet",
  "description": "Renderer test pet",
  "spritesheetPath": "` + spritePath + `",
  "frameWidth": ` + itoa(frameWidth) + `,
  "frameHeight": ` + itoa(frameHeight) + `,
  "license": "MIT",
  "attribution": "tests"
}`)
	if err := os.WriteFile(filepath.Join(dir, "pet.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	var digits [20]byte
	index := len(digits)
	for value > 0 {
		index--
		digits[index] = byte('0' + value%10)
		value /= 10
	}
	return string(digits[index:])
}
