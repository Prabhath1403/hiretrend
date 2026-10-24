#!/usr/bin/env python3
"""
HireTrend - Hadoop Streaming Reducer
Deduplicates postings by content hash key.
"""

import sys

def main():
    current_key = None
    
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
            
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
            
        key, record_json = parts
        
        # Deduplication: only emit the first record for each unique content hash
        if key != current_key:
            current_key = key
            print(record_json)

if __name__ == "__main__":
    main()
