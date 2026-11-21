"""supa.Client's requests, against a mock transport: what is sent for the cleanup of discarded draft files."""
import json

import httpx
import pytest

from processor import supa


def client_with(handler):
    return supa.Client("http://supabase.test", "service-key", transport=httpx.MockTransport(handler))


def test_discarded_take_asks_for_a_batch():
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(200, json=[{"id": "u-1", "storage_path": "home/b/u-1.jpg"}])

    with client_with(handler) as c:
        assert c.discarded_take(50) == [{"id": "u-1", "storage_path": "home/b/u-1.jpg"}]
    (r,) = seen
    assert (r.method, r.url.path) == ("POST", "/rest/v1/rpc/script_discarded_take")
    assert json.loads(r.content) == {"p_limit": 50}
    assert r.headers["authorization"] == "Bearer service-key"


def test_discarded_take_with_nothing_is_empty():
    with client_with(lambda request: httpx.Response(200, json=[])) as c:
        assert c.discarded_take(50) == []


def test_mark_purged_sends_the_ids():
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(204)

    with client_with(handler) as c:
        assert c.mark_purged(["u-1", "u-2"]) is None
    (r,) = seen
    assert (r.method, r.url.path) == ("POST", "/rest/v1/rpc/script_upload_purged")
    assert json.loads(r.content) == {"p_ids": ["u-1", "u-2"]}


def test_remove_deletes_the_objects_in_one_request():
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(200, json=[])

    with client_with(handler) as c:
        c.remove("script-uploads", ["home/b/u-1.jpg", "home/b/u-2.pdf"])
    (r,) = seen
    assert (r.method, r.url.path) == ("DELETE", "/storage/v1/object/script-uploads")
    assert json.loads(r.content) == {"prefixes": ["home/b/u-1.jpg", "home/b/u-2.pdf"]}


def test_a_failed_remove_names_the_status_not_the_paths():
    with client_with(lambda request: httpx.Response(500, json={"message": "home/b/u-1.jpg"})) as c:
        with pytest.raises(supa.SupabaseError) as err:
            c.remove("script-uploads", ["home/b/u-1.jpg"])
    assert "500" in str(err.value) and "home/" not in str(err.value)


def test_record_remask_sends_the_pages_to_script_pages_remasked():
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(200, json={"ok": True, "pages": 1})

    pages = [{"page_id": "p-1", "marking_path": "e/u/9/0-marking.jpg", "rotation": 90, "key": "k"}]
    with client_with(handler) as c:
        assert c.record_remask(9, pages, worker="w-1", attempt=2) == {"ok": True, "pages": 1}
    (r,) = seen
    assert (r.method, r.url.path) == ("POST", "/rest/v1/rpc/script_pages_remasked")
    assert json.loads(r.content) == {"p_job": 9, "p_worker": "w-1", "p_attempt": 2, "p_pages": pages}
