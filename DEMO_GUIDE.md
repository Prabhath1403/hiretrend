# HireTrend – Faculty Demo & Execution Guide 🚀

This guide contains everything you need to run, demonstrate, and explain the HireTrend Big Data pipeline to your faculty.

---

## 📋 Table of Contents
1. [Quick Viva Demo Commands (MongoDB Inspection)](#1-quick-viva-demo-commands)
2. [Starting the Application (Backend + Frontend)](#2-starting-the-application)
3. [Stopping the Application](#3-stopping-the-application)
4. [Running the Entire Pipeline from Scratch](#4-running-the-entire-pipeline)
5. [Key Pipeline Metrics & Explanations for Faculty](#5-key-metrics--viva-qa)

---

## 1. Quick Viva Demo Commands

Open your terminal and run these commands directly in `mongosh` to show your faculty:

### 1.1 Show Raw Postings Ingested into MongoDB First (`raw_jobs`)
```bash
mongosh hiretrend --eval 'print("Raw Postings in MongoDB (raw_jobs): " + db.raw_jobs.estimatedDocumentCount())'
```
> **Expected Output:**
> `Raw Postings in MongoDB (raw_jobs): 1297332`  
> *(1.29 Million raw records imported directly from Kaggle CSVs into MongoDB as the raw data lake)*

---

### 1.2 Show Cleaned Postings After Data Processing (`jobs`)
```bash
mongosh hiretrend --eval 'print("Processed Clean Postings (jobs): " + db.jobs.estimatedDocumentCount())'
```
> **Expected Output:**
> `Processed Clean Postings (jobs): 927709`  
> *(369,623 duplicates and noisy/invalid postings were filtered out by the data processing pipeline)*

---

### 1.3 Compare Document Before vs. After Data Processing
Show your faculty the exact difference between a raw uncleaned posting and a cleaned posting:

```bash
mongosh hiretrend --eval '
  print("=================== [1] RAW DOCUMENT (from raw_jobs) ===================");
  printjson(db.raw_jobs.findOne({}, {
    title: 1,
    company: 1,
    location: 1,
    description: { $substrCP: ["$description", 0, 100] }
  }));
  print("\n=================== [2] CLEAN DOCUMENT (from jobs) ===================");
  printjson(db.jobs.findOne({}, {
    title: 1,
    title_norm: 1,
    company: 1,
    skills: 1
  }));
'
```

**Key Differences to Point Out to Faculty:**
* **Raw Document:** Contains raw title with seniority words, raw unescaped text, unnormalized fields, and duplicates.
* **Clean Document:** Has normalized title (`title_norm`), stripped HTML, matched skills against the 6,938 skill dictionary, and has passed SHA-256 content-hash deduplication.

---

### 1.4 Inspect Downstream MongoDB MapReduce Analytics
Show the 7 analytics collections produced by MapReduce:

```bash
mongosh hiretrend --eval '
  print("=== MongoDB Analytics Collections ===");
  print("  • title_totals (Roles):        " + db.title_totals.estimatedDocumentCount() + " records");
  print("  • top_skills (Role -> Skill):  " + db.top_skills.estimatedDocumentCount() + " records");
  print("  • skill_pairs (Co-occurrence): " + db.skill_pairs.estimatedDocumentCount() + " records");
  print("  • skill_growth (YoY Trends):   " + db.skill_growth.estimatedDocumentCount() + " records");
  print("  • skills_by_level (Seniority): " + db.skills_by_level.estimatedDocumentCount() + " records");
'
```

---

## 2. Starting the Application

To launch both the FastAPI backend and React frontend dashboard:

### Terminal 1: Start FastAPI Backend (Port 8000)
```bash
cd ~/projects/hiretrend
source venv/bin/activate
uvicorn backend.main:app --host 0.0.0.0 --port 8000 --reload
```
* **Swagger API Docs:** [http://localhost:8000/docs](http://localhost:8000/docs)
* **Health Endpoint:** [http://localhost:8000/api/health](http://localhost:8000/api/health)
* **Dataset Overview API:** [http://localhost:8000/api/overview](http://localhost:8000/api/overview)

---

### Terminal 2: Start React Frontend Dashboard (Port 5173)
```bash
cd ~/projects/hiretrend/frontend
npm run dev
```
* **Executive Dashboard:** [http://localhost:5173](http://localhost:5173)

---

## 3. Stopping the Application

Whenever you want to stop the servers:
* Press **`Ctrl + C`** in both Terminal 1 and Terminal 2.

If you ever ran them in the background and want to kill them:
```bash
# Kill FastAPI backend (port 8000)
fuser -k 8000/tcp || true

# Kill React frontend (port 5173)
fuser -k 5173/tcp || true
```

---

## 4. Running the Entire Pipeline

### Method A: One-Command Automated End-to-End Pipeline
Runs all stages from environment checks to raw ingestion, data processing, and MapReduce jobs:

```bash
cd ~/projects/hiretrend
./scripts/run_pipeline.sh
```

*(Optional: To run with Hadoop Distributed Streaming MapReduce instead of direct Python processing, pass `--hadoop`:)*
```bash
./scripts/run_pipeline.sh --hadoop
```

---

### Method B: Run Only the Data Processing from MongoDB
If the raw dataset is already in MongoDB `raw_jobs` and you only want to rerun the data processing:

```bash
cd ~/projects/hiretrend
source venv/bin/activate
python3 scripts/process_from_mongo.py --db hiretrend --src-coll raw_jobs --dst-coll jobs
```

---

### Method C: Re-run MongoDB MapReduce Analytics
To re-run the 7 MapReduce aggregation jobs (J0 to J6):

```bash
cd ~/projects/hiretrend
mongosh hiretrend mongo/run_all_jobs.js
```

---

## 5. Key Metrics & Viva Q&A

### 📊 Summary Table
| Stage | Collection | Document Count | Purpose |
|---|---|---|---|
| **Raw Ingestion** | `raw_jobs` | **1,297,332** | Raw untouched dataset stored in MongoDB Data Lake |
| **Data Processing** | `jobs` | **927,709** | Clean, normalized, deduplicated unique postings |
| **Noise Reduction** | — | **369,623 (28.5%)** | Duplicates & invalid postings removed |
| **Top Skills Mappings** | `top_skills` | **15,255,021** | Generated by MapReduce Job J1 |
| **Co-occurring Pairs** | `skill_pairs` | **11,903,150** | Generated by MapReduce Job J2 |

---

### ❓ Anticipated Viva Questions & Answers

**Q1: Why did you import the dataset into MongoDB before data processing?**  
> *"In enterprise Big Data architectures, raw data is first ingested as-is into a Data Lake / Document Store (`hiretrend.raw_jobs`) to maintain raw data lineage and reproducibility. All transformation, cleaning, text sanitization, and deduplication logic then runs downstream from MongoDB into the production `hiretrend.jobs` collection."*

**Q2: What happens during the Data Processing stage?**  
> 1. *Title Normalization: Strips seniority tokens ('senior', 'lead', 'intern') to match canonical roles (e.g. 'Software Engineer').*  
> 2. *HTML Stripping & Sanitization: Cleans description HTML tags and excess whitespace.*  
> 3. *Skill Extraction: Matches tokens against our 6,938 technical and professional skills dictionary (`skills.txt`).*  
> 4. *SHA-256 Content-Hash Deduplication: Hashes `(title_norm + company + desc[:200])` to detect and eliminate duplicate postings.*

**Q3: What role does Hadoop play vs. MongoDB MapReduce?**  
> * **Hadoop Streaming MapReduce:** Used for high-throughput distributed batch cleaning, HTML parsing, and content-hash deduplication across multi-gigabyte HDFS data blocks.  
> * **MongoDB MapReduce:** Used for complex in-database analytical aggregations (7 jobs: J0 to J6) to compute top skills per role, co-occurring skill pairs, and year-over-year skill growth without transferring data over the network.
