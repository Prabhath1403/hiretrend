// J1: Which skills each role asks for most
var mapJ1 = function() {
    if (this.title_norm && this.skills && Array.isArray(this.skills)) {
        for (var i = 0; i < this.skills.length; i++) {
            emit(this.title_norm + "|" + this.skills[i], 1);
        }
    }
};

var reduceJ1 = function(key, values) {
    return Array.sum(values);
};

db.jobs.mapReduce(mapJ1, reduceJ1, {
    out: { replace: "top_skills" }
});

print("J1 completed: top_skills collection created.");
