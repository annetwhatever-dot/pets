package piinstall

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInstallCopiesAndUpdatesExtension(t *testing.T) {
	root := t.TempDir()
	sourcePath := filepath.Join(root, "source", "index.ts")
	destinationDir := filepath.Join(root, ".pi", "agent", "extensions")

	if err := os.MkdirAll(filepath.Dir(sourcePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(destinationDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sourcePath, []byte("new extension"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(destinationDir, InstalledFileName), []byte("old extension"), 0o644); err != nil {
		t.Fatal(err)
	}

	installedPath, err := Install(Options{SourcePath: sourcePath, DestinationDir: destinationDir})
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(installedPath)
	if err != nil {
		t.Fatal(err)
	}

	if filepath.Base(installedPath) != InstalledFileName {
		t.Fatalf("installed file = %q, want %q", filepath.Base(installedPath), InstalledFileName)
	}
	if string(data) != "new extension" {
		t.Fatalf("installed contents = %q", string(data))
	}
}

func TestInstallReportsMissingExplicitSource(t *testing.T) {
	_, err := Install(Options{
		SourcePath:     filepath.Join(t.TempDir(), "missing.ts"),
		DestinationDir: t.TempDir(),
	})
	if err == nil {
		t.Fatal("Install succeeded with a missing source")
	}
}

func TestUninstallRemovesExtension(t *testing.T) {
	destinationDir := t.TempDir()
	destinationPath := filepath.Join(destinationDir, InstalledFileName)
	if err := os.WriteFile(destinationPath, []byte("extension"), 0o644); err != nil {
		t.Fatal(err)
	}

	removedPath, err := Uninstall(Options{DestinationDir: destinationDir})
	if err != nil {
		t.Fatal(err)
	}
	if removedPath != destinationPath {
		t.Fatalf("removed path = %q, want %q", removedPath, destinationPath)
	}
	if _, err := os.Stat(destinationPath); !os.IsNotExist(err) {
		t.Fatalf("installed extension still exists: %v", err)
	}
}

func TestUninstallAllowsAlreadyMissingExtension(t *testing.T) {
	if _, err := Uninstall(Options{DestinationDir: t.TempDir()}); err != nil {
		t.Fatal(err)
	}
}
