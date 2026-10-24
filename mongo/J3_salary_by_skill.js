// J3: Average pay linked to each skill (LinkedIn sources only)
var mapJ3 = function() {
    var s = this.salary_yearly;
    if (s && this.skills && Array.isArray(this.skills)) {
        this.skills.forEach(function(k) {
            emit(k, { sum: s, n: 1 });
        });
    }
};

var reduceJ3 = function(key, values) {
    var r = { sum: 0, n: 0 };
    values.forEach(function(x) {
        r.sum += x.sum;
        r.n += x.n;
    });
    return r;
};

var finJ3 = function(key, r) {
    return { avg: r.n > 0 ? (r.sum / r.n) : 0, n: r.n };
};

db.jobs.mapReduce(mapJ3, reduceJ3, {
    out: { replace: "salary_by_skill" },
    finalize: finJ3,
    query: { salary_yearly: { $ne: null }, source: { $ne: "serbog" } }
});

print("J3 completed: salary_by_skill collection created.");
