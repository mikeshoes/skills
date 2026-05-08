import json
import os
import subprocess
import sys

import pytest

import install_config as ic


@pytest.fixture
def project(tmp_path, monkeypatch):
    """Isolated project root + isolated $HOME so L3 memory writes don't leak.
    Also neutralizes tmux probing so synthetic %pane ids aren't GC'd as orphans."""
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.delenv("TMUX", raising=False)
    monkeypatch.delenv("TMUX_PANE", raising=False)
    # Force "no tmux" mode: synthetic %pane ids stay alive.
    monkeypatch.setattr(ic, "live_tmux_panes", lambda: None)
    yield tmp_path


def _argv(monkeypatch, *args):
    monkeypatch.setattr(sys, "argv", ["install_config.py", *args])


def _dead_pid():
    p = subprocess.Popen(["true"])
    p.wait()
    return p.pid


# ---- merge_hook ----

def test_merge_hook_creates_entry(project):
    cfg = {}
    assert ic.merge_hook(cfg) is True
    cmds = [
        h["command"]
        for entry in cfg["hooks"]["PreCompact"]
        for h in entry["hooks"]
    ]
    assert ic.HOOK_CMD in cmds


def test_merge_hook_idempotent(project):
    cfg = {}
    ic.merge_hook(cfg)
    assert ic.merge_hook(cfg) is False
    assert len(cfg["hooks"]["PreCompact"]) == 1


def test_merge_hook_drops_legacy_inline(project):
    legacy = '[ -n "$TMUX" ] && for r in pm be fe qa; do echo $r; done'
    cfg = {
        "hooks": {
            "PreCompact": [{"hooks": [{"type": "command", "command": legacy}]}]
        }
    }
    ic.merge_hook(cfg)
    cmds = [
        h["command"]
        for entry in cfg["hooks"]["PreCompact"]
        for h in entry["hooks"]
    ]
    assert legacy not in cmds
    assert ic.HOOK_CMD in cmds


# ---- merge_permissions / remove_permissions ----

def test_merge_permissions_idempotent(project):
    cfg = {}
    added = ic.merge_permissions(cfg)
    assert len(added) == len(ic.PERMISSIONS_ALLOW)
    assert ic.merge_permissions(cfg) == []


def test_remove_permissions_preserves_user_entries(project):
    cfg = {}
    ic.merge_permissions(cfg)
    cfg["permissions"]["allow"].append("Bash(custom:*)")
    removed = ic.remove_permissions(cfg)
    assert removed == len(ic.PERMISSIONS_ALLOW)
    assert cfg["permissions"]["allow"] == ["Bash(custom:*)"]


def test_merge_permanent_allow_idempotent(project):
    cfg = {}
    added = ic.merge_permanent_allow(cfg)
    assert len(added) == len(ic.PERMISSIONS_PERMANENT_ALLOW)
    # 二次调用不重复
    assert ic.merge_permanent_allow(cfg) == []


def test_remove_permissions_keeps_permanent_allow(project):
    cfg = {}
    ic.merge_permissions(cfg)
    ic.merge_permanent_allow(cfg)
    ic.remove_permissions(cfg)
    # bootstrap allow 全清
    for p in ic.PERMISSIONS_ALLOW:
        assert p not in cfg["permissions"]["allow"]
    # permanent allow 留下
    for p in ic.PERMISSIONS_PERMANENT_ALLOW:
        assert p in cfg["permissions"]["allow"]


def test_merge_deny_idempotent(project):
    cfg = {}
    added = ic.merge_deny(cfg)
    assert len(added) == len(ic.PERMISSIONS_DENY)
    assert ic.merge_deny(cfg) == []


# ---- holder lifecycle ----

def test_install_creates_holder_and_perms(project, monkeypatch):
    _argv(monkeypatch, "install", "%pane1")
    ic.cmd_install()
    assert (ic.HOLDER_DIR / "%pane1").exists()
    cfg = json.loads(ic.SETTINGS.read_text())
    assert cfg["permissions"]["allow"]
    assert cfg["hooks"]["PreCompact"]


