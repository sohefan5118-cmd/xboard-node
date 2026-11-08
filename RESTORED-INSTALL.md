# Restored owner installation

Repository: https://github.com/sohefan5118-cmd/xboard-node

Runtime source baseline: owner's preserved commit `77fc2de1ea8f67e92cc42ea0d521b1b3d309c06a`.
The Linux amd64 runtime release asset is extracted without modification from
`ghcr.io/sohefan5118-cmd/xboard-node:77fc2de1ea8f67e92cc42ea0d521b1b3d309c06a`.
Its SHA256 is `a1c5da9af4b4a8e4c6820b95ce34867a1490543436fb89e633d08c56a34d2b8e`.
The management CLI is rebuilt from the same backup with its download URL changed to this repository.

This restoration publishes Linux amd64 assets only. It does not include experimental
device lease changes. Existing GHCR tags are preserved. Automatic CI publishing is
disabled; the preserved workflow can be explicitly dispatched by the owner.

Download the installer, then run it using a machine token obtained from your panel:

```sh
curl -fsSL https://raw.githubusercontent.com/sohefan5118-cmd/xboard-node/09cf31b62d667bbfc55124f5d691a571c090f8c7/install.sh -o /tmp/xboard-node-install.sh
bash /tmp/xboard-node-install.sh --mode machine --panel https://panel.example.com --token-file /root/machine-token --machine-id 1
```

Commit `09cf31b62d667bbfc55124f5d691a571c090f8c7` supports both a downloaded
script and `curl | bash` execution. Pin this commit in generated panel commands;
do not use a moving branch when installing production nodes.

The installer downloads only from this owner's Release and GitHub API and verifies
the pinned checksums. It preserves the existing multi-instance configuration merge
and credentials-file behavior. `--binary` and `--xbctl-binary` remain available for
offline installations. All original attribution and dependency module paths remain
in the restored source; these names do not select an external runtime image.
