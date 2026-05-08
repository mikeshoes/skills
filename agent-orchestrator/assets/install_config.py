#!/usr/bin/env python3
"""install/revoke agent-orchestrator's bootstrap config in .claude/settings.local.json.

install: 加 PreCompact hook + 临时给 bash 常用命令权限，并登记一个 per-pane holder 文件
revoke:  移除当前 pane 的 holder；顺手清扫「holder 在但 tmux pane 已死」的陈尸；
         无任何活 holder 时真正移除 permissions（hook 保留）

设计要点：
  - PreCompact hook 永久保留：命令本身只读 memory 文件，无权限放大
  - permissions.allow 仅 bootstrap 期间存在；归零后回到 install 前状态
  - 每个 pane 自己一个 holder 文件（`.run/perms_holders/<pane_id>`）：
      * 同 pane 多次 install 幂等（同一文件 touch）
      * 不同 pane 并发独立计数
      * pane 崩溃/Ctrl-C 留下的孤儿 holder 由下次 install/revoke 扫尸清理（cross-check tmux list-panes）
  - argv 支持覆盖 pane_id，方便 watcher.sh exit trap 用捕获的 PANE_ID 精准 revoke
  - 旧 counter 文件（.run/orchestrator_perms_count）自动迁移清理
"""
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import time

HOOK_CMD = '[ -f .run/inject_role.sh ] && bash .run/inject_role.sh'

# bootstrap 期间会跑的 bash 命令；保守列表，无 rm/git push/curl 等危险项
PERMISSIONS_ALLOW = [
    "Bash(mkdir:*)",
    "Bash(touch:*)",
    "Bash(chmod:*)",
    "Bash(sed:*)",
    "Bash(cat:*)",
    "Bash(ls:*)",
    "Bash(date:*)",
    "Bash(echo:*)",
    "Bash(grep:*)",
    "Bash(tmux:*)",
    "Bash(bash .run/*)",
    "Bash(python3 .claude/skills/*)",
    "Bash(git pull:*)",
    "Bash(git status:*)",
]

# 永久 deny 列表（永不随 revoke 移除）
# 用于 be/fe 的 acceptEdits 模式 + pm/qa 的 default 模式都生效；多一层显式 guardrail
# bypassPermissions 模式会跳过整个权限层，本列表对它无效
PERMISSIONS_DENY = [
    "Bash(sudo:*)",
    "Bash(git push --force:*)",
    "Bash(git push -f:*)",
]

# 永久 allow 列表（永不随 revoke 移除）
# 写入项目级 .claude/settings.local.json，让 be/fe 在 acceptEdits 模式下不被 dev 命令打断
# 这是项目级配置，跨项目不污染；相比 auto 模式无 opt-in 全局写入风险
# 项目特殊命令用户可自行 append 到 settings.local.json，本列表只覆盖通用 dev 命令
PERMISSIONS_PERMANENT_ALLOW = [
    # 版本控制（force push 已在 deny；其他 git 子命令全放）
    "Bash(git:*)",
    # JS / Node 生态
    "Bash(npm:*)",
    "Bash(yarn:*)",
    "Bash(pnpm:*)",
    "Bash(node:*)",
    "Bash(npx:*)",
    # Python 生态
    "Bash(python:*)",
    "Bash(python3:*)",
    "Bash(pip:*)",
    "Bash(pip3:*)",
    "Bash(pytest:*)",
    "Bash(uv:*)",
    "Bash(poetry:*)",
    # 构建 / 通用
    "Bash(make:*)",
    "Bash(find:*)",
    "Bash(rg:*)",
    "Bash(jq:*)",
]

SETTINGS = pathlib.Path(".claude/settings.local.json")
HOLDER_DIR = pathlib.Path(".run/perms_holders")
LOCKDIR = pathlib.Path(".run/orchestrator_perms.lock.d")
LEGACY_COUNTER = pathlib.Path(".run/orchestrator_perms_count")

# L3 memory（cwd-bound）：协议核心写到这里，Claude Code 自动加载到每次 session baseline
L3_BEGIN_MARKER = "<!-- BEGIN: Comms 协议核心"
L3_END_MARKER = "<!-- END: Comms 协议核心 -->"
PROTOCOL_CORE_SOURCE = pathlib.Path(__file__).parent / "protocol_core.md"
ROLE_PACK_SOURCES = [
    pathlib.Path(__file__).parent / f"role_{r}.md" for r in ("pm", "be", "fe", "qa")
]


