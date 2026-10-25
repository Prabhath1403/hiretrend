#!/usr/bin/env python3
"""
HireTrend - Data Processing from MongoDB (Stage 1)
Reads raw job postings directly from MongoDB ('raw_jobs'),
performs data cleaning, schema normalization, HTML sanitization,
skill matching, and content-hash deduplication,
and inserts the cleaned records into MongoDB ('jobs').

Supports:
  1. Direct MongoDB Stream Processing (raw_jobs -> jobs)
  2. Export for Hadoop MapReduce (raw_jobs -> HDFS / JSONL)
"""

import sys
import os
import re
import json
import time
import hashlib
from datetime import datetime
import argparse
from pymongo import MongoClient, InsertOne
from pymongo.errors import BulkWriteError

# Load skills dictionary
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILLS_FILE = os.path.join(PROJECT_DIR, "skills.txt")

SKILLS_SET = set()
if os.path.exists(SKILLS_FILE):
    with open(SKILLS_FILE, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip().lower()
            if s:
                SKILLS_SET.add(s)

HTML_TAG_RE = re.compile(r'<[^>]+>')
SENIORITY_WORDS = {
    'senior', 'sr', 'junior', 'jr', 'lead', 'principal', 'staff',
    'intern', 'internship', 'trainee', 'associate', 'head', 'director',
    'vp', 'manager', 'chief', 'entry', 'mid', 'experienced'
}

def strip_html(text: str) -> str:
    if not text:
        return ""
    return HTML_TAG_RE.sub(' ', text)

def clean_title(title: str) -> str:
    """Lowercase and strip seniority words and punctuation."""
    if not title:
        return ""
    text = title.lower()
    text = re.sub(r'[^a-z0-9\s]', ' ', text)
    tokens = [t for t in text.split() if t not in SENIORITY_WORDS and len(t) > 1]
    return " ".join(tokens)

def extract_skills(text: str) -> list:
    """Matches words and phrases against dictionary."""
    text_clean = text.lower()
    found = []
    for skill in SKILLS_SET:
        pattern = r'(?<![a-z0-9])' + re.escape(skill) + r'(?![a-z0-9])'
        if re.search(pattern, text_clean):
            found.append(skill)
    return sorted(list(set(found)))

def content_hash(title: str, company: str, desc: str) -> str:
    snippet = desc[:200] if desc else ""
    raw = f"{title.lower()}|{company.lower()}|{snippet.lower()}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()

def process_record(raw_doc: dict) -> dict:
    """Normalize and clean a single record from raw_jobs."""
    title = raw_doc.get("title", "") or ""
    desc = raw_doc.get("description", "") or ""

    # Basic validity check
    if not title or not desc or len(desc) < 20:
        return None

    title_norm = clean_title(title)
    if not title_norm:
        title_norm = title.lower().strip()

    company = str(raw_doc.get("company", raw_doc.get("name", "")))
    location = str(raw_doc.get("location", ""))
    country = str(raw_doc.get("country", ""))
    source = raw_doc.get("source", "asaniczka")
    job_id = str(raw_doc.get("job_id", raw_doc.get("id", "")))

    # Clean description (strip HTML, collapse whitespace)
    clean_desc = strip_html(desc)
    clean_desc = " ".join(clean_desc.split())

    # Salary normalization
    salary_yearly = None
    if "salary_yearly" in raw_doc and raw_doc["salary_yearly"]:
        try:
            salary_yearly = float(raw_doc["salary_yearly"])
        except (ValueError, TypeError):
            pass
    elif "salary" in raw_doc and raw_doc["salary"]:
        try:
            s = float(raw_doc["salary"])
            if s < 200:
                salary_yearly = round(s * 2080, 2)
            elif s < 25000:
                salary_yearly = round(s * 12, 2)
            else:
                salary_yearly = round(s, 2)
        except (ValueError, TypeError):
            pass

    # Skills resolution
    raw_skills = raw_doc.get("skills", [])
    if isinstance(raw_skills, list) and len(raw_skills) > 0:
        skills = [str(s).strip().lower() for s in raw_skills if str(s).strip()]
    elif isinstance(raw_skills, str) and raw_skills:
        skills = [s.strip().lower() for s in raw_skills.split(",") if s.strip()]
    else:
        skills = extract_skills(title + " " + clean_desc)

    # Date parsing
    year = raw_doc.get("year", 2024)
    month = raw_doc.get("month", 1)
    if "creationdate" in raw_doc and raw_doc["creationdate"]:
        try:
            ts = float(raw_doc["creationdate"]) / 1000.0
            dt = datetime.utcfromtimestamp(ts)
            year = dt.year
            month = dt.month
        except Exception:
            pass

    c_hash = content_hash(title_norm, company, clean_desc)

    return {
        "source": source,
        "job_id": job_id,
        "title": title,
        "title_norm": title_norm,
        "company": company,
        "location": location,
        "country": country,
        "year": int(year),
        "month": int(month),
        "level": raw_doc.get("level", None),
        "remote": raw_doc.get("remote", None),
        "salary_yearly": salary_yearly,
        "lang": raw_doc.get("lang", "en"),
        "description": clean_desc,
        "skills": skills,
        "content_hash": c_hash
    }

def main():
    parser = argparse.ArgumentParser(description="HireTrend Data Processing from MongoDB")
    parser.add_argument("--mongo-uri", default="mongodb://localhost:27017", help="MongoDB URI")
    parser.add_argument("--db", default="hiretrend", help="Database name")
    parser.add_argument("--src-coll", default="raw_jobs", help="Source raw collection")
    parser.add_argument("--dst-coll", default="jobs", help="Destination clean collection")
    parser.add_argument("--batch-size", type=int, default=5000, help="Batch size for reads & writes")
    parser.add_argument("--limit", type=int, default=0, help="Max records to process (0 = all)")
    parser.add_argument("--export-file", default="", help="If provided, also export processed JSONL to file")
    args = parser.parse_args()

    print("══════════════════════════════════════════════════════════════════")
    print("   HireTrend: Data Processing Pipeline (From MongoDB 'raw_jobs')")
    print("══════════════════════════════════════════════════════════════════")
    print(f"  • Source Collection:      {args.db}.{args.src_coll}")
    print(f"  • Destination Collection: {args.db}.{args.dst_coll}")
    print(f"  • Batch Size:             {args.batch_size:,}")
    if args.limit > 0:
        print(f"  • Processing Limit:       {args.limit:,} records")

    client = MongoClient(args.mongo_uri)
    db = client[args.db]
    src = db[args.src_coll]
    dst = db[args.dst_coll]

    total_raw = src.estimated_document_count()
    if total_raw == 0:
        print(f"❌ Error: Source collection '{args.src_coll}' is empty or does not exist.")
        sys.exit(1)

    print(f"  • Raw Records Available:  {total_raw:,}")
    print("------------------------------------------------------------------")

    # Clear destination or prepare
    dst.drop()
    print(f"  ✓ Reset destination collection '{args.dst_coll}'")

    start_time = time.time()
    seen_hashes = set()
    total_read = 0
    total_valid = 0
    total_duplicates = 0
    total_invalid = 0

    cursor = src.find({}, {"_id": 0}, batch_size=args.batch_size, no_cursor_timeout=True)
    if args.limit > 0:
        cursor = cursor.limit(args.limit)

    export_f = open(args.export_file, "w", encoding="utf-8") if args.export_file else None
    write_batch = []

    try:
        for doc in cursor:
            total_read += 1

            processed = process_record(doc)
            if not processed:
                total_invalid += 1
                continue

            h = processed["content_hash"]
            if h in seen_hashes:
                total_duplicates += 1
                continue

            seen_hashes.add(h)
            total_valid += 1
            write_batch.append(InsertOne(processed))

            if export_f:
                export_f.write(json.dumps(processed) + "\n")

            if len(write_batch) >= args.batch_size:
                dst.bulk_write(write_batch, ordered=False)
                write_batch = []
                elapsed = time.time() - start_time
                rate = total_read / max(elapsed, 0.001)
                print(f"  Processed {total_read:,}/{total_raw:,} | Clean: {total_valid:,} | Duplicates: {total_duplicates:,} ({rate:.0f} rec/s)", end="\r")

        if write_batch:
            dst.bulk_write(write_batch, ordered=False)
            write_batch = []

    finally:
        cursor.close()
        if export_f:
            export_f.close()

    elapsed = time.time() - start_time
    print(f"\n------------------------------------------------------------------")
    print("✓ Data Processing Complete!")
    print(f"  • Total Read from MongoDB:    {total_read:,}")
    print(f"  • Clean Postings Inserted:    {total_valid:,} -> '{args.dst_coll}'")
    print(f"  • Duplicate Records Removed:  {total_duplicates:,}")
    print(f"  • Invalid/Empty Discarded:    {total_invalid:,}")
    print(f"  • Elapsed Time:               {elapsed:.1f}s ({total_read / max(elapsed, 0.001):.0f} records/sec)")

    # Build essential indexes on the cleaned collection
    print(f"\n  Building query indexes on '{args.dst_coll}'...")
    dst.create_index("title_norm")
    dst.create_index([("year", 1), ("source", 1)])
    dst.create_index("skills")
    print("  ✓ Indexes created: title_norm, year+source, skills")
    print("══════════════════════════════════════════════════════════════════")

if __name__ == "__main__":
    main()
