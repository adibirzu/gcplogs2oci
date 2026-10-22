# gcplogs2oci agent guide
A Python bridge streams GCP Cloud Logging messages from Pub/Sub into OCI Streaming for Log Analytics ingestion.

## Commands
- Install: `python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt`.
- Test: no repository test suite is present; credential checks are `python scripts/test_gcp_credentials.py` and `python scripts/test_oci_credentials.py`.
- Lint: no lint command is configured.
- Run: `python -m bridge.main` (continuous) or `python -m bridge.main --drain` (drain mode).

## Layout
- Bridge implementation -> `bridge/`
- Provisioning, status, credential, and message scripts -> `scripts/`
- Fluentd container bridge -> `docker/`
- OCI Resource Manager Terraform stack -> `stack/`
- Architecture, quickstart, and IAM docs -> `docs/`
- Dependency list and environment template -> `requirements.txt`, `.env.example`

## Boundaries
- The bridge connects GCP Pub/Sub to OCI Streaming; runtime cloud credentials are configured through ADC/environment and OCI SDK configuration.
- Never commit `*.key`, `*.crt`, `*.csr`, `*.pem`, `gcp-sa-key.json`, `.env`, `.env.local`, `.venv/`, or Terraform state/plan files; these are excluded by `.gitignore`.
- `.env.local` is the local configuration file; `.env.example` is the template.

## On error
Search KB.md (and ~/dev/OCI-DEMO/KB.md for OCI issues) before debugging; add an entry after a new fix. Do not read KB.md at session start.

## Done
- `python -m bridge.main --drain`

<!-- BEGIN oci4cca-ecosystem-matrix -->
<!-- BEGIN oci4cca-ecosystem-matrix -->