def l3_memory_dir() -> pathlib.Path:
    """cwd 对应的 Claude Code L3 memory 目录。
    slug 规则：cwd 绝对路径替换 / 为 -（与 ~/.claude/projects/ 子目录命名一致）"""
    slug = str(pathlib.Path.cwd().resolve()).replace("/", "-")
    return pathlib.Path.home() / ".claude" / "projects" / slug / "memory"


def l3_memory_path() -> pathlib.Path:
    return l3_memory_dir() / "MEMORY.md"


def with_lock(action):
    """mkdir-based 互斥锁，10s 超时；多 pane 并发安全。"""
    LOCKDIR.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(100):
        try:
            LOCKDIR.mkdir(exist_ok=False)
        except FileExistsError:
            time.sleep(0.1)
            continue
        try:
            return action()
        finally:
            try:
                LOCKDIR.rmdir()
            except OSError:
                pass
    raise RuntimeError(f"{LOCKDIR} 锁等待超时（10s）；可能有死锁，手动 rm -rf")


def load_cfg() -> dict:
    if SETTINGS.exists() and SETTINGS.stat().st_size > 0:
        return json.loads(SETTINGS.read_text())
    return {}


def save_cfg(cfg: dict) -> None:
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")


def _is_legacy_hook(cmd: str) -> bool:
    """老版本 inline hook 的指纹：含 TMUX 检查 + 内联角色循环，但不调 inject_role.sh"""
    return (
        '[ -n "$TMUX" ]' in cmd
        and 'for r in pm be fe qa' in cmd
        and 'inject_role.sh' not in cmd
    )


def merge_hook(cfg: dict) -> bool:
    hooks = cfg.setdefault("hooks", {})
    pre = hooks.setdefault("PreCompact", [])

    # 迁移：清掉老 inline 版（被 inject_role.sh 替代）
    for entry in pre:
        entry["hooks"] = [
            h for h in entry.get("hooks", [])
            if not _is_legacy_hook(h.get("command", ""))
        ]
    pre[:] = [e for e in pre if e.get("hooks")]

    # 已存在新版 → 跳过
    for entry in pre:
        for h in entry.get("hooks", []):
            if h.get("command") == HOOK_CMD:
                return False
    pre.append({"hooks": [{"type": "command", "command": HOOK_CMD}]})
    return True


def merge_permissions(cfg: dict) -> list[str]:
    perms = cfg.setdefault("permissions", {})
    allow = perms.setdefault("allow", [])
    added: list[str] = []
    for p in PERMISSIONS_ALLOW:
        if p not in allow:
            allow.append(p)
            added.append(p)
    return added


def merge_deny(cfg: dict) -> list[str]:
    """永久 deny 规则，不随 revoke 移除。每次 install 幂等补齐缺失项。"""
    perms = cfg.setdefault("permissions", {})
    deny = perms.setdefault("deny", [])
    added: list[str] = []
    for p in PERMISSIONS_DENY:
        if p not in deny:
            deny.append(p)
            added.append(p)
    return added


def merge_permanent_allow(cfg: dict) -> list[str]:
    """永久 allow 规则（dev 命令），不随 revoke 移除。每次 install 幂等补齐缺失项。
    跟 PERMISSIONS_ALLOW 共存于 cfg.permissions.allow，但 remove_permissions 不动它。"""
    perms = cfg.setdefault("permissions", {})
    allow = perms.setdefault("allow", [])
    added: list[str] = []
    for p in PERMISSIONS_PERMANENT_ALLOW:
        if p not in allow:
            allow.append(p)
            added.append(p)
    return added


def deploy_role_packs_to_l3() -> tuple[int, int]:
    """部署 4 份 role pack 到 L3 memory dir（lazy-load，agent 主动 Read）。
    返回 (新建数, 更新数)。已存在且内容一致 → 跳过。"""
    target_dir = l3_memory_dir()
    target_dir.mkdir(parents=True, exist_ok=True)
    new_count = 0
    updated_count = 0
    for src in ROLE_PACK_SOURCES:
        if not src.exists():
            continue
        target = target_dir / src.name
        new_content = src.read_text()
        if not target.exists():
            target.write_text(new_content)
            new_count += 1
        elif target.read_text() != new_content:
            target.write_text(new_content)
            updated_count += 1
    return (new_count, updated_count)


