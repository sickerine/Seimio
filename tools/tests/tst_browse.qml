// BrowseScreen's rows follow the list Account says it has: a page more adds rows and leaves the ones on
// screen alone, a title gone or another order rebuilds them (a removal used to leave every old row and
// card in place), and the same list again changes nothing.
import QtQuick 2.12
import QtTest 1.12
import Seimio.UI 1.0
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
        function itemsOf(ids) { return ids.map(function (id) { return all.filter(function (i) { return i.id === id })[0] }) }
        function ids() { return all.map(function (i) { return i.id }) }
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
        account.show(ids(13, 1).reverse()); wait(50);       // another order, as many: left alone while it is on screen
        compare(titles()[0], "t1");
        screen.shown = false; screen.shown = true; settle();        // and taken when it next comes on
        compare(titles()[0], "t13");
        // another, longer list: its later rows arrive while the old rows are still fading out (they were
        // added to the old rows, which left holes)
        account.show(ids(40, 100)); settle();
        compare(titles().join(","), ids(40, 100).join(","));
        // grown, with its first two titles the other way round: on screen the forty stay in the order
        // they are in and the new ones join at the end; the list's own order comes when it next does
        var grown = ids(42, 100).reverse().slice(2).reverse();     // the same forty
        grown = [grown[1], grown[0]].concat(grown.slice(2), ["t140", "t141"]);
        account.show(grown);
        tryVerify(function () { return titles().join(",") === ids(42, 100).join(",") }, 3000);
        screen.shown = false; screen.shown = true; settle();
        compare(titles().join(","), grown.join(","));
    }
    // A title removed from the library with the library on screen: the page was shown again from the
    // top, the cursor back on its first card. It changes where it is: the rows before the title are the
    // rows they were, and the cursor stays on its title, or in its place when that title is the one gone.
    function test_aTitleGoneChangesTheRowsWhereTheyAre() {
        account.show(ids(21, 200)); settle();
        wait(300);                                          // its rows reach the row slots a frame apart
        screen.row = 1; screen.forceActiveFocus();
        keyClick(Qt.Key_Right); keyClick(Qt.Key_Right);
        tryVerify(function () { return screen.focusItem && screen.focusItem.id === "t209" });
        var first = screen.rows[0], shown = Remote.tallies["grid shown"] || 0;
        var left = ids(21, 200); left.splice(9, 1);         // the title under the cursor goes
        account.show(left); settle();
        verify(screen.rows[0] === first, "the row before it is the row it was");
        compare(screen.row, 1);
        compare(screen.focusItem.id, "t210", "the cursor is where it was, on the title that took the place");
        left.splice(0, 1);                                  // then one before it, on another device
        account.show(left); settle();
        compare(screen.focusItem.id, "t210", "the cursor stays on its title");
        compare(screen.row, 1);
        compare(Remote.tallies["grid shown"] || 0, shown, "and the page is never shown again");
        screen.row = -1;
    }
    // While the list is on screen its titles stay in the order they are in. One marked watched goes to
    // the front of the list's order, which is left for later; then another removed took that order with
    // it, and every row changed for a title that only left.
    function test_theOrderOnScreenStaysWhileATitleLeaves() {
        var list = ids(14, 300);
        account.show(list); settle();
        var moved = [list[8]].concat(list.slice(0, 8), list.slice(9));      // the ninth to the front
        account.show(moved); wait(50);
        compare(titles().join(","), list.join(","), "another order is left alone");
        var first = screen.rows[0];
        moved.splice(moved.indexOf("t309"), 1);             // then the tenth removed
        account.show(moved); wait(100);
        list.splice(9, 1);
        compare(titles().join(","), list.join(","), "the title left, and the rest stayed where they were");
        verify(screen.rows[0] === first);
        screen.shown = false; screen.shown = true; wait(100);
        compare(titles().join(","), moved.join(","), "the list's own order when it next comes on");
    }
    // In a long list, a title removed above the cursor (on another device): the rows are made a few at a
    // time from the change down, and the cursor, moved to follow its title, was on the title before it
    // until its rows were reached.
    function test_theCursorIsNeverOnAnotherTitle() {
        var list = ids(700, 1000);
        account.show(list); settle();
        wait(300);
        screen.row = 80; screen.forceActiveFocus();
        tryVerify(function () { return screen.focusItem && /^t15\d\d$/.test(screen.focusItem.id) });
        var on = screen.focusItem.id;
        account.show(list.slice(1));
        compare(screen.focusItem.id, on, "at once, not when the rows before it have been made");
        settle();
        compare(screen.focusItem.id, on);
        screen.row = -1;
    }
}
}
