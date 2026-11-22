"""cleanup_pictures(): the page pictures script_pictures_unused_take lists are removed from script-pages, only those,
a hundred to a request; a failure is logged by class name only and the run carries on."""
import logging

import pytest

from processor import main, supa
from test_main import FakeClient

NAMES = [f"exam-1/upload-1/9-1/{i}-marking.jpg" for i in range(3)]


def test_cleanup_pictures_removes_only_what_is_listed():
    client = FakeClient(unused=NAMES)
    assert main.cleanup_pictures(client) == 3
    assert client.named("pictures_unused_take") == [("pictures_unused_take", main.PICTURES_LOOK)]
    assert client.named("remove") == [("remove", "script-pages", NAMES)]
    assert client.named("discarded_take") == [] and client.named("mark_purged") == []


def test_cleanup_pictures_with_nothing_listed_removes_nothing():
    client = FakeClient()
    assert main.cleanup_pictures(client) == 0
    assert client.named("remove") == []


def test_cleanup_pictures_removes_a_hundred_to_a_request_and_never_from_script_uploads():
    names = [f"e/u/1-1/{i}-full.jpg" for i in range(250)]
    client = FakeClient(unused=names)
    assert main.cleanup_pictures(client) == 250
    removes = client.named("remove")
    assert [len(r[2]) for r in removes] == [100, 100, 50]
    assert {r[1] for r in removes} == {"script-pages"}
    assert [n for r in removes for n in r[2]] == names


def test_cleanup_pictures_failure_is_logged_and_run_carries_on(caplog):
    caplog.set_level(logging.DEBUG, logger="processor")
    client = FakeClient(unused=NAMES, remove_error=supa.SupabaseError("remove: HTTP 500"))
    with pytest.raises(supa.SupabaseError):
        main.cleanup_pictures(client)
    # In the timed step the failure is caught: the claim still happens and the log holds the class name, no path.
    client = FakeClient(unused=NAMES, remove_error=supa.SupabaseError("remove: HTTP 500"))
    assert main.run(client, "w-1", once=True) == 0
    assert len(client.named("claim")) == 1
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert "picture cleanup failed: SupabaseError" in text
    for secret in ("exam-1", "upload-1", "marking.jpg"):
        assert secret not in text


def test_the_timed_step_cleans_pictures_after_the_drafts():
    client = FakeClient(unused=NAMES)
    main.run(client, "w-1", once=True)
    names = [c[0] for c in client.calls]
    assert names.index("discarded_take") < names.index("pictures_unused_take") < names.index("claim")


def test_pictures_unused_take_sends_the_limit_and_returns_names():
    import httpx
    import json
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(200, json=[{"name": "e/u/1-1/0-full.jpg"}])

    with supa.Client("http://supabase.test", "k", transport=httpx.MockTransport(handler)) as c:
        assert c.pictures_unused_take(500) == ["e/u/1-1/0-full.jpg"]
    (r,) = seen
    assert r.url.path == "/rest/v1/rpc/script_pictures_unused_take" and json.loads(r.content) == {"p_limit": 500}