def merge_l3_memory() -> tuple[str, pathlib.Path]:
    """把 protocol_core.md 内容幂等 merge 到 cwd 对应的 L3 MEMORY.md。

    返回 (status, path)，status ∈ {"new", "updated", "unchanged", "missing-source"}。
    - 已有同 marker 块且内容一致 → unchanged
    - 已有同 marker 块但内容不一致 → updated（替换块内）
    - 没有 marker 块 → 追加到末尾（保留已有索引行）
    """
    if not PROTOCOL_CORE_SOURCE.exists():
        return ("missing-source", PROTOCOL_CORE_SOURCE)

    block = PROTOCOL_CORE_SOURCE.read_text().rstrip() + "\n"
    target = l3_memory_path()
    target.parent.mkdir(parents=True, exist_ok=True)

    existing = target.read_text() if target.exists() else ""

    if L3_BEGIN_MARKER in existing and L3_END_MARKER in existing:
        begin_idx = existing.index(L3_BEGIN_MARKER)
        end_idx = existing.index(L3_END_MARKER) + len(L3_END_MARKER)
        current_block = existing[begin_idx:end_idx]
        new_block = block.rstrip()
        if current_block.rstrip() == new_block:
            return ("unchanged", target)
        new_content = existing[:begin_idx] + new_block + existing[end_idx:]
        # 保证文末换行
        if not new_content.endswith("\n"):
            new_content += "\n"
        target.write_text(new_content)
        return ("updated", target)

    # 追加（保留索引行）
    if existing and not existing.endswith("\n"):
        existing += "\n"
    if existing:
        existing += "\n"  # 与块之间留空行
    target.write_text(existing + block)
    return ("new", target)


def remove_permissions(cfg: dict) -> int:
    if "permissions" not in cfg or "allow" not in cfg["permissions"]:
        return 0
    before = cfg["permissions"]["allow"]
    after = [p for p in before if p not in PERMISSIONS_ALLOW]
    cfg["permissions"]["allow"] = after
    if not after:
        cfg["permissions"].pop("allow", None)
    if not cfg["permissions"]:
        cfg.pop("permissions", None)
    return len(before) - len(after)


def my_pane_id() -> str:
    """优先级：argv[2] 显式覆盖 > $TMUX_PANE > nopane-<ppid> 兜底。"""
    if len(sys.argv) >= 3 and sys.argv[2]:
        return sys.argv[2]
    p = os.environ.get("TMUX_PANE")
    if p:
        return p
    return f"nopane-{os.getppid()}"


def sanitize(pane: str) -> str:
    """保守化：只保留字母数字 . - _ %，其他替为 _。避免奇怪字符破文件系统。"""
    return "".join(c if c.isalnum() or c in "._-%" else "_" for c in pane)


