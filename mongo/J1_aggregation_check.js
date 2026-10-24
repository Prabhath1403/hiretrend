// Quality check: Modern Aggregation Pipeline alternative for J1 (top_skills)
// Compares aggregation pipeline output with MapReduce output
var pipeline = [
    { $unwind: "$skills" },
    { $match: { title_norm: { $ne: "" } } },
    { $group: { _id: { $concat: ["$title_norm", "|", "$skills"] }, count: { $sum: 1 } } },
    { $sort: { count: -1 } },
    { $limit: 10 }
];

print("--- Aggregation Pipeline Top 10 ---");
var aggResults = db.jobs.aggregate(pipeline).toArray();
printjson(aggResults);

print("--- MapReduce (top_skills) Top 10 ---");
var mrResults = db.top_skills.find().sort({ value: -1 }).limit(10).toArray();
printjson(mrResults);
