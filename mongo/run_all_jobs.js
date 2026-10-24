// Run all HireTrend MapReduce jobs in sequence
print(">>> Starting MapReduce Batch Pipeline (J0 -> J6)...");

load("mongo/J0_title_totals.js");
load("mongo/J1_top_skills.js");
load("mongo/J2_skill_pairs.js");
load("mongo/J3_salary_by_skill.js");
load("mongo/J4_skill_growth.js");
load("mongo/J5_skills_by_level.js");
load("mongo/J6_source_compare.js");

print(">>> All 7 MapReduce jobs completed successfully!");
