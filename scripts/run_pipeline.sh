#!/usr/bin/env bash
# ==============================================================================
# HireTrend - Automated End-to-End Big Data Pipeline
#
# Steps:
#   1. Environment & Services verification (HDFS, MongoDB)
#   2. Stage 0: Normalization (normalize.py)
#   3. Stage 1: HDFS Upload & Hadoop Streaming MapReduce (mapper.py + reducer.py)
#   4. Stage 2: Export Clean Data & Ingest into MongoDB (mongoimport)
#   5. Stage 3: Run MongoDB Analytics MapReduce Jobs (J0 -> J6)
#   6. Verify Collections & Summary
# ==============================================================================

set -eo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

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
log_step "[1/6] Verifying Environment & Starting Daemons"

export JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64"
export HADOOP_HOME="/opt/hadoop"
export PATH="$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$JAVA_HOME/bin:$PATH"

if [ -f "$PROJECT_DIR/venv/bin/activate" ]; then
    source "$PROJECT_DIR/venv/bin/activate"
    log_ok "Python virtual environment activated"
else
    log_warn "Python venv not found at $PROJECT_DIR/venv. Using system Python."
fi

# Check Hadoop binary
if ! command -v hadoop &> /dev/null; then
    log_error "Hadoop binary not found in PATH ($HADOOP_HOME/bin)"
    exit 1
fi
log_ok "Hadoop version: $(hadoop version | head -n 1)"

# Check HDFS daemons (NameNode, DataNode)
if ! jps | grep -q "NameNode"; then
    log_info "HDFS NameNode is not running. Starting HDFS daemons..."
    start-dfs.sh
    sleep 3
fi
if jps | grep -q "NameNode" && jps | grep -q "DataNode"; then
    log_ok "HDFS daemons are active (NameNode, DataNode)"
else
    log_warn "HDFS daemons check: $(jps | tr '\n' ' ')"
fi

# Check MongoDB
if pgrep -x mongod > /dev/null; then
    log_ok "MongoDB service is running (PID: $(pgrep -x mongod))"
else
    log_warn "MongoDB daemon (mongod) not found running. Starting mongod..."
    sudo systemctl start mongod || true
    sleep 2
fi

# Verify input merged dataset
INPUT_MERGED="$PROJECT_DIR/merged_asaniczka.jsonl"
if [ ! -f "$INPUT_MERGED" ]; then
    log_error "Merged dataset not found at: $INPUT_MERGED"
    echo "Please run: python3 scripts/merge_asaniczka.py . merged_asaniczka.jsonl first!"
    exit 1
fi
INPUT_SIZE_MB=$(du -m "$INPUT_MERGED" | cut -f1)
log_ok "Input dataset ready: $INPUT_MERGED (~${INPUT_SIZE_MB} MB)"

# ── 2. Stage 0: Schema Normalization ──────────────────────────────────────────
log_step "[2/6] Stage 0: Schema Normalization (normalize.py)"

NORM_FILE="/tmp/norm_asaniczka.jsonl"
log_info "Normalizing '$INPUT_MERGED' -> '$NORM_FILE'..."
python3 normalize.py asaniczka "$INPUT_MERGED" "$NORM_FILE"

NORM_COUNT=$(wc -l < "$NORM_FILE")
log_ok "Normalized $NORM_COUNT records in $NORM_FILE"

# ── 3. Stage 1: HDFS Upload & Hadoop Streaming MapReduce ──────────────────────
log_step "[3/6] Stage 1: Hadoop Distributed Processing & Deduplication"

HDFS_RAW="/hiretrend/raw"
HDFS_CLEAN="/hiretrend/clean"
STREAMING_JAR="$HADOOP_HOME/share/hadoop/tools/lib/hadoop-streaming-3.3.6.jar"

if [ ! -f "$STREAMING_JAR" ]; then
    STREAMING_JAR=$(find "$HADOOP_HOME" -name "hadoop-streaming*.jar" | head -n 1)
fi

log_info "Preparing HDFS directories..."
hdfs dfs -mkdir -p "$HDFS_RAW"
hdfs dfs -rm -r -f "$HDFS_CLEAN" 2>/dev/null || true
hdfs dfs -rm -f "$HDFS_RAW/norm_asaniczka.jsonl" 2>/dev/null || true

log_info "Uploading normalized data to HDFS: $HDFS_RAW/..."
hdfs dfs -put "$NORM_FILE" "$HDFS_RAW/"
log_ok "Data uploaded to HDFS:"
hdfs dfs -ls "$HDFS_RAW"

