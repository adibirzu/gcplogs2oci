# Quickstart

End-to-end setup from zero to seeing GCP logs in OCI Log Analytics.

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **GCP** | Project with Cloud Logging and Pub/Sub APIs enabled; `gcloud` CLI installed and authenticated |
| **OCI** | Tenancy with Streaming and Log Analytics **onboarded**; `oci` CLI configured (`oci setup config`) |
| **Python** | 3.11+ with `pip` |
| **OCI Python SDK** | `oci >= 2.124.0` (included in `requirements.txt`; needed by `setup_oci.sh` for field/parser creation) |
| **Docker** | Optional — only needed for the Fluentd production path |

### Required IAM Policies (OCI)

The user running `setup_oci.sh` needs these permissions in the target compartment:

```
Allow group <group> to manage streams in compartment <compartment>
Allow group <group> to manage stream-pools in compartment <compartment>
Allow group <group> to manage log-analytics-log-group in compartment <compartment>
Allow group <group> to manage loganalytics-features-family in compartment <compartment>
Allow group <group> to manage serviceconnectors in compartment <compartment>
```

The Service Connector Hub also needs a policy to read from the stream:

```
Allow any-user to use stream-pull in compartment <compartment> where all {request.principal.type='serviceconnector'}
Allow any-user to use log-analytics-log-group in compartment <compartment> where all {request.principal.type='serviceconnector'}
```

### Onboard OCI Log Analytics

If Log Analytics has not been activated in your tenancy, do so before running `setup_oci.sh`:

1. Go to **OCI Console > Observability & Management > Log Analytics**
2. Click **Start Using Log Analytics** (one-time per tenancy)
3. Wait for onboarding to complete

The `setup_oci.sh` script auto-detects the Log Analytics namespace, which only exists after onboarding.

## 1. Clone and Configure

```bash
git clone https://github.com/adibirzu/gcplogs2oci.git
cd gcplogs2oci
cp .env.example .env.local       # fill in GCP + OCI auth values (see below)
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

Edit `.env.local` with your **GCP project ID** and **OCI authentication credentials** (user OCID, key file, fingerprint, tenancy, region, compartment). The OCI Stream OCID and message endpoint will be filled in *after* running `setup_oci.sh` in step 3.

See `.env.example` for all available variables and their descriptions.

### GCP Authentication

The bridge uses **Application Default Credentials (ADC)** — no service account key file needed for local development:

```bash
gcloud auth application-default login
```

For CI/production environments, create a service account with `Pub/Sub Subscriber` and `Pub/Sub Viewer` roles, download a JSON key, and set:

```
GOOGLE_APPLICATION_CREDENTIALS=/path/to/gcp-sa-key.json
```

### OCI Authentication

1. Run `oci setup config` if you haven't already (creates `~/.oci/config` and generates an API signing key)
2. **Upload the public key** to OCI Console: **Identity > Users > your user > API Keys > Add API Key**
3. Set the key path in `.env.local`:

```
OCI_KEY_FILE=~/.oci/oci_api_key.pem
```

For CI/containers, provide the PEM inline instead:

```
OCI_KEY_CONTENT="-----BEGIN PRIVATE KEY----- ... -----END PRIVATE KEY-----"
```

## 2. Provision GCP Resources

```bash
# Creates: Pub/Sub topic + subscription, Log Router sink, service account + IAM bindings
./scripts/setup_gcp.sh
```

This creates:
- **Pub/Sub topic** (`oci-log-export-topic`) with 7-day message retention
- **Pull subscription** (`fluentd-oci-bridge-sub`) with 60s ack deadline, no expiration
- **Log Router sink** (`gcp-to-oci-sink`) routing matching logs to the topic
- **Service account** IAM bindings for Pub/Sub access

Validate GCP credentials:

```bash
python scripts/test_gcp_credentials.py
```

## 3. Provision OCI Resources

Ensure the [IAM policies listed above](#required-iam-policies-oci) are in place — both the **user policies** (to create resources) and the **SCH policies** (to allow Service Connector Hub to read streams and write to Log Analytics).

```bash
# Creates 7 resources: Stream Pool, Stream, Log Group, custom fields, parser, source, SCH
./scripts/setup_oci.sh
```

The script automatically provisions the full pipeline in 7 steps:

1. **Stream Pool** — Kafka-compatible pool with SASL/SSL
2. **Stream** — `gcp-inbound-stream` message buffer
3. **Kafka connection info** — Prints bootstrap servers for the Fluentd path
4. **Log Analytics Log Group** — `GCPLogs` (or custom name via `OCI_LOG_GROUP_NAME`)
5. **Custom fields + JSON parser** — 40 GCP-specific fields and a 44-mapping JSON parser covering all [GCP Cloud Logging](https://cloud.google.com/logging/docs/structured-logging) resource types (audit, Cloud Run, Pub/Sub, etc.)
6. **Log Analytics source** — `GCP Cloud Logging Logs` source using the custom parser
7. **Service Connector Hub** — `GCP-Stream-to-LogAnalytics` connecting stream to log group

After setup, **update `.env.local`** with the printed values:

```
OCI_STREAM_OCID=ocid1.stream.oc1...        # from step 2
OCI_MESSAGE_ENDPOINT=https://cell-1...      # from step 3
OCI_LOG_ANALYTICS_NAMESPACE=...             # from step 4 (or auto-detected)
```

Validate OCI credentials:

```bash
python scripts/test_oci_credentials.py
```

## 4. End-to-End Test

### Publish test messages to GCP Pub/Sub:

```bash
python scripts/publish_test_message.py --count 5
```

### Run the bridge in drain mode:

```bash
python -m bridge.main --drain
```

Expected output:

```
Bridge initialised | project=my-project | subscription=fluentd-oci-bridge-sub ...
Streaming pull started ...
Flushed to OCI: sent=5, failed=0, batches=1
Inactivity timeout (30s) reached, stopping
Bridge stopped | processed=5 | sent=5 | failed=0 | errors=0 | batches=1
```

### Verify in OCI Log Analytics:

After the bridge sends messages, the Service Connector Hub automatically forwards them from the stream to Log Analytics. Query using the OCI CLI:

```bash
# macOS:
TIME_START="$(date -u -v-1H +%Y-%m-%dT%H:%M:%S.000Z)"
# Linux:
# TIME_START="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S.000Z)"

