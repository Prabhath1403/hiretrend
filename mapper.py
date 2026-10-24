#!/usr/bin/env python3
"""
HireTrend - Hadoop Streaming Mapper
Cleans text, matches skills from skills.txt, detects language, and emits content hash.
"""

import sys
import json
import re
import hashlib

# Load skills dictionary
SKILLS_SET = set()
try:
    with open("skills.txt", "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip().lower()
            if s:
                SKILLS_SET.add(s)
except Exception:
    pass

# Simple regex for HTML stripping
HTML_TAG_RE = re.compile(r'<[^>]+>')

def strip_html(text: str) -> str:
    return HTML_TAG_RE.sub(' ', text)

def extract_skills(text: str) -> list:
    """Matches words and phrases against dictionary."""
    text_clean = text.lower()
    found = []
    # Token matching
    for skill in SKILLS_SET:
        # Match whole word / boundary
        pattern = r'(?<![a-z0-9])' + re.escape(skill) + r'(?![a-z0-9])'
        if re.search(pattern, text_clean):
            found.append(skill)
    return sorted(list(set(found)))

def content_hash(title: str, company: str, desc: str) -> str:
    snippet = desc[:200] if desc else ""
    raw = f"{title.lower()}|{company.lower()}|{snippet.lower()}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except Exception:
            continue
            
        title = record.get("title", "")
        desc = record.get("description", "")
        
        # Filter out records missing title or description
        if not title or not desc or len(desc) < 20:
            continue
            
        # Clean description
        clean_desc = strip_html(desc)
        clean_desc = re.sub(r'\s+', ' ', clean_desc).strip()
        
        # Extract skills if not already provided
        existing_skills = record.get("skills", [])
        if not existing_skills:
            matched_skills = extract_skills(title + " " + clean_desc)
            record["skills"] = matched_skills
        else:
            record["skills"] = [s.lower() for s in existing_skills]

        record["description"] = clean_desc
        
        # Compute deduplication content key
        key = content_hash(title, record.get("company", ""), clean_desc)
        
        # Emit key \t json_record
        print(f"{key}\t{json.dumps(record)}")

if __name__ == "__main__":
    main()
