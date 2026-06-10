package x11overlay

const (
	windowWidth  = 240
	windowHeight = 300
)

type dragInteraction struct {
	active    bool
	lastRootX int
	lastRootY int
	stateID   string
}

func containsPetBodyPoint(x int, y int) bool {
	return x >= 0 && x < windowWidth && y >= 0 && y < windowHeight
}

func dragStateForDelta(deltaX int, previous string) string {
	switch {
	case deltaX < 0:
		return "running-left"
	case deltaX > 0:
		return "running-right"
	case previous != "":
		return previous
	default:
		return "running-right"
	}
}
