"""worker: one lane that builds one change. `start` writes the brief and the dispatch approval; dispatch starts the lane. The lane's
own delivery (a landing or a merged PR) closes the row, so `result` only reports a lane that ended `failed`."""
import steplib
import store


def start(home, step):
    steplib.brief(home, step, scout=False)
    steplib.approve(home, step, "worker")
    return "started", "the brief is written and the start is approved"


def result(home, step):
    if store.lane_verb(step["id"]) == "failed":
        return "failed", "the lane ended failed"
    return "open", "the lane delivers and closes the row"
