# AGENTS.md

Guidance for agentic coding work in this repository.

## Scope

- Repository: `/Users/worker/ars`
- Project type: Bash-heavy automation with one Python helper
- Runtime: Ubuntu 22.04 on EC2, GitHub Actions deploy
- No Cursor rules or Copilot instructions were present in this repo when this file was written

## What This Repo Does

- Loads bug bounty programs from `programs/*.yaml`
- Syncs jobs into `jobs/`
- Runs recon pipelines per program
- Writes structured outputs into `targets/<program>/`
- Uses optional external tools when enabled on EC2

## Key Paths

- `programs/` program definitions
- `scripts/` shell entrypoints and helper code
- `config/` checked-in examples plus server-local real configs
- `docs/` architecture and operational notes
- `.github/workflows/` deployment automation

## Safety Rules

- Never commit real secrets.
- Real config files are gitignored: `config/notify-config.yaml` and `config/subfinder-config.yaml`.
- Example configs are the only files that should be committed.
- Do not overwrite user changes outside the task.
- Prefer small, targeted edits.

## Build / Lint / Test

There is no package manager or dedicated test harness.

Use these validation commands:

```bash
bash -n scripts/lib.sh scripts/sync_programs.sh scripts/run_jobs.sh scripts/run_pipeline.sh scripts/update_templates.sh scripts/setup_ec2.sh
python3 -m py_compile scripts/reconlib.py
```

Terraform checks:

```bash
terraform -chdir=terraform fmt -check
terraform -chdir=terraform init
terraform -chdir=terraform validate
```

Single-file shell syntax check:

```bash
bash -n scripts/run_pipeline.sh
```

Single Python file check:

```bash
python3 -m py_compile scripts/reconlib.py
```

Single-program local smoke test:

```bash
tmp=$(mktemp -d)
mkdir -p "$tmp/programs"
cp programs/airbnb.yaml "$tmp/programs/airbnb.yaml"
RECON_ROOT="$tmp" RECON_USE_SUBFINDER=false RECON_USE_HTTPX=false RECON_USE_NUCLEI=false ./scripts/sync_programs.sh
RECON_ROOT="$tmp" RECON_USE_SUBFINDER=false RECON_USE_HTTPX=false RECON_USE_NUCLEI=false ./scripts/run_jobs.sh
```

Direct pipeline run for one program:

```bash
RECON_ROOT="$tmp" RECON_USE_SUBFINDER=false RECON_USE_HTTPX=false RECON_USE_NUCLEI=false ./scripts/run_pipeline.sh airbnb
```

EC2 bootstrap dry run checks:

```bash
bash -n scripts/setup_ec2.sh
```

Terraform plan:

```bash
terraform -chdir=terraform plan -var-file=terraform.tfvars
```

## How To Test Changes

- If you change shell logic, run `bash -n` on every touched `.sh` file.
- If you change `scripts/reconlib.py`, run `python3 -m py_compile scripts/reconlib.py`.
- If you change pipeline flow, run the temporary-root smoke test above.
- If you change deployment behavior, inspect `.github/workflows/deploy.yml` and `scripts/setup_ec2.sh` together.

## Shell Style

- Use `#!/usr/bin/env bash`.
- Keep `set -euo pipefail` in executable scripts.
- Source shared shell helpers from `scripts/lib.sh`.
- Use uppercase environment variables for runtime configuration.
- Prefer early exits over deep nesting.
- Quote variable expansions unless word splitting is intended.
- Prefer arrays for command arguments.
- Redirect noisy external-tool output to `2>/dev/null` when failures are intentionally non-fatal.
- Use `trap` to clean up locks and temporary state.
- Keep log messages short and structured.

## Shell Naming

- Script names should be lowercase with underscores.
- Runtime status files use `program=<name>` and `status=<state>` lines.
- Functions should use descriptive verb phrases like `install_packages` or `update_job_status`.

## Shell Error Handling

- Fail fast on missing required inputs.
- Treat lock acquisition as a hard gate.
- Non-critical recon tool failures may be tolerated, but the script must still produce valid output files.
- If a command is optional, guard it with `command -v` and a feature flag or file check.

## Python Style

- Use Python 3.10+ syntax.
- Keep the helper script dependency-free.
- Preserve type hints on public helpers.
- Use `Path` instead of string path concatenation when reading and writing files.
- Prefer small pure helpers for parsing and filtering logic.
- Keep CLI actions separated into command functions.

## Python Naming

- Functions: `snake_case`.
- Variables: `snake_case`.
- Constants: this repo does not currently use module-level constants heavily; only add them when useful.
- CLI subcommands should map cleanly to function names.

## Python Error Handling

- Raise or exit on invalid CLI usage.
- Let file read/write errors surface unless there is a clear recovery path.
- Keep JSON parsing deterministic and explicit.
- Avoid adding broad `except Exception` blocks.

## YAML Style

- Use lowercase keys.
- Keep program YAML files minimal and declarative.
- Quote wildcard domains such as `"*.example.com"`.
- Keep secrets out of YAML tracked by Git.

## Documentation Style

- Keep docs short and operational.
- Prefer examples over abstract prose.
- Update `README.md` when user-facing workflow changes.
- Update `docs/design.md` when runtime behavior changes.

## Deployment Notes

- GitHub Actions deploys on changes to `programs/**`, `scripts/**`, `config/**`, `docs/**`, and `deploy.sh`.
- EC2 runtime defaults to `/recon`.
- EC2 repo checkout defaults to `/recon-repo`.
- The bootstrap script should remain safe to re-run.

## External Tools

- `subfinder`, `httpx`, `nuclei`, and `notify` are optional in local development.
- Real scanner execution is controlled with:
  - `RECON_USE_SUBFINDER=true`
  - `RECON_USE_HTTPX=true`
  - `RECON_USE_NUCLEI=true`
- `NUCLEI_TEMPLATES_DIR`, `SUBFINDER_CONFIG_FILE`, and `NOTIFY_CONFIG_FILE` can override defaults if needed.

## Locking And Outputs

- Per-program locks live at `targets/<program>/lock`.
- A pipeline run should leave these outputs:
  - `subs.txt`
  - `filtered_subs.txt`
  - `live.txt`
  - `findings.raw`
  - `findings.json`
- The lock must be removed on exit.

## Practical Agent Workflow

1. Inspect the relevant script or doc before editing.
2. Make the smallest correct change.
3. Run the relevant validation command.
4. Mention any remaining assumptions or runtime dependencies.
