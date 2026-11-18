// ShowScreen.refresh: the same title with new watch state (an episode marked from its menu, a change on
// another device). The row is built again on the card that had the focus, and Play names what it named:
// taken as a page opened on the focused card, Play was renamed to it ("Play Special 1" for a related show
// held a moment before). Once the episode Play named is done, Play moves on to the next.
import QtQuick 2.12
import QtTest 1.12
import "../../app/qml"

Item {
    width: 1920; height: 1080
    ShowScreen { id: page; active: true; focus: true; today: "2026-11-18" }

    TestCase {
    name: "ShowScreen"
    when: windowShown
    property var title: ({ id: "t", name: "T" })
    // one season of five aired episodes, the third the one you are on; `done`: the numbers watched
    function show(done, progress) {
        var eps = [];
        for (var n = 1; n <= 5; n++) eps.push({ id: "t:1:" + n, episode: n, title: "E" + n, released: "2026-01-0" + n, thumb: "",
                                                watched: done.indexOf(n) >= 0, progress: n === 3 ? progress : 0 });
        return { name: "T", current: "t:1:3", seasons: [{ season: 1, episodes: eps }] };
    }
    function focused() { return page.focusedEp ? page.focusedEp.id : "" }

    function test_refreshKeepsPlayAndFocus() {
        page.open(title, show([1, 2], 40));
        compare(page.resumeLabel, "Resume E3");
        keyClick(Qt.Key_Right); keyClick(Qt.Key_Right);
        tryVerify(function () { return focused() === "t:1:5" });
        page.refresh(title, show([1, 2, 5], 40));               // the fifth marked watched from its menu
        compare(page.resumeLabel, "Resume E3", "Play names where you are, not the card that had the focus");
        compare(focused(), "t:1:5", "and the focus stays on that card");
        page.refresh(title, show([1, 2, 3, 5], 0));             // the third marked watched: done
        compare(page.resumeLabel, "Play E4", "Play moves on once the episode it named is done");
        compare(focused(), "t:1:5");
    }
}
}
