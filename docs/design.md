# Automated Recon System Design

This repository implements the design for a cloud-based reconnaissance system.

## Core flow

`programs/*.yaml` -> `sync_programs.sh` -> `run_jobs.sh` -> `run_pipeline.sh`

## Runtime outputs

- `targets/<program>/subs.txt`
- `targets/<program>/filtered_subs.txt`
- `targets/<program>/live.txt`
- `targets/<program>/findings.json`

## Notes

- Locking is handled per program during a pipeline run.
- External tools are used when installed; the scripts degrade safely when a tool is missing.
- Findings are annotated with the originating program.
- Scanner execution can be enabled explicitly with `RECON_USE_SUBFINDER`, `RECON_USE_HTTPX`, and `RECON_USE_NUCLEI`.
- Real Telegram and subfinder credentials live only in server-local files named without the `.example` suffix.

## EC2 Bootstrap

Use `scripts/setup_ec2.sh` to install packages, Go tools, clone the repo, create runtime directories, and add cron jobs.
