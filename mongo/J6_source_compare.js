// J6: Skill shares for US LinkedIn data vs European data
var mapJ6 = function() {
    if (this.source && this.skills && Array.isArray(this.skills)) {
        var src = this.source;
        this.skills.forEach(function(skill) {
            emit(src + "|" + skill, 1);
        });
        emit(src + "|__TOTAL__", 1);
    }
};

var reduceJ6 = function(key, values) {
    return Array.sum(values);
};

db.jobs.mapReduce(mapJ6, reduceJ6, {
    out: { replace: "source_compare" }
});

print("J6 completed: source_compare collection created.");