oci log-analytics query search \
    --namespace-name "$OCI_LOG_ANALYTICS_NAMESPACE" \
    --compartment-id "$OCI_COMPARTMENT_OCID" \
    --query-string "'Log Source' = 'GCP Cloud Logging Logs' | fields 'Cloud Provider', Severity, Message, 'GCP Insert ID', 'GCP Resource Type', 'GCP Project ID' | head 5" \
    --sub-system LOG \
    --time-start "$TIME_START" \
    --time-end "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
```

You should see records with extracted GCP fields:

```
Cloud Provider: GCP
GCP Insert ID: test-xxxx-0
GCP Resource Type: gce_instance
GCP Project ID: test-project
Severity: INFO
Message: Test audit log entry #0 from gcplogs2oci publish_test_message.py
```

## 5. Continuous Mode

For production-style long-running operation:

```bash
python -m bridge.main
```

Or use the Docker/Fluentd path (see [ARCHITECTURE.md](ARCHITECTURE.md)):

```bash
docker build -t gcp-oci-bridge:latest docker/
docker run --rm \
    -v "$PWD/gcp-sa-key.json:/mnt/secrets/gcp-key.json:ro" \
    -e GCP_PROJECT_ID="$GCP_PROJECT_ID" \
    -e GCP_PUBSUB_TOPIC="$GCP_PUBSUB_TOPIC" \
    -e GCP_PUBSUB_SUBSCRIPTION="$GCP_PUBSUB_SUBSCRIPTION" \
    -e OCI_STREAM_POOL_ENDPOINT="$OCI_STREAM_POOL_ENDPOINT" \
    -e OCI_KAFKA_USERNAME="$OCI_KAFKA_USERNAME" \
    -e OCI_AUTH_TOKEN="$OCI_AUTH_TOKEN" \
    gcp-oci-bridge:latest
```

## 6. Querying Logs in OCI Log Analytics

Once logs are flowing, use these sample queries in the OCI Console (Log Explorer) or via CLI:

```
# Count logs by GCP resource type
'Cloud Provider' = GCP | stats count by 'GCP Resource Type'

# Find audit logs by a specific principal
'GCP Principal Email' = 'user@example.com' | sort by Time desc

# Errors from a specific GCP project
'GCP Project ID' = 'my-project' AND Severity = ERROR | head 20

# Cloud Run HTTP request analysis
'GCP HTTP Method' = GET | fields 'GCP HTTP URL', 'GCP HTTP Status', 'GCP HTTP Latency', 'GCP HTTP User Agent'

# Cloud Run service overview
'GCP Resource Type' = cloud_run_revision | stats count by 'GCP Cloud Run Service', 'GCP Location'

# Multicloud: compare log volume across cloud providers
* | stats count by 'Cloud Provider'
```

See the [Architecture doc](ARCHITECTURE.md) for the full field mapping reference.
