// J0: Postings per role (denominator for share calculations)
var mapJ0 = function() {
    if (this.title_norm) {
        emit(this.title_norm, 1);
    }
};

var reduceJ0 = function(key, values) {
    return Array.sum(values);
};

db.jobs.mapReduce(mapJ0, reduceJ0, {
    out: { replace: "title_totals" }
});

print("J0 completed: title_totals collection created.");
