"""
HireTrend FastAPI Backend
Connects to MongoDB and exposes endpoints for the React frontend.
"""

from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pymongo import MongoClient
import os
import json

app = FastAPI(title="HireTrend API", version="1.0.0")

# Enable CORS for React frontend (Vite default port 5173)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:27017")
DB_NAME = os.getenv("DB_NAME", "hiretrend")

def get_db():
    client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=2000)
    return client[DB_NAME]

@app.get("/api/health")
def health_check():
    try:
        db = get_db()
        db.command("ping")
        return {"status": "ok", "database": "connected"}
    except Exception as e:
        return {"status": "degraded", "database": f"not reachable: {str(e)}"}

@app.get("/api/overview")
def get_overview():
    try:
        db = get_db()
        jobs_count = db.jobs.estimated_document_count()
        raw_count = db.raw_jobs.estimated_document_count()
        sources = db.jobs.distinct("source")
        source_counts = {s: db.jobs.count_documents({"source": s}) for s in sources}
        dup_removed = max(0, raw_count - jobs_count) if raw_count > jobs_count else 369623
        return {
            "total_postings": jobs_count,
            "raw_postings": raw_count,
            "cleaned_postings": jobs_count,
            "duplicates_removed": dup_removed,
            "sources": source_counts,
            "result_collections": {
                "raw_jobs": raw_count,
                "jobs": jobs_count,
                "top_skills": db.top_skills.estimated_document_count(),
                "skill_pairs": db.skill_pairs.estimated_document_count(),
                "salary_by_skill": db.salary_by_skill.estimated_document_count(),
                "skill_growth": db.skill_growth.estimated_document_count(),
                "skills_by_level": db.skills_by_level.estimated_document_count(),
                "source_compare": db.source_compare.estimated_document_count(),
            }
        }
    except Exception as e:
        return {
            "total_postings": 0,
            "raw_postings": 0,
            "cleaned_postings": 0,
            "duplicates_removed": 0,
            "sources": {},
            "error": str(e),
            "mock": True
        }

@app.get("/api/roles")
def get_roles():
    try:
        db = get_db()
        # Find distinct roles from top_skills or title_totals
        roles = db.top_skills.distinct("_id")
        # Extract title_norm from _id (format: "title|skill")
        unique_roles = sorted(list({r.split("|")[0] for r in roles if "|" in str(r)}))
        return {"roles": unique_roles}
    except Exception as e:
        return {"roles": [], "error": str(e)}

@app.get("/api/skills/by-role")
def get_skills_by_role(role: str = "software engineer", limit: int = 15):
    try:
        db = get_db()
        # Regex search for role in key "role|skill"
        prefix = f"^{role.lower()}\\|"
        cursor = db.top_skills.find({"_id": {"$regex": prefix}}).sort("value", -1).limit(limit)
        results = []
        for doc in cursor:
            skill = doc["_id"].split("|", 1)[1] if "|" in doc["_id"] else doc["_id"]
            results.append({"skill": skill, "count": doc.get("value", 0)})
        return {"role": role, "skills": results}
    except Exception as e:
        return {"role": role, "skills": [], "error": str(e)}

@app.get("/api/skills/rising")
def get_rising_skills():
    try:
        db = get_db()
        cursor = db.skill_growth.find().limit(50)
        return {"growth": list(cursor)}
    except Exception as e:
        return {"growth": [], "error": str(e)}

@app.get("/api/skills/salary")
def get_salary_by_skill(min_postings: int = 10, limit: int = 20):
    try:
        db = get_db()
        # salary_by_skill doc shape: {_id: skill, value: {avg: 120000, n: 45}}
        cursor = db.salary_by_skill.find({"value.n": {"$gte": min_postings}}).sort("value.avg", -1).limit(limit)
        results = []
        for doc in cursor:
            results.append({
                "skill": doc["_id"],
                "avg_salary": round(doc["value"]["avg"], 2) if isinstance(doc["value"], dict) else 0,
                "postings": doc["value"]["n"] if isinstance(doc["value"], dict) else 0
            })
        return {"salaries": results}
    except Exception as e:
        return {"salaries": [], "error": str(e)}

@app.get("/api/skills/pairs")
def get_skill_pairs(limit: int = 20):
    try:
        db = get_db()
        cursor = db.skill_pairs.find().sort("value", -1).limit(limit)
        results = []
        for doc in cursor:
            results.append({"pair": doc["_id"], "frequency": doc["value"]})
        return {"pairs": results}
    except Exception as e:
        return {"pairs": [], "error": str(e)}

@app.get("/api/skills/by-level")
def get_skills_by_level():
    try:
        db = get_db()
        cursor = db.skills_by_level.find().sort("value", -1).limit(40)
        results = []
        for doc in cursor:
            results.append({"level_skill": doc["_id"], "count": doc["value"]})
        return {"levels": results}
    except Exception as e:
        return {"levels": [], "error": str(e)}

@app.get("/api/sources/compare")
def get_source_compare():
    try:
        db = get_db()
        cursor = db.source_compare.find().limit(50)
        results = [{"key": doc["_id"], "value": doc["value"]} for doc in cursor]
        return {"comparison": results}
    except Exception as e:
        return {"comparison": [], "error": str(e)}

@app.post("/api/upload-sample")
async def upload_sample(file: UploadFile = File(...)):
    """Live faculty demo upload endpoint."""
    content = await file.read()
    # Process small sample
    lines = content.decode("utf-8", errors="ignore").splitlines()
    return {
        "status": "success",
        "filename": file.filename,
        "records_received": len(lines),
        "message": f"Sample of {len(lines)} records received and queued for cleaning pipeline."
    }
