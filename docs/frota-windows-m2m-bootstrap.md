# Frota Windows M2M Bootstrap

`FROTA_WINDOWS_M2M_CLONE` is the canonical `after_create` contract for Frota
Windows workers that need unattended HTTPS clones from the allowed GitHub repo.

The contract preserves the Gabriela homologation baseline:

- GitHub App installation token is issued on TRUCK.
- The token is passed only through process stdin.
- The token is not placed in the URL, command line, Git config, logs, or a file.
- Git for Windows receives credentials through a process-local MSYS
  `credential.helper`.
- `git.exe` is launched directly through `ProcessStartInfo`.
- Temporary helper and PowerShell hook files are removed after execution.

Runtime configuration stays worker-neutral:

```yaml
hooks:
  after_create: |
    FROTA_WINDOWS_M2M_CLONE
```

The allowed repo comes from `tracker.provider.repo`; Symphony requests the
installation token for that repo and the remote script clones
`https://github.com/<repo>.git` into the prepared workspace.

Workers remain parameterized by existing config:

- `worker.ssh_hosts`
- `worker.platforms`
- `worker.workspace_roots`
- `routing.canonical_file`
- issue capability labels

Do not replace this flow with `gh auth`, Windows credential helpers, PATs,
deploy keys, GitHub SSH, `GIT_ASKPASS`, token-in-URL, or local fallback.
