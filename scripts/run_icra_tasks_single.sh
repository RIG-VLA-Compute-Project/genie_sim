#!/bin/bash

# Run icra_*.yaml configs under source/geniesim/config/.
# Usage:
#   ./scripts/run_icra_tasks.sh [--infer-host HOST:PORT] [--task TASK_NAME]
#
# Examples:
#   ./scripts/run_icra_tasks.sh --task icra_pick_place
#   ./scripts/run_icra_tasks.sh --task pick_place
#   ./scripts/run_icra_tasks.sh --infer-host 127.0.0.1:8000 --task icra_pick_place

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/source/geniesim/config"
OUTPUT_DIR="${PROJECT_ROOT}/output"
BENCHMARK_DIR="${OUTPUT_DIR}/benchmark"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 [--infer-host HOST:PORT] [--task TASK_NAME]"
    echo ""
    echo "Examples:"
    echo "  $0"
    echo "  $0 --task icra_pick_place"
    echo "  $0 --task pick_place"
    echo "  $0 --infer-host 127.0.0.1:8000 --task icra_pick_place"
}

print_available_tasks() {
    echo -e "${YELLOW}Available tasks:${NC}"
    find "${CONFIG_DIR}" -maxdepth 1 -name "icra_*.yaml" -type f \
        -exec basename {} .yaml \; | sort | sed 's/^/  - /'
}

# Parse arguments
INFER_HOST=""
TASK_NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --infer-host)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo -e "${RED}Error: --infer-host requires HOST:PORT${NC}"
                echo ""
                print_usage
                exit 1
            fi
            INFER_HOST="$2"
            shift 2
            ;;
        --task)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo -e "${RED}Error: --task requires TASK_NAME${NC}"
                echo ""
                print_usage
                exit 1
            fi
            TASK_NAME="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            echo ""
            print_usage
            exit 1
            ;;
    esac
done

# Trap Ctrl+C to run clean.sh before exiting
trap_cleanup() {
    echo -e "\n${YELLOW}Interrupted! Running cleanup...${NC}"
    bash "${SCRIPT_DIR}/clean.sh"
    exit 130
}
trap trap_cleanup SIGINT

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}ICRA Task Batch Runner${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Config directory: ${YELLOW}${CONFIG_DIR}${NC}"
if [ -n "${INFER_HOST}" ]; then
    echo -e "Override infer_host: ${YELLOW}${INFER_HOST}${NC}"
fi
if [ -n "${TASK_NAME}" ]; then
    echo -e "Selected task: ${YELLOW}${TASK_NAME}${NC}"
fi
echo -e "${GREEN}========================================${NC}\n"

if [ ! -d "${CONFIG_DIR}" ]; then
    echo -e "${RED}Error: Config directory not found: ${CONFIG_DIR}${NC}"
    exit 1
fi

# Build list of configs
if [ -n "${TASK_NAME}" ]; then
    if [[ "${TASK_NAME}" == icra_* ]]; then
        YAML_PATH="${CONFIG_DIR}/${TASK_NAME}.yaml"
    else
        YAML_PATH="${CONFIG_DIR}/icra_${TASK_NAME}.yaml"
    fi

    if [ ! -f "${YAML_PATH}" ]; then
        echo -e "${RED}Error: Task config not found for: ${TASK_NAME}${NC}"
        echo ""
        print_available_tasks
        exit 1
    fi

    ICRA_YAMLS=("${YAML_PATH}")
else
    mapfile -t ICRA_YAMLS < <(find "${CONFIG_DIR}" -maxdepth 1 -name "icra_*.yaml" -type f | sort)
fi

# If --infer-host is provided, create copies in /tmp with overridden infer_host
TEMP_CONFIG_DIR=""
if [ -n "${INFER_HOST}" ]; then
    TEMP_CONFIG_DIR="/tmp/icra_configs_$$"
    mkdir -p "${TEMP_CONFIG_DIR}"
    NEW_YAMLS=()
    for yaml in "${ICRA_YAMLS[@]}"; do
        TMP_YAML="${TEMP_CONFIG_DIR}/$(basename "${yaml}")"
        sed "s|infer_host:.*|infer_host: \"${INFER_HOST}\"|" "${yaml}" > "${TMP_YAML}"
        echo -e "  ${YELLOW}$(basename "${yaml}")${NC}: $(grep infer_host "${TMP_YAML}")"
        NEW_YAMLS+=("${TMP_YAML}")
    done
    ICRA_YAMLS=("${NEW_YAMLS[@]}")
    echo -e "${GREEN}Created ${#ICRA_YAMLS[@]} temp config(s) with infer_host=${INFER_HOST}${NC}\n"
fi

if [ ${#ICRA_YAMLS[@]} -eq 0 ]; then
    echo -e "${RED}Error: No icra_*.yaml files found in ${CONFIG_DIR}${NC}"
    exit 1
fi

# Back up benchmark dir only for batch runs
if [ -z "${TASK_NAME}" ] && [ -d "${BENCHMARK_DIR}" ]; then
    TIMESTAMP=$(date +%Y-%m-%d-%H)
    BACKUP_DIR="${OUTPUT_DIR}/benchmark_${TIMESTAMP}"
    echo -e "${YELLOW}Backing up ${BENCHMARK_DIR} -> ${BACKUP_DIR}${NC}"
    mv "${BENCHMARK_DIR}" "${BACKUP_DIR}"
    echo -e "${GREEN}Backup done.${NC}\n"
fi

echo -e "${GREEN}Found ${#ICRA_YAMLS[@]} icra config(s) to run${NC}\n"

SUCCESS_COUNT=0
FAILED_COUNT=0
declare -a FAILED_TASKS

for YAML_PATH in "${ICRA_YAMLS[@]}"; do
    CONFIG_NAME="$(basename "${YAML_PATH}" .yaml)"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Processing: ${YELLOW}${CONFIG_NAME}${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "  Config: ${YAML_PATH}\n"

    cd "${PROJECT_ROOT}" || exit 1
    /isaac-sim/python.sh source/geniesim/app/app.py --config "${YAML_PATH}"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Successfully completed: ${CONFIG_NAME}${NC}\n"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo -e "${RED}✗ Failed: ${CONFIG_NAME}${NC}\n"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_TASKS+=("${CONFIG_NAME}")
    fi

    echo ""
done

# Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Batch Run Summary${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Total configs: ${#ICRA_YAMLS[@]}"
echo -e "${GREEN}Successful: ${SUCCESS_COUNT}${NC}"
echo -e "${RED}Failed: ${FAILED_COUNT}${NC}"

if [ ${FAILED_COUNT} -gt 0 ]; then
    echo -e "\n${RED}Failed configs:${NC}"
    for task in "${FAILED_TASKS[@]}"; do
        echo -e "  - ${task}"
    done
fi

echo -e "${GREEN}========================================${NC}"

# Clean up temp configs
if [ -n "${TEMP_CONFIG_DIR}" ] && [ -d "${TEMP_CONFIG_DIR}" ]; then
    rm -rf "${TEMP_CONFIG_DIR}"
fi

# Auto-run score statistics if benchmark output exists
if [ -d "${BENCHMARK_DIR}" ]; then
    echo -e "\n${GREEN}Running score statistics...${NC}"
    python3 "${SCRIPT_DIR}/stat_average.py" "${BENCHMARK_DIR}"
fi

if [ ${FAILED_COUNT} -gt 0 ]; then
    exit 1
fi
exit 0