def test_revoke_clears_perms_when_last_holder(project, monkeypatch):
    _argv(monkeypatch, "install", "%pane1")
    ic.cmd_install()
    _argv(monkeypatch, "revoke", "%pane1")
    ic.cmd_revoke()
    cfg = json.loads(ic.SETTINGS.read_text())
    # Hook stays
    assert "PreCompact" in cfg.get("hooks", {})
    # Bootstrap allow 全清；permanent allow + deny 留下
    remaining_allow = cfg.get("permissions", {}).get("allow", [])
    for p in ic.PERMISSIONS_ALLOW:
        assert p not in remaining_allow, f"bootstrap perm {p} should be revoked"
    for p in ic.PERMISSIONS_PERMANENT_ALLOW:
        assert p in remaining_allow, f"permanent dev allow {p} should remain"
    remaining_deny = cfg.get("permissions", {}).get("deny", [])
    for p in ic.PERMISSIONS_DENY:
        assert p in remaining_deny, f"permanent deny {p} should remain"


def test_revoke_keeps_perms_with_other_holder(project, monkeypatch):
    _argv(monkeypatch, "install", "%pane1")
    ic.cmd_install()
    _argv(monkeypatch, "install", "%pane2")
    ic.cmd_install()
    assert ic.holder_count() == 2

    _argv(monkeypatch, "revoke", "%pane1")
    ic.cmd_revoke()
    cfg = json.loads(ic.SETTINGS.read_text())
    # 还有 holder 时 bootstrap perms 也保留
    assert cfg["permissions"]["allow"], "perms should remain while pane2 holds"
    # 至少含一项 bootstrap perm（证明 bootstrap allow 还在）
    assert any(p in cfg["permissions"]["allow"] for p in ic.PERMISSIONS_ALLOW)

    _argv(monkeypatch, "revoke", "%pane2")
    ic.cmd_revoke()
    cfg = json.loads(ic.SETTINGS.read_text())
    # 最后一个 holder 走后 bootstrap allow 应清光，permanent allow 留下
    remaining_allow = cfg.get("permissions", {}).get("allow", [])
    for p in ic.PERMISSIONS_ALLOW:
        assert p not in remaining_allow
    for p in ic.PERMISSIONS_PERMANENT_ALLOW:
        assert p in remaining_allow


def test_install_idempotent_same_pane(project, monkeypatch):
    _argv(monkeypatch, "install", "%pane1")
    ic.cmd_install()
    ic.cmd_install()
    assert ic.holder_count() == 1


# ---- GC ----

def test_gc_removes_orphan_nopane_holder(project):
    ic.HOLDER_DIR.mkdir(parents=True, exist_ok=True)
    orphan = ic.HOLDER_DIR / f"nopane-{_dead_pid()}"
    orphan.touch()
    cleaned = ic.cleanup_dead_holders()
    assert cleaned == 1
    assert not orphan.exists()


def test_gc_keeps_live_nopane_holder(project):
    ic.HOLDER_DIR.mkdir(parents=True, exist_ok=True)
    holder = ic.HOLDER_DIR / f"nopane-{os.getpid()}"
    holder.touch()
    cleaned = ic.cleanup_dead_holders()
    assert cleaned == 0
    assert holder.exists()


# ---- L3 memory merge ----

def test_l3_memory_new(project):
    status, path = ic.merge_l3_memory()
    assert status == "new"
    text = path.read_text()
    assert ic.L3_BEGIN_MARKER in text
    assert ic.L3_END_MARKER in text


def test_l3_memory_unchanged_on_second_call(project):
    ic.merge_l3_memory()
    status, _ = ic.merge_l3_memory()
    assert status == "unchanged"


def test_l3_memory_updated_when_block_tampered(project):
    ic.merge_l3_memory()
    path = ic.l3_memory_path()
    text = path.read_text()
    # Tamper with content INSIDE the block, not the markers (which contain "协议核心").
    assert "硬规则" in text, "fixture invariant: protocol_core has 硬规则 section"
    path.write_text(text.replace("硬规则", "STALE_MARKER", 1))
    status, _ = ic.merge_l3_memory()
    assert status == "updated"
    final = path.read_text()
    assert "STALE_MARKER" not in final
    assert "硬规则" in final


def test_l3_memory_appends_when_no_marker_block(project):
    target = ic.l3_memory_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("# My index\n- existing entry\n")
    status, _ = ic.merge_l3_memory()
    assert status == "new"
    text = target.read_text()
    assert "existing entry" in text
    assert ic.L3_BEGIN_MARKER in text
