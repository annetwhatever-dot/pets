package x11overlay

import (
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"os"
	"path/filepath"
	"strings"

	"codex-pets/internal/catalog"
)

const (
	spriteWidth  = 154
	spriteHeight = 166
)

type spriteSheet struct {
	image       image.Image
	frameWidth  int
	frameHeight int
	path        string
}

func loadSpriteSheet(petDir string) *spriteSheet {
	if petDir == "" {
		return nil
	}
	pet, err := catalog.LoadLocalPet(petDir, catalog.DefaultLimits())
	if err != nil {
		return nil
	}
	if strings.ToLower(filepath.Ext(pet.SourcePath)) != ".png" {
		return nil
	}
	file, err := os.Open(pet.SourcePath)
	if err != nil {
		return nil
	}
	defer file.Close()
	img, err := png.Decode(file)
	if err != nil {
		return nil
	}
	return &spriteSheet{
		image:       img,
		frameWidth:  pet.FrameWidth,
		frameHeight: pet.FrameHeight,
		path:        pet.SourcePath,
	}
}

func (sheet *spriteSheet) frame(stateID string, frame int) image.Image {
	row, frames := stateRow(stateID)
	source := image.Rect(
		(frame%frames)*sheet.frameWidth,
		row*sheet.frameHeight,
		(frame%frames+1)*sheet.frameWidth,
		(row+1)*sheet.frameHeight,
	).Intersect(sheet.image.Bounds())
	if source.Empty() {
		return placeholderImage()
	}
	return scaleNearest(sheet.image, source, spriteWidth, spriteHeight)
}

func stateRow(stateID string) (int, int) {
	switch stateID {
	case "running-right":
		return 1, 8
	case "running-left":
		return 2, 8
	case "waving":
		return 3, 4
	case "jumping":
		return 4, 5
	case "failed":
		return 5, 8
	case "waiting":
		return 6, 6
	case "running":
		return 7, 6
	case "review":
		return 8, 6
	default:
		return 0, 6
	}
}

func placeholderImage() image.Image {
	img := image.NewNRGBA(image.Rect(0, 0, spriteWidth, spriteHeight))
	draw.Draw(img, img.Bounds(), image.NewUniform(color.NRGBA{R: 240, G: 244, B: 248, A: 255}), image.Point{}, draw.Src)
	return img
}

func scaleNearest(src image.Image, source image.Rectangle, width int, height int) image.Image {
	dst := image.NewNRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		sy := source.Min.Y + y*source.Dy()/height
		for x := 0; x < width; x++ {
			sx := source.Min.X + x*source.Dx()/width
			dst.Set(x, y, src.At(sx, sy))
		}
	}
	return dst
}

type wrappedLine struct {
	text  string
	index int
}

func wrapText(text string, max int, maxLines int) []wrappedLine {
	words := strings.Fields(text)
	lines := []wrappedLine{}
	current := ""
	for _, word := range words {
		if len(current)+len(word)+1 > max && current != "" {
			lines = append(lines, wrappedLine{text: current, index: len(lines)})
			current = word
			if len(lines) >= maxLines {
				return lines
			}
			continue
		}
		if current == "" {
			current = word
		} else {
			current += " " + word
		}
	}
	if current != "" && len(lines) < maxLines {
		lines = append(lines, wrappedLine{text: current, index: len(lines)})
	}
	return lines
}

func countText(count int) string {
	if count == 1 {
		return "1"
	}
	return "many"
}
