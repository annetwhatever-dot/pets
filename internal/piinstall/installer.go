package piinstall

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const InstalledFileName = "codex-pets.ts"

type Options struct {
	SourcePath     string
	DestinationDir string
}

func Install(options Options) (string, error) {
	sourcePath, err := sourcePath(options.SourcePath)
	if err != nil {
		return "", err
	}
	destinationDir, err := destinationDir(options.DestinationDir)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(destinationDir, 0o755); err != nil {
		return "", err
	}

	destinationPath := filepath.Join(destinationDir, InstalledFileName)
	if err := copyFile(sourcePath, destinationPath); err != nil {
		return "", err
	}
	return destinationPath, nil
}

func sourcePath(explicit string) (string, error) {
	if explicit != "" {
		if isReadableFile(explicit) {
			return explicit, nil
		}
		return "", fmt.Errorf("Pi extension source was not found: %s", explicit)
	}

	for _, candidate := range sourceCandidates() {
		if isReadableFile(candidate) {
			return candidate, nil
		}
	}
	return "", errors.New("Pi extension source was not found")
}

func sourceCandidates() []string {
	var candidates []string
	if env := os.Getenv("PI_PET_EXTENSION_SOURCE"); env != "" {
		candidates = append(candidates, env)
	}
	if executable, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(executable), "pi-extension", "index.ts"))
	}
	if cwd, err := os.Getwd(); err == nil {
		candidates = append(candidates, filepath.Join(cwd, "pi-extension", "index.ts"))
	}
	return candidates
}

func destinationDir(explicit string) (string, error) {
	if explicit != "" {
		return explicit, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".pi", "agent", "extensions"), nil
}

func copyFile(sourcePath string, destinationPath string) error {
	source, err := os.Open(sourcePath)
	if err != nil {
		return err
	}
	defer source.Close()

	tempPath := destinationPath + ".tmp"
	destination, err := os.OpenFile(tempPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(destination, source); err != nil {
		destination.Close()
		_ = os.Remove(tempPath)
		return err
	}
	if err := destination.Close(); err != nil {
		_ = os.Remove(tempPath)
		return err
	}
	return os.Rename(tempPath, destinationPath)
}

func isReadableFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}
