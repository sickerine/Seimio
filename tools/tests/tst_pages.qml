// A title's page as Catalog holds it (catalog.h, `loadFranchise`): the rules the screens lean on now that
// they keep no maps of their own. Asked for twice it is fetched and told once; held, it is the same
// objects each time and nothing is said again; one that can't be had is kept as such until it is asked
// for outright; the pages go with the library they were made with, and one on its way then still comes,
// once. (A page that never came was a title OK did nothing on.)
// The answers are the previews' recordings (check.sh runs the tests with SEIMIO_REPLAY), so nothing is
// asked of the network: a Kitsu id has none there and can't be had.
import QtQuick 2.12
import QtTest 1.2
import Seimio.Data 1.0

TestCase {
    name: "Pages"
    Catalog { id: catalog; today: "2026-11-16" }
    SignalSpy { id: ready; target: catalog; signalName: "franchiseReady" }
    SignalSpy { id: failed; target: catalog; signalName: "franchiseFailed" }
    SignalSpy { id: loaded; target: catalog; signalName: "loaded" }
    // titles the recordings have a meta for and Continue Watching doesn't hold, as a search gives them
    readonly property var odyssey: ({ id: "tt33764258", type: "movie", name: "The Odyssey", thin: true })
    readonly property var castle: ({ id: "tt32820897", type: "movie", name: "Infinity Castle", thin: true })
    readonly property var slayer: ({ id: "tt9335498", type: "series", name: "Demon Slayer", thin: true })
    function told(id) { var n = 0; for (var i = 0; i < ready.count; i++) if (ready.signalArguments[i][0] === id) n++; return n }

    function initTestCase() { tryVerify(function () { return catalog.ready }, 15000, "Home's data came, from the recordings") }
    function init() { ready.clear(); failed.clear(); loaded.clear() }

    function test_askedTwiceItIsFetchedAndToldOnce() {
        verify(catalog.franchise(odyssey.id) === undefined, "not held before it is asked for");
        catalog.loadFranchise(odyssey); catalog.loadFranchise(odyssey);
        tryVerify(function () { return told(odyssey.id) === 1 }, 5000);
        var page = catalog.franchise(odyssey.id);
        verify(page && page.item.id === odyssey.id, "held under the id it was asked for");
        verify(!page.item.thin && !!page.item.description, "with its meta's facts");
        verify(ready.signalArguments[0][1] === page.item, "what was told is what is held");
        catalog.loadFranchise(odyssey);                     // held: nothing more is fetched or said
        wait(300);
        compare(told(odyssey.id), 1);
        verify(catalog.franchise(odyssey.id).item === page.item, "the same objects each time");
        compare(failed.count, 0);
    }
    function test_oneThatCantBeHadIsKeptAsSuchUntilAskedOutright() {
        var none = { id: "kitsu:999999", type: "series", name: "No such show" };
        verify(!catalog.unfetchable(none.id));
        catalog.loadFranchise(none);
        tryCompare(failed, "count", 1, 5000);
        compare(failed.signalArguments[0][0], none.id);
        verify(catalog.unfetchable(none.id), "kept as one that can't be had");
        verify(catalog.franchise(none.id) === undefined);
        catalog.loadFranchise(none);                        // OK on it: tried once more
        tryCompare(failed, "count", 2, 5000);
        verify(catalog.unfetchable(none.id));
        compare(ready.count, 0);
    }
    function test_thePagesGoWithTheLibraryAndOneOnItsWayStillComesOnce() {
        catalog.loadFranchise(castle);
        tryVerify(function () { return told(castle.id) === 1 }, 5000);
        verify(catalog.franchise(castle.id) !== undefined);
        catalog.fault(slayer.id, 1200, false);              // its meta is slow to come
        catalog.loadFranchise(slayer);
        catalog.reload();                                   // the library changed: Home's data are taken again
        tryCompare(loaded, "count", 1, 5000);
        verify(catalog.franchise(castle.id) === undefined, "made with the library before: forgotten");
        compare(told(slayer.id), 0, "still on its way");
        tryVerify(function () { return told(slayer.id) === 1 }, 8000);
        wait(400);
        compare(told(slayer.id), 1, "once, though it was asked for again when the pages went");
        var page = catalog.franchise(slayer.id);
        verify(page && page.show.seasons.length > 0, "held, with its seasons");
        catalog.fault("", 0, false);
    }
}
