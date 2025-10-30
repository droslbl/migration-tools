#!/bin/bash

# Entity Comparison Script
# Compares NGSI-LD entities between source and target Scorpio brokers

set -euo pipefail

# Configuration
SRC_API="${SRC_API:-http://127.0.0.1:9090}"
TGT_API="${TGT_API:-http://127.0.0.1:9092}"
LIMIT="${ENTITY_LIMIT:-1000}"

# Get script directory and set logs path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to get entity types from an API
get_types() {
    local url="$1"
    local endpoint="${url}/ngsi-ld/v1/types"

    local response
    response=$(curl -s -w "\n%{http_code}" "${endpoint}")
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    if [ "$http_code" -eq 200 ]; then
        echo "$body" | jq -r '.typeList[]' 2>/dev/null || echo ""
    else
        echo "ERROR: Failed to get types from ${url} (HTTP ${http_code})" >&2
        return 1
    fi
}

# Function to get entities of a specific type
get_entities() {
    local url="$1"
    local type="$2"
    local endpoint="${url}/ngsi-ld/v1/entities?type=${type}&limit=${LIMIT}"

    local response
    response=$(curl -s -w "\n%{http_code}" "${endpoint}")
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    if [ "$http_code" -eq 200 ]; then
        echo "$body"
    else
        echo "[]"
    fi
}

# Function to extract entity IDs from JSON array
get_entity_ids() {
    local entities="$1"
    echo "$entities" | jq -r '.[].id' 2>/dev/null || echo ""
}

# Function to find items in list1 not in list2
get_missing() {
    local list1="$1"
    local list2="$2"

    local missing=""
    while IFS= read -r item; do
        if [ -n "$item" ] && ! echo "$list2" | grep -qxF "$item"; then
            missing="${missing}${item}"$'\n'
        fi
    done <<< "$list1"

    echo "$missing" | grep -v '^$' || echo ""
}

# Function to log discrepancies to files
log_discrepancies() {
    local type="$1"
    local missing_in_tgt="$2"
    local missing_in_src="$3"
    local src_count="$4"
    local tgt_count="$5"

    # Create type-specific directory
    local type_dir="${LOGS_DIR}/${type}"
    mkdir -p "${type_dir}"

    # Create summary file
    local summary_file="${type_dir}/summary.txt"
    {
        echo "Entity Type: ${type}"
        echo "Timestamp: ${TIMESTAMP}"
        echo "Source API: ${SRC_API}"
        echo "Target API: ${TGT_API}"
        echo ""
        echo "Entity Counts:"
        echo "  Source: ${src_count}"
        echo "  Target: ${tgt_count}"
        echo ""
        echo "Discrepancies:"
        local missing_in_tgt_count=0
        local missing_in_src_count=0

        if [ -n "$missing_in_tgt" ]; then
            missing_in_tgt_count=$(echo "$missing_in_tgt" | wc -l)
        fi

        if [ -n "$missing_in_src" ]; then
            missing_in_src_count=$(echo "$missing_in_src" | wc -l)
        fi

        echo "  Missing in target: ${missing_in_tgt_count}"
        echo "  Extra in target: ${missing_in_src_count}"
    } > "${summary_file}"

    # Log missing in target
    if [ -n "$missing_in_tgt" ]; then
        local missing_file="${type_dir}/missing_in_target.txt"
        {
            echo "# Entities present in SOURCE but MISSING in TARGET"
            echo "# Type: ${type}"
            echo "# Timestamp: ${TIMESTAMP}"
            echo "# Total: $(echo "$missing_in_tgt" | wc -l)"
            echo ""
            echo "$missing_in_tgt"
        } > "${missing_file}"
    fi

    # Log extra in target
    if [ -n "$missing_in_src" ]; then
        local extra_file="${type_dir}/extra_in_target.txt"
        {
            echo "# Entities present in TARGET but NOT in SOURCE"
            echo "# Type: ${type}"
            echo "# Timestamp: ${TIMESTAMP}"
            echo "# Total: $(echo "$missing_in_src" | wc -l)"
            echo ""
            echo "$missing_in_src"
        } > "${extra_file}"
    fi
}

