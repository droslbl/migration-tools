#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MIGRATOR_JAR_DIR="${PROJECT_ROOT}/migrator-jar"

# Broker URLs (using localhost ports)
SOURCE_BROKER="http://localhost:9090"
TARGET_BROKER="http://localhost:9092"

echo "🔄 Starting TM Forum data migration from v0.31.2 to v1.3.13..."

# Check if both environments are running
check_environment() {
    local namespace=$1
    local service=$2

    echo "🔍 Checking ${namespace} environment..."

    if ! kubectl get namespace "${namespace}" &> /dev/null; then
        echo "❌ Namespace ${namespace} not found. Please deploy the environment first."
        exit 1
    fi

    if ! kubectl get pods -n "${namespace}" | grep -q "Running"; then
        echo "❌ No running pods found in ${namespace}. Please check the deployment."
        exit 1
    fi

    # Check if Scorpio service is accessible
    if ! kubectl get svc -n "${namespace}" "${service}" &> /dev/null; then
        echo "❌ Service ${service} not found in ${namespace}."
        exit 1
    fi

    echo "✅ ${namespace} environment is ready"
}

# Pre-migration checks
echo "🔍 Performing pre-migration checks..."

# Check Java installation
if ! command -v java &> /dev/null; then
    echo "❌ Java is not installed. Please install Java 11 or higher."
    exit 1
fi

JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | awk -F '.' '{print $1}')
echo "✅ Java version: $(java -version 2>&1 | head -n 1)"

# Check migrator JAR files exist
if [[ ! -f "${MIGRATOR_JAR_DIR}/legacy-loader-0.1.jar" ]]; then
    echo "❌ legacy-loader-0.1.jar not found in ${MIGRATOR_JAR_DIR}"
    exit 1
fi

if [[ ! -f "${MIGRATOR_JAR_DIR}/migrator-0.1.jar" ]]; then
    echo "❌ migrator-0.1.jar not found in ${MIGRATOR_JAR_DIR}"
    exit 1
fi

if [[ ! -f "${MIGRATOR_JAR_DIR}/update-writer-0.1.jar" ]]; then
    echo "❌ update-writer-0.1.jar not found in ${MIGRATOR_JAR_DIR}"
    exit 1
fi

echo "✅ All migration JAR files found"

check_environment "tmforum-source" "scorpio-source"
check_environment "tmforum-target" "scorpio-target"

# Check if source has data (assumes port-forward already set up)
echo "📊 Checking source environment for data..."
SOURCE_POD=$(kubectl get pods -n tmforum-source -l app.kubernetes.io/name=scorpio -o jsonpath='{.items[0].metadata.name}')

if [[ -n "$SOURCE_POD" ]]; then
    # Check entities (expects localhost:9090 to be accessible)
    ENTITY_COUNT=$(curl -s "http://localhost:9090/ngsi-ld/v1/entities" \
        -H "Accept: application/json" | jq '. | length' 2>/dev/null || echo "0")

    if [[ "$ENTITY_COUNT" != "0" ]]; then
        echo "📈 Found ${ENTITY_COUNT} entities in source environment"
    else
        echo "⚠️  WARNING: No entities found or source not accessible at localhost:9090"
        echo "   To check data: kubectl port-forward -n tmforum-source pod/${SOURCE_POD} 9090:9090"
        echo "   Consider populating with test data first"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Migration cancelled"
            exit 0
        fi
    fi
else
    echo "⚠️  Could not find source pod - proceeding with migration"
fi

# Run migration using JAR files
echo ""
echo "🚀 Starting data migration using migrator JAR..."
echo "   Read Broker (-rB): ${SOURCE_BROKER} (source v0.31.2 data)"
echo "   Write Broker (-wB): ${TARGET_BROKER} (target v1.3.13 data)"
echo "   Legacy Loader: ${MIGRATOR_JAR_DIR}/legacy-loader-0.1.jar"
echo "   Update Writer: ${MIGRATOR_JAR_DIR}/update-writer-0.1.jar"
echo ""

MIGRATION_FAILED=false

# Run the migration command
# Reads from SOURCE (localhost:9090) and writes to TARGET (localhost:9092)
echo "🔄 Running migration..."
if java --add-opens java.base/java.lang=ALL-UNNAMED \
    -jar "${MIGRATOR_JAR_DIR}/migrator-0.1.jar" \
    -rB "${SOURCE_BROKER}" \
    -wB "${TARGET_BROKER}" \
    -ll "${MIGRATOR_JAR_DIR}/legacy-loader-0.1.jar" \
    -uw "${MIGRATOR_JAR_DIR}/update-writer-0.1.jar" 2>&1 | tee /tmp/migration.log; then
    echo ""
    echo "✅ Migration completed successfully!"
else
    echo ""
    echo "❌ Migration failed!"
    echo "   Check logs at: /tmp/migration.log"
    MIGRATION_FAILED=true
    exit 1
fi

echo ""
echo "📋 Migration log saved to: /tmp/migration.log"
echo ""

# Verify target environment has data
if [[ "$MIGRATION_FAILED" == "false" ]]; then
    echo ""
    echo "🔍 Verifying target environment..."

    TARGET_POD=$(kubectl get pods -n tmforum-target -l app.kubernetes.io/name=scorpio -o jsonpath='{.items[0].metadata.name}')

    if [[ -n "$TARGET_POD" ]]; then
        # Check entities (expects localhost:9092 to be accessible)
        TARGET_ENTITY_COUNT=$(curl -s "http://localhost:9092/ngsi-ld/v1/types" \
            -H "Accept: application/json" | jq -r '.typeList[]?' || echo "0")

        if [[ "$TARGET_ENTITY_COUNT" != "0" ]]; then
            echo "📈 Target environment now has ${TARGET_ENTITY_COUNT} types"
            echo "✅ Migration verification successful!"
            echo ""
            echo "🔄 Next steps:"
            echo "   Validate migration: ../validation/entity_compare.sh"
        else
            echo "⚠️  WARNING: No entities found or target not accessible at localhost:9092"
            echo "   To verify: kubectl port-forward -n tmforum-target pod/${TARGET_POD} 9092:9090"
        fi
    fi
fi