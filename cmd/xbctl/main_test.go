package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigInitDropsStaleMachineInstanceAndKeepsCredentials(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yml")
	credPath := filepath.Join(dir, "credentials.env")
	metaPath := filepath.Join(dir, "install-meta.json")

	if err := os.WriteFile(cfgPath, []byte(`instances:
  - panel:
      url: "https://panel.example.com"
    machine:
      machine_id: 1
  - panel:
      url: "https://panel.example.com"
    machine:
      machine_id: 6
      token_env: "INSTANCE_PANEL_EXAMPLE_COM_MACHINE_6_EXISTING_MACHINE_TOKEN"
`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(credPath, []byte("INSTANCE_PANEL_EXAMPLE_COM_MACHINE_6_EXISTING_MACHINE_TOKEN=old-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	err := runConfigInit([]string{
		"--mode", "machine",
		"--config", cfgPath,
		"--output", cfgPath,
		"--credentials-in", credPath,
		"--credentials-out", credPath,
		"--meta", metaPath,
		"--panel-url", "https://panel.example.com",
		"--machine-id", "4",
		"--token", "new-token",
		"--install-root", dir,
		"--version", "test",
	})
	if err != nil {
		t.Fatalf("runConfigInit: %v", err)
	}

	root, err := loadWritableRootConfig(cfgPath)
	if err != nil {
		t.Fatalf("load output config: %v", err)
	}
	if got, want := len(root.Instances), 2; got != want {
		t.Fatalf("instances after stale cleanup: got %d, want %d", got, want)
	}
	for _, inst := range root.Instances {
		if inst.Machine != nil && inst.Machine.MachineID == 1 {
			t.Fatalf("stale machine without credential was retained: %+v", inst)
		}
	}

	cred, err := os.ReadFile(credPath)
	if err != nil {
		t.Fatal(err)
	}
	credText := string(cred)
	if !strings.Contains(credText, "old-token") {
		t.Fatalf("existing credential was not preserved: %s", credText)
	}
	if !strings.Contains(credText, "new-token") {
		t.Fatalf("new real token was not written: %s", credText)
	}
	if strings.Contains(credText, "=***") {
		t.Fatalf("redacted placeholder leaked into credentials: %s", credText)
	}
}
