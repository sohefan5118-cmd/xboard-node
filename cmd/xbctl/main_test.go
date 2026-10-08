package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigInitRefusesStaleMachineInstanceWithoutMutatingFiles(t *testing.T) {
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

	originalConfig, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	originalCred, err := os.ReadFile(credPath)
	if err != nil {
		t.Fatal(err)
	}
	err = runConfigInit([]string{
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
	if err == nil || !strings.Contains(err.Error(), "refusing to remove it") {
		t.Fatalf("expected stale credential refusal, got %v", err)
	}
	gotConfig, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	gotCred, err := os.ReadFile(credPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(gotConfig) != string(originalConfig) || string(gotCred) != string(originalCred) {
		t.Fatal("refused merge mutated config or credentials")
	}
}

func TestConfigInitPreservesCredentialedInstancesAndAddsMachine(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yml")
	credPath := filepath.Join(dir, "credentials.env")
	metaPath := filepath.Join(dir, "install-meta.json")

	if err := os.WriteFile(cfgPath, []byte(`instances:
  - panel:
      url: "https://panel.example.com"
    machine:
      machine_id: 6
      token_env: "INSTANCE_PANEL_EXAMPLE_COM_MACHINE_6_MACHINE_TOKEN"
`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(credPath, []byte("INSTANCE_PANEL_EXAMPLE_COM_MACHINE_6_MACHINE_TOKEN=old-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := runConfigInit([]string{
		"--mode", "machine",
		"--config", cfgPath,
		"--output", filepath.Join(dir, "staged.yml"),
		"--credentials-in", credPath,
		"--credentials-out", filepath.Join(dir, "staged.env"),
		"--meta", metaPath,
		"--panel-url", "https://panel.example.com",
		"--machine-id", "8",
		"--token", "new-token",
		"--install-root", dir,
		"--version", "test",
	}); err != nil {
		t.Fatal(err)
	}

	stagedConfig, err := os.ReadFile(filepath.Join(dir, "staged.yml"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(stagedConfig)
	if !strings.Contains(text, "machine_id: 6") || !strings.Contains(text, "machine_id: 8") {
		t.Fatalf("merged config lost an instance:\n%s", text)
	}
	stagedCred, err := os.ReadFile(filepath.Join(dir, "staged.env"))
	if err != nil {
		t.Fatal(err)
	}
	credText := string(stagedCred)
	if !strings.Contains(credText, "INSTANCE_PANEL_EXAMPLE_COM_MACHINE_6_MACHINE_TOKEN=old-token") ||
		!strings.Contains(credText, "INSTANCE_PANEL_EXAMPLE_COM_MACHINE_8_MACHINE_TOKEN=new-token") {
		t.Fatalf("merged credentials are incomplete:\n%s", credText)
	}
}
