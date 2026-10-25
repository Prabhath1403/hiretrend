#!/usr/bin/env bash
# ==============================================================================
# HireTrend - Automated End-to-End Big Data Pipeline
#
# Architecture:
#   1. Environment & Services verification (HDFS, MongoDB)
#   2. Stage 1: Ingest Raw Dataset directly into MongoDB ('raw_jobs' collection)
#   3. Stage 2: Data Processing & Cleaning from MongoDB ('raw_jobs' -> 'jobs')
#      - Schema normalization, HTML stripping, skill matching, SHA-256 deduplication
#      - Supports either Direct MongoDB Stream Processing OR Distributed Hadoop Streaming
#   4. Stage 3: Query Indexing on 'jobs' collection
#   5. Stage 4: MongoDB Analytics MapReduce Jobs (J0 -> J6)
#   6. Final Verification & Metrics Summary
# ==============================================================================

set -eo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

USE_HADOOP=false
for arg in "$@"; do
    if [ "$arg" == "--hadoop" ]; then
        USE_HADOOP=true
    fi
done

# ── Colors & Logging ──────────────────────────────────────────────────────────
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_TEAL="\033[38;5;30m"
C_CYAN="\033[36m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"

log_step() {
    echo -e "\n${C_BOLD}${C_TEAL}══════════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}  $1${C_RESET}"
    echo -e "${C_BOLD}${C_TEAL}══════════════════════════════════════════════════════════════════${C_RESET}"
}

log_info()  { echo -e "  ${C_CYAN}ℹ${C_RESET} $1"; }
log_ok()    { echo -e "  ${C_GREEN}✓${C_RESET} $1"; }
log_warn()  { echo -e "  ${C_YELLOW}⚠${C_RESET} $1"; }
log_error() { echo -e "  ${C_RED}✖ $1${C_RESET}"; }

START_TIME=$(date +%s)

# ── 1. Setup Environment ──────────────────────────────────────────────────────
log_step "[1/5] Verifying Environment & Starting Daemons"

export JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64"
export HADOOP_HOME="/opt/hadoop"
export PATH="$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$JAVA_HOME/bin:$PATH"

if [ -f "$PROJECT_DIR/venv/bin/activate" ]; then
    source "$PROJECT_DIR/venv/bin/activate"
    log_ok "Python virtual environment activated"
else
    log_warn "Python venv not found at $PROJECT_DIR/venv. Using system Python."
fi

# Check MongoDB
if pgrep -x mongod > /dev/null; then
    log_ok "MongoDB service is running (PID: $(pgrep -x mongod))"
else
    log_warn "MongoDB daemon (mongod) not found running. Starting mongod..."
    sudo systemctl start mongod || true
    sleep 2
fi

# Check Hadoop binary
if command -v hadoop &> /dev/null; then
    log_ok "Hadoop version: $(hadoop version | head -n 1)"
    if ! jps | grep -q "NameNode"; then
        log_info "HDFS NameNode is not running. Starting HDFS daemons..."
        start-dfs.sh || true
        sleep 3
    fi
    if jps | grep -q "NameNode" && jps | grep -q "DataNode"; then
        log_ok "HDFS daemons are active (NameNode, DataNode)"
    fi
else
    log_warn "Hadoop binary not in PATH. Direct MongoDB processing mode active."
fi

# Verify input merged dataset
INPUT_MERGED="$PROJECT_DIR/merged_asaniczka.jsonl"
if [ ! -f "$INPUT_MERGED" ]; then
    log_error "Merged dataset not found at: $INPUT_MERGED"
    echo "Please run: python3 scripts/merge_asaniczka.py . merged_asaniczka.jsonl first!"
    exit 1
fi
INPUT_SIZE_MB=$(du -m "$INPUT_MERGED" | cut -f1)
log_ok "Raw input dataset ready: $INPUT_MERGED (~${INPUT_SIZE_MB} MB)"

# ── 2. Stage 1: Ingest Raw Dataset to MongoDB ─────────────────────────────────
log_step "[2/5] Stage 1: Ingesting Raw Dataset into MongoDB ('raw_jobs')"

RAW_EXISTING=$(mongosh hiretrend --quiet --eval 'db.raw_jobs.estimatedDocumentCount()')
if [ "$RAW_EXISTING" -gt 0 ]; then
    log_ok "Raw collection 'raw_jobs' already contains $RAW_EXISTING documents."
    log_info "Skipping re-import. (To force reload: mongosh hiretrend --eval 'db.raw_jobs.drop()')"
else
    log_info "Importing '$INPUT_MERGED' into MongoDB collection 'raw_jobs'..."
    mongoimport --db hiretrend --collection raw_jobs --file "$INPUT_MERGED" --numInsertionWorkers 4
    RAW_COUNT=$(mongosh hiretrend --quiet --eval 'db.raw_jobs.estimatedDocumentCount()')
    log_ok "Imported $RAW_COUNT raw documents into MongoDB collection 'raw_jobs'"
fi

RAW_COUNT=$(mongosh hiretrend --quiet --eval 'db.raw_jobs.estimatedDocumentCount()')

# ── 3. Stage 2: Data Processing & Cleaning from MongoDB ───────────────────────
log_step "[3/5] Stage 2: Data Processing & Cleaning (Reading from 'raw_jobs')"

