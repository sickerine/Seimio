// BrowseScreen's rows follow the list Account says it has: a page more adds rows and leaves the ones on
// screen alone, a title gone or another order rebuilds them (a removal used to leave every old row and
// card in place), and the same list again changes nothing.
import QtQuick 2.12
import QtTest 1.12
import "../../app/qml"

Item {
    width: 1920; height: 1080
    // Account, as far as the screen uses it
    QtObject {
        id: account
        property var all: []
        property var browsing: ({ what: "library", filters: [], count: 0, more: false, loading: false })
        property var watchedTitles: ({})
        function browse(what) {}
        function choose(key, option) {}
        function more() {}
        function items(from, n) { return all.slice(from, from + n) }
        function stampOf(n) { return all.slice(0, n).map(function (i) { return i.id }).join(",") }
        function show(ids) {
            all = ids.map(function (id) { return { id: id, name: id, title: id, art: "" } });
            browsing = { what: "library", filters: [], count: ids.length, more: false, loading: false };
        }
    }
    // on screen (a TestCase's own children are not), so new rows fade the old ones out first, as in the app
    BrowseScreen { id: screen; width: 1920; height: 1080; account: account; what: "library"; shown: true }

    TestCase {
    name: "BrowseScreen"
    when: windowShown
    function ids(n, from) { var out = []; for (var i = from || 0; i < (from || 0) + n; i++) out.push("t" + i); return out }
    function titles() { var out = []; screen.rows.forEach(function (r) { r.items.forEach(function (i) { out.push(i.id) }) }); return out }
    function settle() { tryVerify(function () { return titles().join(",") === account.all.map(function (i) { return i.id }).join(",") }, 3000) }

    function test_rowsFollowTheList() {
        account.show(ids(14)); settle();
        compare(screen.rows.length, 2);
        var first = screen.rows[0];
        account.show(ids(21)); settle();                    // a page more
        compare(screen.rows.length, 3);
        verify(screen.rows[0] === first, "the rows on screen are the same rows");
        account.show(ids(21)); settle();                    // the same again
        verify(screen.rows[0] === first);
        account.show(ids(13, 1)); settle();                 // the first title gone
        compare(titles().join(","), ids(13, 1).join(","));
        compare(screen.rows.length, 2);
        account.show(ids(13, 1).reverse()); settle();       // another order, as many
        compare(titles()[0], "t13");
        // another, longer list: its later rows arrive while the old rows are still fading out (they were
        // added to the old rows, which left holes)
        account.show(ids(40, 100)); settle();
        compare(titles().join(","), ids(40, 100).join(","));
        // grown, but with its first two titles the other way round: not a page more (the rows built
        // were kept as long as the last of them was where it had been)
        var grown = ids(42, 100).reverse().slice(2).reverse();     // the same forty
        grown = [grown[1], grown[0]].concat(grown.slice(2), ["t140", "t141"]);
        account.show(grown); settle();
        compare(titles().join(","), grown.join(","));
    }
}
}
