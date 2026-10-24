#!/usr/bin/env python3
"""
HireTrend - Stage 0: Schema Normalization
Maps raw datasets into a unified JSON Lines schema.
"""

import sys
import json
import re
from datetime import datetime

SENIORITY_WORDS = {
    'senior', 'sr', 'junior', 'jr', 'lead', 'principal', 'staff',
    'intern', 'internship', 'trainee', 'associate', 'head', 'director',
    'vp', 'manager', 'chief', 'entry', 'mid', 'experienced'
}

def clean_title(title: str) -> str:
    """Lowercase and strip seniority words and punctuation."""
    if not title:
        return ""
    text = title.lower()
    text = re.sub(r'[^a-z0-9\s]', ' ', text)
    tokens = [t for t in text.split() if t not in SENIORITY_WORDS and len(t) > 1]
    return " ".join(tokens)

def normalize_record(source: str, raw_row: dict) -> dict:
    """Normalize input record to HireTrend unified schema."""
    title = raw_row.get("title", "") or ""
    title_norm = clean_title(title)
    
    # Defaults
    job_id = str(raw_row.get("job_id", raw_row.get("id", "")))
    company = str(raw_row.get("company", raw_row.get("name", "")))
    location = str(raw_row.get("location", ""))
    country = str(raw_row.get("country", ""))
    
    # Date parsing
    year = raw_row.get("year", 2024)
    month = raw_row.get("month", 1)
    
    # Handle epoch ms for serbog
    if "creationdate" in raw_row and raw_row["creationdate"]:
        try:
            ts = float(raw_row["creationdate"]) / 1000.0
            dt = datetime.utcfromtimestamp(ts)
            year = dt.year
            month = dt.month
        except Exception:
            pass

    # Salary normalization (hourly/monthly -> yearly)
    salary_yearly = None
    if "salary_yearly" in raw_row and raw_row["salary_yearly"]:
        try:
            salary_yearly = float(raw_row["salary_yearly"])
        except ValueError:
            pass
    elif "salary" in raw_row and raw_row["salary"]:
        try:
            s = float(raw_row["salary"])
            # Heuristic: hourly < 200, monthly < 25000
            if s < 200:
                salary_yearly = round(s * 2080, 2)
            elif s < 25000:
                salary_yearly = round(s * 12, 2)
            else:
                salary_yearly = round(s, 2)
        except ValueError:
            pass

    description = str(raw_row.get("description", ""))
    # Pre-clean description of newlines so one record = one JSON line
    description_clean = " ".join(description.split())

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
        "level": raw_row.get("level", None),
        "remote": raw_row.get("remote", None),
        "salary_yearly": salary_yearly,
        "lang": raw_row.get("lang", "en"),
        "description": description_clean,
        "skills": raw_row.get("skills", [])
    }

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 normalize.py <source_name> <input_file> [output_file]")
        sys.exit(1)
        
    src = sys.argv[1]
    input_path = sys.argv[2]
    out_file = sys.argv[3] if len(sys.argv) > 3 else "normalized.jsonl"
    
    count = 0
    with open(input_path, 'r', encoding='utf-8', errors='ignore') as infile, \
         open(out_file, 'w', encoding='utf-8') as outfile:
        for line in infile:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
                norm = normalize_record(src, row)
                outfile.write(json.dumps(norm) + "\n")
                count += 1
                if count % 100000 == 0:
                    print(f"  → Normalized {count:,} records...", flush=True)
            except Exception as e:
                continue
    print(f"✓ Normalized {count:,} records from {src} to {out_file}")
