# Automated Recon System

Program-based, continuously running recon for bug bounty programs.

## What is included

- YAML-driven program definitions in `programs/`
- Scheduler and worker scripts in `scripts/`
- EC2 deployment workflow for GitHub Actions
- Sample configs and placeholder notifications setup

## Quick Start

```bash
mkdir -p /recon
export RECON_ROOT=/recon
./scripts/sync_programs.sh
./scripts/run_jobs.sh
```

## Scanner Flags

Set these to `true` on the EC2 host to enable the external ProjectDiscovery tools:

- `RECON_USE_SUBFINDER`
- `RECON_USE_HTTPX`
- `RECON_USE_NUCLEI`

Without those flags, the repo still runs with deterministic fallback behavior for local development.

## Config Files

Create server-local secrets on the EC2 host by copying the example files:

```bash
cp /recon/config/notify-config.example.yaml /recon/config/notify-config.yaml
cp /recon/config/subfinder-config.example.yaml /recon/config/subfinder-config.yaml
chmod 600 /recon/config/*.yaml
```

The runtime reads the non-example files only.

## EC2 Setup

Run the bootstrap script on Ubuntu 22.04:

```bash
REPO_URL=git@github.com:you/your-repo.git ./scripts/setup_ec2.sh
```

The bootstrap now creates swap automatically and installs Go tools with a single build worker to reduce OOM risk on small instances.

## Terraform

Provision the AWS side from `terraform/`:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
terraform -chdir=terraform init
terraform -chdir=terraform plan -var-file=terraform.tfvars
terraform -chdir=terraform apply -var-file=terraform.tfvars
```

For free-tier testing, keep `instance_type = "t3.micro"`.

Before applying, create these SSM parameters if you want the instance to bootstrap fully:

- `/ars/github_deploy_key`
- `/ars/notify_config_yaml`
- `/ars/subfinder_config_yaml`

Store the values as base64-encoded blobs. The Terraform userdata decodes them on boot and writes the real files onto the instance.

If the repo is private, add a GitHub deploy key to `git@github.com:vshneer/ars.git` and store the matching private key in `/ars/github_deploy_key`.

Example:

```bash
val=$(base64 < config/notify-config.yaml | tr -d '\n')
aws ssm put-parameter --name /ars/notify_config_yaml --type SecureString --value "$val" --overwrite
```

Repeat the same pattern for `/ars/subfinder_config_yaml` and `/ars/github_deploy_key`.

## GitHub Deployment

The GitHub workflow now uses AWS Systems Manager instead of inbound SSH.

Add these GitHub secrets:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`

The AWS identity used by the workflow needs permission to:

- `ec2:DescribeInstances`
- `ssm:SendCommand`
- `ssm:GetCommandInvocation`
- `ssm:ListCommandInvocations`

The EC2 host must have the SSM managed instance role attached, which Terraform now configures.

## Manual Local Testing

Use a temporary root so you do not touch `/recon`:

```bash
tmp=$(mktemp -d)
mkdir -p "$tmp/programs"
cp programs/airbnb.yaml "$tmp/programs/airbnb.yaml"
RECON_ROOT="$tmp" RECON_USE_SUBFINDER=false RECON_USE_HTTPX=false RECON_USE_NUCLEI=false ./scripts/sync_programs.sh
RECON_ROOT="$tmp" RECON_USE_SUBFINDER=false RECON_USE_HTTPX=false RECON_USE_NUCLEI=false ./scripts/run_jobs.sh
```

Check the output files in `$tmp/targets/airbnb/`.

Pipeline outputs are cumulative:

- `subs.txt` = all discovered subdomains seen so far
- `subs.raw.txt` = raw output from the latest run
- `subs.new.txt` = only the new discoveries from the latest run

## Status Check

On EC2, run:

```bash
/recon-repo/scripts/check_status.sh
```


## Layout

- `programs/` program YAML files
- `scripts/` sync, scheduler, pipeline, and helper scripts
- `config/` tool configs and notification config
- `docs/` design and operational notes