# Main execution
main() {
    echo "=================================================="
    echo "NGSI-LD Entity Comparison"
    echo "=================================================="
    echo "Source API: ${SRC_API}"
    echo "Target API: ${TGT_API}"
    echo "Entity Limit: ${LIMIT}"
    echo "Logs Directory: ${LOGS_DIR}"
    echo "=================================================="
    echo ""

    # Clean and create logs directory
    if [ -d "${LOGS_DIR}" ]; then
        echo "Cleaning previous logs..."
        rm -rf "${LOGS_DIR}"
    fi
    mkdir -p "${LOGS_DIR}"
    echo "Logs will be saved to: ${LOGS_DIR}"
    echo ""

    # Get types from both APIs
    echo "Fetching entity types..."
    local src_types
    src_types=$(get_types "${SRC_API}")
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to get source types${NC}"
        exit 1
    fi

    local tgt_types
    tgt_types=$(get_types "${TGT_API}")
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to get target types${NC}"
        exit 1
    fi

    # Compare types
    echo "Comparing entity types..."
    local missing_in_target
    missing_in_target=$(get_missing "$src_types" "$tgt_types")
    local missing_in_source
    missing_in_source=$(get_missing "$tgt_types" "$src_types")

    if [ -n "$missing_in_target" ] || [ -n "$missing_in_source" ]; then
        if [ -n "$missing_in_target" ]; then
            echo -e "${YELLOW}Types in source but not in target:${NC}"
            echo "$missing_in_target"
        fi
        if [ -n "$missing_in_source" ]; then
            echo -e "${YELLOW}Types in target but not in source:${NC}"
            echo "$missing_in_source"
        fi
    else
        echo -e "${GREEN}All types match between source and target${NC}"
    fi

    echo ""
    echo "Source types:"
    echo "$src_types"
    echo ""

    # Compare entities for each type
    echo "=================================================="
    echo "Comparing entities by type..."
    echo "=================================================="

    local total_src=0
    local total_tgt=0
    local total_missing_in_target=0
    local total_missing_in_source=0

    while IFS= read -r type; do
        if [ -z "$type" ]; then
            continue
        fi

        echo ""
        echo "Processing type: ${type}"

        # Get entities from both APIs
        local src_entities
        src_entities=$(get_entities "${SRC_API}" "$type")
        local src_count
        src_count=$(echo "$src_entities" | jq '. | length' 2>/dev/null || echo 0)

        local tgt_entities
        tgt_entities=$(get_entities "${TGT_API}" "$type")
        local tgt_count
        tgt_count=$(echo "$tgt_entities" | jq '. | length' 2>/dev/null || echo 0)

        # Update totals
        total_src=$((total_src + src_count))
        total_tgt=$((total_tgt + tgt_count))

        # Get entity IDs
        local src_ids
        src_ids=$(get_entity_ids "$src_entities")
        local tgt_ids
        tgt_ids=$(get_entity_ids "$tgt_entities")

        # Find missing in each direction
        local missing_in_tgt
        missing_in_tgt=$(get_missing "$src_ids" "$tgt_ids")
        local missing_in_src
        missing_in_src=$(get_missing "$tgt_ids" "$src_ids")

        local missing_in_tgt_count=0
        local missing_in_src_count=0
        
        if [ -n "$missing_in_tgt" ]; then
            missing_in_tgt_count=$(echo "$missing_in_tgt" | wc -l)
        fi
        
        if [ -n "$missing_in_src" ]; then
            missing_in_src_count=$(echo "$missing_in_src" | wc -l)
        fi

        total_missing_in_target=$((total_missing_in_target + missing_in_tgt_count))
        total_missing_in_source=$((total_missing_in_source + missing_in_src_count))

        # Print results
        if [ "$src_count" -eq "$tgt_count" ] && [ "$missing_in_tgt_count" -eq 0 ] && [ "$missing_in_src_count" -eq 0 ]; then
            echo -e "${GREEN}✓ ${type}: ${src_count}/${tgt_count} entities (perfect match)${NC}"
        else
            echo -e "${YELLOW}⚠ ${type}: ${src_count}/${tgt_count} entities${NC}"

            if [ "$missing_in_tgt_count" -gt 0 ]; then
                echo -e "  ${RED}Missing in TARGET: ${missing_in_tgt_count}${NC}"
                if [ "$missing_in_tgt_count" -le 5 ]; then
                    echo "$missing_in_tgt" | sed 's/^/    /'
                else
                    echo "$missing_in_tgt" | head -5 | sed 's/^/    /'
                    echo "    ... and $((missing_in_tgt_count - 5)) more"
                fi
            fi

            if [ "$missing_in_src_count" -gt 0 ]; then
                echo -e "  ${BLUE}Extra in TARGET (not in source): ${missing_in_src_count}${NC}"
                if [ "$missing_in_src_count" -le 5 ]; then
                    echo "$missing_in_src" | sed 's/^/    /'
                else
                    echo "$missing_in_src" | head -5 | sed 's/^/    /'
                    echo "    ... and $((missing_in_src_count - 5)) more"
                fi
            fi

            # Log discrepancies to files
            echo "  📝 Logging details to: logs/${type}/"
            log_discrepancies "$type" "$missing_in_tgt" "$missing_in_src" "$src_count" "$tgt_count"
        fi

        echo "  Total entities so far: ${total_src}/${total_tgt}"

    done <<< "$src_types"

    # Final summary
    echo ""
    echo "=================================================="
    echo "Summary"
    echo "=================================================="
    echo "Total source entities: ${total_src}"
    echo "Total target entities: ${total_tgt}"
    echo -e "${RED}Missing in target: ${total_missing_in_target}${NC}"
    echo -e "${BLUE}Extra in target: ${total_missing_in_source}${NC}"
    echo ""

    # Create master summary file
    local master_summary="${LOGS_DIR}/master_summary.txt"
    {
        echo "================================================================"
        echo "NGSI-LD Entity Migration Comparison - Master Summary"
        echo "================================================================"
        echo "Timestamp: ${TIMESTAMP}"
        echo "Source API: ${SRC_API}"
        echo "Target API: ${TGT_API}"
        echo ""
        echo "Overall Statistics:"
        echo "  Total source entities: ${total_src}"
        echo "  Total target entities: ${total_tgt}"
        echo "  Missing in target: ${total_missing_in_target}"
        echo "  Extra in target: ${total_missing_in_source}"
        echo ""
        echo "Detailed logs available in subdirectories by entity type:"

        # List all type directories
        for type_dir in "${LOGS_DIR}"/*/ ; do
            if [ -d "$type_dir" ]; then
                local type_name=$(basename "$type_dir")
                echo "  - ${type_name}/"
            fi
        done
    } > "${master_summary}"

    if [ "$total_src" -eq "$total_tgt" ] && [ "$total_missing_in_target" -eq 0 ] && [ "$total_missing_in_source" -eq 0 ]; then
        echo -e "${GREEN}✓ Migration successful: All entities match perfectly!${NC}"
        echo ""
        echo "No discrepancies found. Logs directory is clean."
        exit 0
    else
        echo -e "${YELLOW}⚠ Differences detected${NC}"
        echo ""
        echo "=================================================="
        echo "Detailed logs saved to:"
        echo "  ${LOGS_DIR}"
        echo ""
        echo "Files created:"
        echo "  - master_summary.txt (this summary)"
        echo "  - [type]/summary.txt (per-type summary)"
        echo "  - [type]/missing_in_target.txt (IDs in source but not in target)"
        echo "  - [type]/extra_in_target.txt (IDs in target but not in source)"
        echo "=================================================="
        exit 1
    fi
}

# Run main function
main "$@"