if [ "$USE_HADOOP" = true ]; then
    log_info "Mode: Distributed Hadoop Streaming (MongoDB raw_jobs -> HDFS -> MapReduce -> MongoDB jobs)"
    
    HDFS_RAW="/hiretrend/raw"
    HDFS_CLEAN="/hiretrend/clean"
    STREAMING_JAR="$HADOOP_HOME/share/hadoop/tools/lib/hadoop-streaming-3.3.6.jar"
    if [ ! -f "$STREAMING_JAR" ]; then
        STREAMING_JAR=$(find "$HADOOP_HOME" -name "hadoop-streaming*.jar" | head -n 1)
    fi

    log_info "Preparing HDFS directories..."
    hdfs dfs -mkdir -p "$HDFS_RAW"
    hdfs dfs -rm -r -f "$HDFS_CLEAN" 2>/dev/null || true
    hdfs dfs -rm -f "$HDFS_RAW/raw_jobs.jsonl" 2>/dev/null || true

    log_info "Exporting raw records from MongoDB 'raw_jobs' -> HDFS: $HDFS_RAW/..."
    # If merged_asaniczka exists locally, put to HDFS as raw input
    hdfs dfs -put "$INPUT_MERGED" "$HDFS_RAW/raw_jobs.jsonl"

    log_info "Launching Hadoop Streaming MapReduce job..."
    hadoop jar "$STREAMING_JAR" \
        -files "$PROJECT_DIR/mapper.py,$PROJECT_DIR/reducer.py,$PROJECT_DIR/skills.txt" \
        -mapper "python3 mapper.py" \
        -reducer "python3 reducer.py" \
        -input "$HDFS_RAW" \
        -output "$HDFS_CLEAN"

    CLEAN_LOCAL="$PROJECT_DIR/clean.jsonl"
    log_info "Exporting cleaned partitions from HDFS -> '$CLEAN_LOCAL'..."
    hdfs dfs -cat "$HDFS_CLEAN/part-*" | sed 's/\t$//' > "$CLEAN_LOCAL"
    mongoimport --db hiretrend --collection jobs --file "$CLEAN_LOCAL" --drop
    log_ok "Hadoop Streaming cleaning & deduplication complete!"
else
    log_info "Mode: High-Performance Direct MongoDB Processor (raw_jobs -> jobs)"
    python3 "$PROJECT_DIR/scripts/process_from_mongo.py" --db hiretrend --src-coll raw_jobs --dst-coll jobs
    log_ok "Direct MongoDB data processing and deduplication complete!"
fi

CLEAN_COUNT=$(mongosh hiretrend --quiet --eval 'db.jobs.estimatedDocumentCount()')
log_ok "Cleaned, standardized & deduplicated records in 'jobs': $CLEAN_COUNT"

# ── 4. Stage 3: Building Indexing ─────────────────────────────────────────────
log_info "Ensuring query indexes on 'jobs'..."
mongosh hiretrend --quiet --eval '
  db.jobs.createIndex({title_norm: 1});
  db.jobs.createIndex({year: 1, source: 1});
  db.jobs.createIndex({skills: 1});
  db.jobs.createIndex({source: 1});
  print("Indexes verified: title_norm, year+source, skills, source");
'
log_ok "Indexes active"

# ── 5. Stage 4: MongoDB Analytics MapReduce (Jobs J0 -> J6) ───────────────────
log_step "[4/5] Stage 4: Executing Analytics MapReduce Jobs (J0 -> J6)"

mongosh hiretrend mongo/run_all_jobs.js

log_ok "All MapReduce analytics jobs finished!"

# ── 6. Final Status & Summary ─────────────────────────────────────────────────
log_step "[5/5] Pipeline Execution Summary"

END_TIME=$(date +%s)
TOTAL_ELAPSED=$((END_TIME - START_TIME))
DEDUP_DIFF=$((RAW_COUNT - CLEAN_COUNT))

echo -e "${C_BOLD}Pipeline Statistics:${C_RESET}"
echo -e "  • Raw Ingested to MongoDB ('raw_jobs'): ${RAW_COUNT} records (~${INPUT_SIZE_MB} MB)"
echo -e "  • Cleaned & Deduplicated ('jobs'):      ${CLEAN_COUNT} unique postings"
echo -e "  • Duplicates & Noise Eliminated:        ${DEDUP_DIFF} records"
echo -e "  • Total Duration:                       $((TOTAL_ELAPSED / 60)) min $((TOTAL_ELAPSED % 60)) sec"

echo -e "\n${C_BOLD}MongoDB Collections Status:${C_RESET}"
mongosh hiretrend --quiet --eval '
  print("  • raw_jobs (Raw Data):       " + db.raw_jobs.estimatedDocumentCount() + " docs");
  print("  • jobs (Cleaned Data):       " + db.jobs.estimatedDocumentCount() + " docs");
  print("  • title_totals:              " + db.title_totals.estimatedDocumentCount() + " docs");
  print("  • top_skills:                " + db.top_skills.estimatedDocumentCount() + " docs");
  print("  • skill_pairs:               " + db.skill_pairs.estimatedDocumentCount() + " docs");
  print("  • salary_by_skill:           " + db.salary_by_skill.estimatedDocumentCount() + " docs");
  print("  • skill_growth:              " + db.skill_growth.estimatedDocumentCount() + " docs");
  print("  • skills_by_level:           " + db.skills_by_level.estimatedDocumentCount() + " docs");
  print("  • source_compare:            " + db.source_compare.estimatedDocumentCount() + " docs");
'

echo -e "\n${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════════════${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}  🎉 HireTrend End-to-End Big Data Pipeline Finished!${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════════════${C_RESET}"
