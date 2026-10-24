// J5: What entry and senior roles ask for
var mapJ5 = function() {
    if (this.level && this.skills && Array.isArray(this.skills)) {
        var lvl = this.level.toLowerCase();
        this.skills.forEach(function(skill) {
            emit(lvl + "|" + skill, 1);
        });
    }
};

var reduceJ5 = function(key, values) {
    return Array.sum(values);
};

db.jobs.mapReduce(mapJ5, reduceJ5, {
    out: { replace: "skills_by_level" }
});

print("J5 completed: skills_by_level collection created.");
