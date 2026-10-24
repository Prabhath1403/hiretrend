// J4: Share of postings per year to rank growth
var mapJ4 = function() {
    if (this.year && this.skills && Array.isArray(this.skills)) {
        var y = this.year;
        this.skills.forEach(function(skill) {
            emit(skill + "|" + y, 1);
        });
        emit("__TOTAL__|" + y, 1);
    }
};

var reduceJ4 = function(key, values) {
    return Array.sum(values);
};

db.jobs.mapReduce(mapJ4, reduceJ4, {
    out: { replace: "skill_growth" }
});

print("J4 completed: skill_growth collection created.");
