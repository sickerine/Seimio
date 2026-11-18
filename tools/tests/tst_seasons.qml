// The seasons the Anime tab offers: the next one first, then the one now, then back three years. Winter
// runs December to February under the year it ends in, so December belongs to next year's Winter.
import QtQuick 2.12
import QtTest 1.2
import Seimio.Data 1.0

TestCase {
    name: "Seasons"
    Catalog { id: catalog }
    function labels(day) { return catalog.seasonsOn(day).map(function (s) { return s.label + (s.detail ? " (" + s.detail + ")" : "") }) }
    function test_nextNowAndBack() {
        var l = labels("2026-11-17");
        compare(l.slice(0, 5), ["Winter 2027 (Next)", "Fall 2026 (Now)", "Summer 2026", "Spring 2026", "Winter 2026"]);
        compare(l.length, 14);
        compare(l[13], "Fall 2023", "three years back");
    }
    function test_decemberIsNextYearsWinter() {
        compare(labels("2026-12-05").slice(0, 3), ["Spring 2027 (Next)", "Winter 2027 (Now)", "Fall 2026"]);
        compare(labels("2027-02-28").slice(0, 2), ["Spring 2027 (Next)", "Winter 2027 (Now)"]);
        compare(catalog.seasonsOn("2026-12-05")[1].season, "WINTER");
    }
}