log_info "Launching Hadoop Streaming MapReduce job..."
log_info "Mapper:  mapper.py (HTML stripping + skills matching + SHA-256 hash)"
log_info "Reducer: reducer.py (Content-hash deduplication)"

hadoop jar "$STREAMING_JAR" \
    -files "$PROJECT_DIR/mapper.py,$PROJECT_DIR/reducer.py,$PROJECT_DIR/skills.txt" \
    -mapper "python3 mapper.py" \
    -reducer "python3 reducer.py" \
    -input "$HDFS_RAW" \
    -output "$HDFS_CLEAN"

log_ok "Hadoop Streaming job completed successfully!"

# ── 4. Stage 2: Export from HDFS & Ingest into MongoDB ─────────────────────────
log_step "[4/6] Stage 2: Export Clean Data from HDFS & Ingest to MongoDB"

CLEAN_LOCAL="$PROJECT_DIR/clean.jsonl"
log_info "Exporting cleaned partitions from HDFS -> '$CLEAN_LOCAL'..."
hdfs dfs -cat "$HDFS_CLEAN/part-*" | sed 's/\t$//' > "$CLEAN_LOCAL"

CLEAN_COUNT=$(wc -l < "$CLEAN_LOCAL")
log_ok "Cleaned and deduplicated records: $CLEAN_COUNT"

log_info "Importing into MongoDB collection 'jobs' (database: 'hiretrend')..."
mongoimport --db hiretrend --collection jobs --file "$CLEAN_LOCAL" --drop

log_info "Building indexes on 'jobs' collection..."
mongosh hiretrend --quiet --eval '
  db.jobs.createIndex({title_norm: 1});
  db.jobs.createIndex({year: 1, source: 1});
  db.jobs.createIndex({skills: 1});
  print("Indexes created: title_norm, year+source, skills");
'
log_ok "MongoDB ingestion and indexing complete"

# ── 5. Stage 3: Run MongoDB MapReduce Analytics (Jobs J0 -> J6) ───────────────
log_step "[5/6] Stage 3: Executing Analytics MapReduce Jobs (J0 -> J6)"

log_info "Running batch jobs:"
log_info "  - J0: title_totals      (Postings per role)"
log_info "  - J1: top_skills        (Skill demand per role)"
log_info "  - J2: skill_pairs       (Co-occurring technologies)"
log_info "  - J3: salary_by_skill   (Compensation analytics)"
log_info "  - J4: skill_growth      (Year-over-year trends)"
log_info "  - J5: skills_by_level   (Entry vs. Senior requirements)"
log_info "  - J6: source_compare    (Geographic/Dataset comparison)"

mongosh hiretrend mongo/run_all_jobs.js

log_ok "All MapReduce analytics jobs finished!"

# ── 6. Final Status & Summary ─────────────────────────────────────────────────
log_step "[6/6] Pipeline Execution Summary"

END_TIME=$(date +%s)
TOTAL_ELAPSED=$((END_TIME - START_TIME))

echo -e "${C_BOLD}Pipeline Statistics:${C_RESET}"
echo -e "  • Total Raw Input:        ${INPUT_SIZE_MB} MB ($NORM_COUNT postings)"
echo -e "  • Cleaned & Deduplicated: $CLEAN_COUNT unique job postings"
DEDUP_DIFF=$((NORM_COUNT - CLEAN_COUNT))
echo -e "  • Duplicates Filtered:    $DEDUP_DIFF records"
echo -e "  • Total Duration:         $((TOTAL_ELAPSED / 60)) min $((TOTAL_ELAPSED % 60)) sec"

echo -e "\n${C_BOLD}MongoDB Result Collections Status:${C_RESET}"
mongosh hiretrend --quiet --eval '
  print("  • jobs:            " + db.jobs.countDocuments() + " docs");
  print("  • title_totals:    " + db.title_totals.countDocuments() + " docs");
  print("  • top_skills:      " + db.top_skills.countDocuments() + " docs");
  print("  • skill_pairs:     " + db.skill_pairs.countDocuments() + " docs");
  print("  • salary_by_skill: " + db.salary_by_skill.countDocuments() + " docs");
  print("  • skill_growth:    " + db.skill_growth.countDocuments() + " docs");
  print("  • skills_by_level: " + db.skills_by_level.countDocuments() + " docs");
  print("  • source_compare:  " + db.source_compare.countDocuments() + " docs");
'

echo -e "\n${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════════════${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}  🎉 HireTrend End-to-End Big Data Pipeline Finished!${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════════════${C_RESET}"
