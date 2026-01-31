#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# setup_gcp.sh – Provision GCP Pub/Sub resources for the bridge
#
# Prerequisites:
#   - gcloud CLI authenticated (gcloud auth login)
#   - .env.local populated with GCP_PROJECT_ID at minimum
#
# Usage:
#   ./scripts/setup_gcp.sh
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment
if [ -f "$PROJECT_DIR/.env.local" ]; then
    set -a; source "$PROJECT_DIR/.env.local"; set +a
    echo "Loaded .env.local"
elif [ -f "$PROJECT_DIR/.env" ]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
    echo "Loaded .env"
else
    echo "ERROR: No .env.local or .env found. Copy .env.example to .env.local and fill in values."
    exit 1
fi

PROJECT="${GCP_PROJECT_ID:?GCP_PROJECT_ID is required}"
TOPIC="${GCP_PUBSUB_TOPIC:-oci-log-export-topic}"
SUBSCRIPTION="${GCP_PUBSUB_SUBSCRIPTION:-fluentd-oci-bridge-sub}"
SINK_NAME="${GCP_LOG_SINK_NAME:-gcp-to-oci-sink}"
LOG_FILTER="${GCP_LOG_FILTER:-severity >= ERROR}"
SA_NAME="${GCP_SA_NAME:-oci-log-shipper-sa}"

echo "============================================================"
echo "  GCP Setup for gcplogs2oci"
echo "============================================================"
echo "  Project:      $PROJECT"
echo "  Topic:        $TOPIC"
echo "  Subscription: $SUBSCRIPTION"
echo "  Sink:         $SINK_NAME"
echo "  Filter:       $LOG_FILTER"
echo "============================================================"
echo ""

gcloud config set project "$PROJECT"

# ── 0. Enable required APIs ──────────────────────────────────
echo "0/5  Enabling required GCP APIs..."
gcloud services enable pubsub.googleapis.com logging.googleapis.com --quiet
echo "     Pub/Sub and Cloud Logging APIs enabled."
echo ""

# ── 1. Create Pub/Sub Topic ─────────────────────────────────
echo "1/5  Creating Pub/Sub topic: $TOPIC"
if gcloud pubsub topics describe "$TOPIC" &>/dev/null; then
    echo "     Topic already exists, skipping."
else
    gcloud pubsub topics create "$TOPIC" \
        --message-retention-duration=7d
    echo "     Topic created with 7-day retention."
fi

# ── 2. Create Pull Subscription ─────────────────────────────
echo "2/5  Creating Pull subscription: $SUBSCRIPTION"
if gcloud pubsub subscriptions describe "$SUBSCRIPTION" &>/dev/null; then
    echo "     Subscription already exists, skipping."
else
    gcloud pubsub subscriptions create "$SUBSCRIPTION" \
        --topic="$TOPIC" \
        --ack-deadline=60 \
        --expiration-period=never \
        --message-retention-duration=7d
    echo "     Subscription created (ack deadline 60s, no expiration)."
fi

# ── 3. Create Log Router Sink ────────────────────────────────
echo "3/5  Creating Log Router sink: $SINK_NAME"
TOPIC_FULL="pubsub.googleapis.com/projects/$PROJECT/topics/$TOPIC"
if gcloud logging sinks describe "$SINK_NAME" &>/dev/null; then
    echo "     Sink already exists, skipping."
else
    gcloud logging sinks create "$SINK_NAME" "$TOPIC_FULL" \
        --log-filter="$LOG_FILTER"
    echo "     Sink created."
fi

# Grant the sink's service account publish access to the topic
SINK_SA=$(gcloud logging sinks describe "$SINK_NAME" --format='value(writerIdentity)')
echo "     Granting sink writer ($SINK_SA) publish access..."
gcloud pubsub topics add-iam-policy-binding "$TOPIC" \
    --member="$SINK_SA" \
    --role="roles/pubsub.publisher" \
    --quiet
echo "     IAM binding set."

# ── 4. Create Service Account ────────────────────────────────
echo "4/5  Creating service account: $SA_NAME"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
if gcloud iam service-accounts describe "$SA_EMAIL" &>/dev/null; then
    echo "     Service account already exists."
else
    gcloud iam service-accounts create "$SA_NAME" \
        --display-name="OCI Log Shipper Service Account"
    echo "     Service account created."
fi

echo "     Granting Pub/Sub Subscriber + Viewer roles..."
for ROLE in roles/pubsub.subscriber roles/pubsub.viewer; do
    gcloud projects add-iam-policy-binding "$PROJECT" \
        --member="serviceAccount:$SA_EMAIL" \
        --role="$ROLE" \
        --quiet
done
echo "     Roles granted."

# ── 5. Generate Service Account Key ─────────────────────────
KEY_FILE="$PROJECT_DIR/gcp-sa-key.json"
if [ -f "$KEY_FILE" ]; then
    echo "5/5  Key file already exists at $KEY_FILE, skipping."
else
    echo "5/5  Generating service account key..."
    gcloud iam service-accounts keys create "$KEY_FILE" \
        --iam-account="$SA_EMAIL"
    echo "     Key saved to $KEY_FILE"
    echo "     IMPORTANT: This file is in .gitignore. Never commit it."
fi

echo ""
echo "============================================================"
echo "  GCP Setup Complete"
echo "============================================================"
echo ""
echo "Next steps:"
echo "  1. Set GOOGLE_APPLICATION_CREDENTIALS=$KEY_FILE in .env.local"
echo "  2. Run: python scripts/test_gcp_credentials.py"
echo "  3. Run: python scripts/test_oci_credentials.py"
echo "  4. Run: python -m bridge.main --drain"
echo ""