def live_tmux_panes() -> set[str] | None:
    """返回 tmux 里当前活着的 pane id 集合；tmux 不可用返回 None（表示无法判定，不做 GC）。"""
    try:
        r = subprocess.run(
            ["tmux", "list-panes", "-a", "-F", "#{pane_id}"],
            capture_output=True, text=True, timeout=3,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    return {ln.strip() for ln in r.stdout.splitlines() if ln.strip()}


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False
    except OSError:
        return False


def cleanup_dead_holders() -> int:
    """扫 HOLDER_DIR，把孤儿 holder（pane/进程已死）删掉。返回清理数量。"""
    if not HOLDER_DIR.exists():
        return 0
    live = live_tmux_panes()
    removed = 0
    for h in HOLDER_DIR.iterdir():
        if not h.is_file():
            continue
        name = h.name
        if name.startswith("nopane-"):
            # 非 tmux 兜底 holder，按 ppid 判活
            tail = name[len("nopane-"):]
            try:
                pid = int(tail)
            except ValueError:
                h.unlink(missing_ok=True)
                removed += 1
                continue
            if not pid_alive(pid):
                h.unlink(missing_ok=True)
                removed += 1
        else:
            # tmux pane holder；tmux 不可用则不做判断
            if live is None:
                continue
            if name not in live:
                h.unlink(missing_ok=True)
                removed += 1
    return removed


def holder_count() -> int:
    if not HOLDER_DIR.exists():
        return 0
    return sum(1 for h in HOLDER_DIR.iterdir() if h.is_file())


def migrate_legacy() -> None:
    """旧 counter 文件模型废弃；清掉避免混淆。"""
    LEGACY_COUNTER.unlink(missing_ok=True)


def cmd_install() -> int:
    def action():
        migrate_legacy()
        HOLDER_DIR.mkdir(parents=True, exist_ok=True)
        dead = cleanup_dead_holders()
        pane = sanitize(my_pane_id())
        holder = HOLDER_DIR / pane
        was_new = not holder.exists()
        holder.touch()
        cfg = load_cfg()
        hook_added = merge_hook(cfg)
        perms_added = merge_permissions(cfg)
        deny_added = merge_deny(cfg)
        perm_allow_added = merge_permanent_allow(cfg)
        if hook_added or perms_added or deny_added or perm_allow_added:
            save_cfg(cfg)
        n = holder_count()
        l3_status, l3_path = merge_l3_memory()
        rp_new, rp_updated = deploy_role_packs_to_l3()
        return (hook_added, perms_added, deny_added, perm_allow_added,
                n, pane, was_new, dead, l3_status, l3_path, rp_new, rp_updated)

    (hook_added, perms_added, deny_added, perm_allow_added,
     n, pane, was_new, dead, l3_status, l3_path, rp_new, rp_updated) = with_lock(action)
    parts = [
        "hook 新建" if hook_added else "hook 已存在",
        f"权限 +{len(perms_added)}" if perms_added else "权限 已齐",
        f"holder={pane}({'new' if was_new else 'existing'})",
        f"active={n}",
    ]
    if deny_added:
        parts.append(f"deny +{len(deny_added)}")
    if perm_allow_added:
        parts.append(f"dev allow +{len(perm_allow_added)}")
    l3_label = {
        "new": "L3 协议核心 已注入",
        "updated": "L3 协议核心 已更新",
        "unchanged": "L3 协议核心 已是最新",
        "missing-source": "⚠️ L3 协议核心源文件缺失",
    }.get(l3_status, f"L3:{l3_status}")
    parts.append(l3_label)
    if rp_new or rp_updated:
        parts.append(f"role pack 部署 (新 {rp_new} / 更新 {rp_updated})")
    else:
        parts.append("role pack 已最新")
    if dead:
        parts.append(f"GC {dead} 陈尸")
    print(f"✅ install: {' · '.join(parts)}")
    if l3_status in ("new", "updated"):
        print(f"   L3 路径：{l3_path}")
    return 0


def cmd_revoke() -> int:
    def action():
        migrate_legacy()
        HOLDER_DIR.mkdir(parents=True, exist_ok=True)
        pane = sanitize(my_pane_id())
        holder = HOLDER_DIR / pane
        had_holder = holder.exists()
        holder.unlink(missing_ok=True)
        dead = cleanup_dead_holders()
        remaining = holder_count()
        if remaining > 0:
            return remaining, 0, dead, pane, had_holder
        cfg = load_cfg()
        removed = remove_permissions(cfg)
        if removed:
            save_cfg(cfg)
        try:
            HOLDER_DIR.rmdir()
        except OSError:
            pass
        return remaining, removed, dead, pane, had_holder

    remaining, removed, dead, pane, had_holder = with_lock(action)
    holder_note = f"holder={pane}({'清' if had_holder else '本就不在'})"
    gc_note = f" · GC {dead} 陈尸" if dead else ""
    if remaining > 0:
        print(f"⏳ revoke: {holder_note} · 还有 {remaining} 个 holder 活着，暂不移除 permissions{gc_note}")
    else:
        print(f"✅ revoke: {holder_note} · 移除 {removed} 条 bootstrap permissions（hook 保留）{gc_note}")
    return 0


def cmd_gc() -> int:
    """独立扫尸命令：不动自己的 holder，只清孤儿；holders 归零则顺手移除 perms。"""
    def action():
        migrate_legacy()
        HOLDER_DIR.mkdir(parents=True, exist_ok=True)
        dead = cleanup_dead_holders()
        remaining = holder_count()
        removed = 0
        if remaining == 0:
            cfg = load_cfg()
            removed = remove_permissions(cfg)
            if removed:
                save_cfg(cfg)
            try:
                HOLDER_DIR.rmdir()
            except OSError:
                pass
        return dead, remaining, removed

    dead, remaining, removed = with_lock(action)
    parts = [f"GC {dead} 陈尸", f"active={remaining}"]
    if remaining == 0 and removed:
        parts.append(f"移除 {removed} 条 permissions")
    print(f"✅ gc: {' · '.join(parts)}")
    return 0


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "install"
    if cmd == "install":
        return cmd_install()
    if cmd == "revoke":
        return cmd_revoke()
    if cmd == "gc":
        return cmd_gc()
    print(f"Usage: {sys.argv[0]} install|revoke|gc [pane_id]", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
