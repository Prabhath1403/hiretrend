// J2: Which skills appear together (co-occurrence)
var mapJ2 = function() {
    if (this.skills && Array.isArray(this.skills) && this.skills.length > 1) {
        // Cap to top 8 skills per posting to prevent O(N^2) combinatorial explosion in MongoDB
        var sorted = this.skills.slice(0, 8).sort();
        for (var i = 0; i < sorted.length; i++) {
            for (var j = i + 1; j < sorted.length; j++) {
                emit(sorted[i] + "|" + sorted[j], 1);
            }
        }
    }
};

var reduceJ2 = function(key, values) {
    return Array.sum(values);
};

db.jobs.mapReduce(mapJ2, reduceJ2, {
    out: { replace: "skill_pairs" }
});

print("J2 completed: skill_pairs collection created.");
