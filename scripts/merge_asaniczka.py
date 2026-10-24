#!/usr/bin/env python3
"""
HireTrend - High-Performance Streaming Merge Script for Kaggle 'asaniczka' Dataset
(1.3M LinkedIn Jobs & Skills 2024)

Merges linkedin_job_postings.csv, job_skills.csv, and job_summary.csv into merged_asaniczka.jsonl.
Uses in-memory lookup table (< 1.5 GB RAM) and chunked streaming for blazing-fast performance.
"""

import sys
import os
import json
import time
from datetime import datetime
import pandas as pd

def main():
    data_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    output_file = sys.argv[2] if len(sys.argv) > 2 else "merged_asaniczka.jsonl"

    postings_path = os.path.join(data_dir, "linkedin_job_postings.csv")
    skills_path = os.path.join(data_dir, "job_skills.csv")
    summary_path = os.path.join(data_dir, "job_summary.csv")

    for path, name in [(postings_path, "linkedin_job_postings.csv"),
                       (skills_path, "job_skills.csv"),
                       (summary_path, "job_summary.csv")]:
        if not os.path.exists(path):
            print(f"❌ ERROR: Missing required file: {path}")
            print(f"   Please make sure '{name}' is in '{data_dir}/'")
            sys.exit(1)

    print("══════════════════════════════════════════════════════════════════")
    print("   HireTrend: Blazing-Fast Dataset Merge (1.3M Postings)")
    print("══════════════════════════════════════════════════════════════════")
    start_time = time.time()

    # Step 1: Load Skills into in-memory dictionary
    print("\n[1/3] Loading skills from 'job_skills.csv' into memory index...")
    t0 = time.time()
    skills_df = pd.read_csv(skills_path, low_memory=False)
    skills_dict = {}
    for link, raw_skills in zip(skills_df["job_link"], skills_df["job_skills"]):
        if pd.notna(link) and pd.notna(raw_skills):
            skills_dict[str(link).strip()] = [s.strip().lower() for s in str(raw_skills).split(",") if s.strip()]
    del skills_df
    print(f"      ✓ Indexed {len(skills_dict):,} skills mappings in {time.time()-t0:.2f}s")

    # Step 2: Load Job Postings metadata into in-memory dictionary
    print("\n[2/3] Loading job metadata from 'linkedin_job_postings.csv' into memory index...")
    t0 = time.time()
    jobs_df = pd.read_csv(postings_path, usecols=[
        "job_link", "job_title", "company", "job_location",
        "search_country", "job_level", "job_type", "first_seen"
    ], low_memory=False)

    jobs_dict = {}
    for _, row in jobs_df.iterrows():
        link = str(row["job_link"]).strip() if pd.notna(row["job_link"]) else ""
        if not link:
            continue

        title = str(row["job_title"]) if pd.notna(row["job_title"]) else ""
        company = str(row["company"]) if pd.notna(row["company"]) else ""
        location = str(row["job_location"]) if pd.notna(row["job_location"]) else ""
        country = str(row["search_country"]) if pd.notna(row["search_country"]) else ""
        level = str(row["job_level"]).strip() if pd.notna(row["job_level"]) else None

        job_type = str(row["job_type"]).lower().strip() if pd.notna(row["job_type"]) else ""
        remote = True if "remote" in job_type else (False if "onsite" in job_type or "on-site" in job_type else None)

        year = 2024
        month = 1
        first_seen = str(row["first_seen"]) if pd.notna(row["first_seen"]) else ""
        if first_seen and len(first_seen) >= 7:
            try:
                dt = datetime.fromisoformat(first_seen[:10])
                year = dt.year
                month = dt.month
            except Exception:
                pass

        job_id = link.split("-")[-1] if "-" in link else link.split("/")[-1]

        jobs_dict[link] = {
            "title": title,
            "company": company,
            "location": location,
            "country": country,
            "level": level,
            "remote": remote,
            "year": year,
            "month": month,
            "job_id": job_id
        }
    del jobs_df
    print(f"      ✓ Indexed {len(jobs_dict):,} job metadata records in {time.time()-t0:.2f}s")

    # Step 3: Stream job_summary.csv in chunks and emit unified JSONL
    print(f"\n[3/3] Streaming 'job_summary.csv' (4.8 GB) and merging directly to '{output_file}'...")
    t0 = time.time()
    written_count = 0
    chunksize = 50000

    with open(output_file, "w", encoding="utf-8") as out_f:
        for chunk in pd.read_csv(summary_path, chunksize=chunksize, low_memory=False):
            lines_batch = []
            for link, summary in zip(chunk["job_link"], chunk["job_summary"]):
                if pd.isna(link):
                    continue
                link_str = str(link).strip()
                meta = jobs_dict.get(link_str)
                if not meta:
                    continue

                desc_raw = str(summary) if pd.notna(summary) else ""
                desc_clean = " ".join(desc_raw.split())
                if len(desc_clean) < 10:
                    continue

                skills = skills_dict.get(link_str, [])

                record = {
                    "source": "asaniczka",
                    "job_id": meta["job_id"],
                    "title": meta["title"],
                    "company": meta["company"],
                    "location": meta["location"],
                    "country": meta["country"],
                    "year": meta["year"],
                    "month": meta["month"],
                    "level": meta["level"],
                    "remote": meta["remote"],
                    "salary_yearly": None,
                    "lang": "en",
                    "description": desc_clean,
                    "skills": skills
                }
                lines_batch.append(json.dumps(record, ensure_ascii=False))

            if lines_batch:
                out_f.write("\n".join(lines_batch) + "\n")
                written_count += len(lines_batch)
                print(f"      → Written {written_count:,} records ({time.time()-t0:.1f}s)...", end="\r", flush=True)

    elapsed = time.time() - start_time
    file_size_mb = os.path.getsize(output_file) / (1024 * 1024)
    print(f"\n      ✓ Total records merged & written: {written_count:,}")
    print("\n══════════════════════════════════════════════════════════════════")
    print(f"✅ Merge Complete in {elapsed:.1f}s! ({elapsed/60:.2f} min)")
    print(f"   Output file: {output_file} ({file_size_mb:.1f} MB)")
    print("══════════════════════════════════════════════════════════════════\n")

if __name__ == "__main__":
    main()
