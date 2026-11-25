import pytest

from musicsync.playlists import PlaylistError, PlaylistStore, now_ms, TOMBSTONE_TTL_MS


@pytest.fixture
def store(tmp_path):
    return PlaylistStore(tmp_path / "pl.json")


def test_crud(store, tmp_path):
    p = store.create("  My   Mix ", ["a", "b"])
    assert p.name == "My Mix"
    store.add_tracks(p.id, ["c"])
    store.remove_tracks(p.id, ["a"])
    assert store.get(p.id).track_ids == ["b", "c"]
    store.update(p.id, name="Renamed")
    reloaded = PlaylistStore(tmp_path / "pl.json")
    assert reloaded.get(p.id).name == "Renamed"
    assert reloaded.find("renamed").id == p.id
    assert store.delete(p.id)
    assert store.get(p.id) is None
    assert store.all() == []
    assert store.all(include_deleted=True)[0].deleted
    assert not store.delete(p.id)


def test_duplicates_allowed_and_order_kept(store):
    p = store.create("x", ["a", "b", "a"])
    assert p.track_ids == ["a", "b", "a"]


def test_empty_name_rejected(store):
    with pytest.raises(PlaylistError):
        store.create("   ")


def test_updated_at_monotonic(store):
    p = store.create("x")
    p.updated_at = now_ms() + 10_000_000  # 未来の時刻（他端末の時計が進んでいた）
    before = p.updated_at
    store.update(p.id, name="y")
    assert store.get(p.id).updated_at > before


def test_merge_last_writer_wins(store):
    p = store.create("server", ["a"])
    newer = {"id": p.id, "name": "client", "trackIds": ["b"], "updatedAt": p.updated_at + 5}
    older = {"id": p.id, "name": "stale", "trackIds": [], "updatedAt": p.updated_at - 5}
    store.merge([older])
    assert store.get(p.id).name == "server"
    store.merge([newer])
    assert store.get(p.id).name == "client"
    # 同時刻ならサーバー優先
    same = {"id": p.id, "name": "tie", "trackIds": [], "updatedAt": store.get(p.id).updated_at}
    store.merge([same])
    assert store.get(p.id).name == "client"


def test_merge_new_and_deleted(store):
    keep = store.create("keep")
    gone = store.create("gone")
    merged = store.merge([
        {"id": "new-1", "name": "from phone", "trackIds": ["z"], "updatedAt": now_ms()},
        {"id": gone.id, "name": "", "trackIds": [], "updatedAt": gone.updated_at + 1, "deleted": True},
    ])
    ids = {p.id: p for p in merged}
    assert ids["new-1"].name == "from phone"
    assert ids[gone.id].deleted
    assert store.get(gone.id) is None
    assert store.get(keep.id)


def test_merge_rejects_invalid_atomically(store):
    with pytest.raises(PlaylistError):
        store.merge([
            {"id": "ok", "name": "fine", "trackIds": [], "updatedAt": 1},
            {"id": "bad", "name": "x", "trackIds": [1, 2], "updatedAt": 1},
        ])
    assert store.all() == []
    for bad in [None, {"id": ""}, {"id": "x", "name": 3}, {"id": "x", "name": "a", "updatedAt": "1"},
                {"id": "x", "name": "a", "updatedAt": True}]:
        with pytest.raises(PlaylistError):
            store.merge([bad])


def test_old_tombstones_purged(store):
    p = store.create("old")
    store.delete(p.id)
    store._items[p.id].updated_at = now_ms() - TOMBSTONE_TTL_MS - 1
    store.create("trigger save")
    assert p.id not in {x.id for x in store.all(include_deleted=True)}
    # 古い tombstone をクライアントから受け取っても復活させない
    store.merge([{"id": "ancient", "name": "", "trackIds": [], "deleted": True,
                  "updatedAt": now_ms() - TOMBSTONE_TTL_MS - 5}])
    assert "ancient" not in {x.id for x in store.all(include_deleted=True)}


def test_prune_missing(store):
    p = store.create("x", ["a", "b", "c"])
    assert store.prune_missing_tracks({"a", "c"}) == 1
    assert store.get(p.id).track_ids == ["a", "c"]
