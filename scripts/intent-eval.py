#!/usr/bin/env python3
"""Intent eval for the phone's input bar (NoteAssistant): 24 utterances against a generated to-do
list, each scored on what it should and shouldn't change. Runs aist-cli assist per case.

    scripts/intent-eval.py .build/debug/aist-cli            # 8-item list
    scripts/intent-eval.py .build/debug/aist-cli --big      # 30-item list (id confusion, 「第一条」)
    scripts/intent-eval.py .build/debug/aist-cli reopen-done unknown-ref   # just these cases

Provider: AIST_BASE_URL / AIST_FORMAT / AIST_MODEL / AIST_API_KEY as for the CLI; without them the
CLI uses ~/.config/aist/config.json (run via scripts/gui-run.sh over SSH, the keychain is locked there).
The list is written to a temp file with deadlines relative to now, so expectations never go stale.
"""
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import uuid

args = [a for a in sys.argv[1:] if not a.startswith("--")]
if not args:
    sys.exit(__doc__)
CLI = args[0]
ONLY = set(args[1:])
BIG = "--big" in sys.argv

NOW = dt.datetime.now().astimezone()
TODAY = NOW.date()


def at(days, hour, minute=0):
    return (NOW + dt.timedelta(days=days)).replace(hour=hour, minute=minute, second=0, microsecond=0)


def iso(d):
    return d.isoformat(timespec="seconds") if d else None


def weekday_ahead(wd):  # next date with that weekday (0=Mon), strictly after today
    d = TODAY + dt.timedelta(days=1)
    while d.weekday() != wd:
        d += dt.timedelta(days=1)
    return d


def next_week(wd):  # that weekday in the following calendar week
    return TODAY + dt.timedelta(days=(7 - TODAY.weekday()) + wd)


FRIDAY = (4 - NOW.weekday()) % 7 or 7


def mk(title, due=None, pri="medium", who=None, done=False, text=None, age=0):
    created = NOW - dt.timedelta(days=age)
    return {
        "id": str(uuid.uuid4()).upper(), "title": title, "requester": who, "source": "随手记",
        "dueText": text, "dueAt": iso(due), "priority": pri, "evidence": None,
        "status": "done" if done else "open", "origin": "manual",
        "createdAt": iso(created), "updatedAt": iso(created),
        "completedAt": iso(NOW - dt.timedelta(hours=20)) if done else None, "notes": None,
    }


todos = [
    mk("给 Sarah 回邮件确认 vendor quote", at(1, 15), "high", "Sarah Lim", text="明天下午", age=1),
    mk("今晚去超市买菜", at(0, 20), text="今晚"),
    mk("整理 Q3 复盘文档", at(FRIDAY, 17), text="周五", age=3),
    mk("预约车子保养", age=5),
    mk("参加 AstraFlow 周会", at(1, 10), age=2),
    mk("给房东转房租", None, "high", age=1),
    mk("提交出差报销", done=True, age=4),
    mk("把项目周报发给老板", at(FRIDAY, 18), text="周五前"),
]
if BIG:
    filler = [
        ("更新简历上的项目经历", None, "low"), ("给 Lily 发 Q4 预算表", at(2, 18), "medium"),
        ("续签办公室打印机维保", at(6, 18), "low"), ("看牙医拿洗牙报告", None, "low"),
        ("回复 HR 关于年假的邮件", at(1, 18), "medium"), ("订下周一去槟城的机票", at(3, 18), "high"),
        ("给小区物业交停车费", at(5, 18), "medium"), ("整理 AstraFlow 发版 checklist", at(2, 17), "medium"),
        ("买打印纸和笔", None, "low"), ("把合同扫描件发给财务", at(1, 12), "high"),
        ("帮妈妈换手机套餐", None, "low"), ("跟 Ahmad 确认 Sandbox CI 失败原因", at(1, 18), "high"),
        ("报名 11 月的产品沙龙", at(4, 18), "low"), ("取干洗的西装", at(2, 19), "low"),
        ("写 Thinkfree 会议纪要发群里", at(0, 18), "medium"), ("预约宠物疫苗", None, "medium"),
        ("把车停到 B2 之前先缴费", None, "low"), ("退掉多买的显示器支架", at(7, 18), "low"),
        ("给 Wang Hui 发测试账号", at(1, 11), "medium"), ("交水电费", at(3, 18), "medium"),
        ("改 landing page 文案", at(5, 17), "low"), ("申请新加坡出差签证", at(2, 18), "high"),
    ]
    todos += [mk(t, d, p, age=i % 6) for i, (t, d, p) in enumerate(filler)]

TODOS = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
json.dump(todos, TODOS, ensure_ascii=False)
TODOS.close()


def screen_first():
    """The first open row on screen: pinned, overdue, due today, due in 2 days…, earliest deadline first."""
    def rank(t):
        d = dt.datetime.fromisoformat(t["dueAt"]) if t.get("dueAt") else None
        if t.get("pinned"): r = 0
        elif d and d < NOW: r = 1
        elif d and d.date() == TODAY: r = 2
        elif d and (d - NOW).total_seconds() < 2 * 86400: r = 3
        elif t["priority"] == "high": r = 4
        elif d and (d - NOW).total_seconds() < 7 * 86400: r = 5
        else: r = 6 if t["priority"] == "medium" else 7
        return (r, d or dt.datetime.max.replace(tzinfo=NOW.tzinfo), -dt.datetime.fromisoformat(t["createdAt"]).timestamp())
    return min((t for t in todos if t["status"] == "open"), key=rank)["id"]


def tid(sub):
    if sub is None:
        return screen_first()
    for t in todos:
        if sub in t["title"]:
            return t["id"]
    raise SystemExit(f"no todo matching {sub}")


def day_of(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone().date() if s else None


CASES = [
    dict(name="done-email", text="Sarah 的邮件回了", complete=["Sarah"], add=0, update=0, remove=0),
    dict(name="code-switch-done", text="Sarah 的 email 已经 reply 了", complete=["Sarah"], add=0, update=0, remove=0),
    dict(name="move-groceries", text="买菜明天再去", update=[dict(m="买菜", day=TODAY + dt.timedelta(days=1), title_not="今晚")], add=0, complete=0, remove=0),
    dict(name="position-ref", text="第一条推到明天", update=[dict(m=None, day=TODAY + dt.timedelta(days=1))], add=0, complete=0, remove=0),
    dict(name="cancel-service", text="车保养不用约了", remove=["保养"], add=0, update=0, complete=0),
    dict(name="defer-by-person", text="Sarah 那个不急，下周再说", update=[dict(m="Sarah")], add=0, complete=0, remove=0),
    dict(name="done+add", text="房租转了，顺便记一下周五给爸爸买生日礼物", complete=["房租"], add=1, update=0, remove=0),
    dict(name="question-status", text="复盘文档写完了吗", nochange=True, reply=True),
    dict(name="chit-chat", text="今天好累啊", nochange=True),
    dict(name="musing", text="明天要不要去保养车呢", nochange=True),
    dict(name="reopen-done", text="报销那个其实还没交完", reopen=["报销"], add=0, remove=0),
    dict(name="unknown-ref", text="把和 Sarah 签合同那个改到周三", update=0, add=0, remove=0, complete=0, reply=True),
    dict(name="ideas", text="帮我想想搬家前要做哪些事", suggestions=3, add=0, update=0),
    dict(name="meeting-move", text="周会改到周四下午三点，地点换成 5 楼会议室",
         update=[dict(m="周会", day=weekday_ahead(3), hour=15, details="5 楼")], add=0, complete=0, remove=0),
    # Milk and bread may become one errand, or be folded into the existing grocery trip (update).
    dict(name="three-items", text="买牛奶、面包，还有去银行办卡", add=(1, 3), touched=(2, 3), complete=0),
    dict(name="doc-reschedule", text="复盘文档推到下周三", update=[dict(m="复盘", day=next_week(2))], add=0, complete=0),
    dict(name="done+reschedule", text="菜买好了，车保养约在下周二上午十点", complete=["买菜"],
         update=[dict(m="保养", day=next_week(1), hour=10)], add=0, remove=0),
    dict(name="count-question", text="还有几件没做？", nochange=True, reply=True),
    dict(name="delete-rent", text="算了，房租那条删掉", remove=["房租"], add=0, complete=0, update=0),
    dict(name="details-into-existing", text="Sarah 说 quote 改成 RM 52,000，她电话 0123456789",
         update=[dict(m="Sarah", details="52,000", details2="0123456789")], add=0, complete=0),
    dict(name="memo-only", text="房东的电话是 012-345 6789", update=[dict(m="房租", details="012-345 6789")], add=0, complete=0),
    dict(name="voice-mess", text="嗯那个 就是 Sarah 那个邮件 我已经回了啊 然后车保养的话 下周再约吧",
         complete=["Sarah"], update=[dict(m="保养")], add=0, remove=0),
    dict(name="followup-fix", text="刚才那个改成周三，不是周五",
         recent="用户说：周五前把项目周报发给老板\n你做了：新增「把项目周报发给老板」（周五 18:00）",
         update=[dict(m="周报", day=weekday_ahead(2))], add=0, complete=0),
    dict(name="followup-pick", text="第二个",
         recent="用户说：那个改到周三\n你做了：什么都没改；回复「你说的是「整理 Q3 复盘文档」还是「把项目周报发给老板」？」",
         update=[dict(m="周报", day=weekday_ahead(2))], add=0, complete=0),
]


def run(case):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write(case["text"])
    cmd = [CLI, "assist", f.name, "--todos", TODOS.name]
    if case.get("recent"):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as r:
            r.write(case["recent"])
        cmd += ["--recent", r.name]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if p.returncode != 0:
        return None, p.stderr.strip()[-300:]
    return json.loads(p.stdout), p.stderr.strip()


def check(case, r):
    probs = []
    cnt = {k: len(r.get(k) or []) for k in ("add", "complete", "update", "remove", "suggestions", "reopen")}
    ids = lambda k: [x.get("id") for x in (r.get(k) or [])]
    if case.get("nochange") and any(cnt[k] for k in ("add", "complete", "update", "remove", "reopen")):
        probs.append(f"changed something: {cnt}")
    for k in ("add", "update", "complete", "remove"):
        exp = case.get(k)
        if isinstance(exp, int) and cnt[k] != exp:
            probs.append(f"{k}={cnt[k]} want {exp}")
        elif isinstance(exp, tuple) and not (exp[0] <= cnt[k] <= exp[1]):
            probs.append(f"{k}={cnt[k]} want {exp[0]}-{exp[1]}")
        elif isinstance(exp, list):
            if k in ("complete", "remove"):
                for sub in exp:
                    if tid(sub) not in ids(k):
                        probs.append(f"{k} missing {sub}")
                if cnt[k] != len(exp):
                    probs.append(f"{k}={cnt[k]} want {len(exp)}")
            else:
                for spec in exp:
                    hit = next((u for u in r.get("update") or [] if u.get("id") == tid(spec["m"])), None)
                    if not hit:
                        probs.append(f"update missing {spec['m'] or 'first row'}")
                        continue
                    if "day" in spec and day_of(hit.get("due_at")) != spec["day"]:
                        probs.append(f"{spec['m']} due {day_of(hit.get('due_at'))} want {spec['day']}")
                    if "hour" in spec and hit.get("due_at"):
                        h = dt.datetime.fromisoformat(hit["due_at"]).astimezone().hour
                        if h != spec["hour"]:
                            probs.append(f"{spec['m']} hour {h} want {spec['hour']}")
                    if "title_not" in spec and spec["title_not"] in (hit.get("title") or ""):
                        probs.append(f"{spec['m']} title still has {spec['title_not']}: {hit.get('title')}")
                    for key in ("details", "details2"):
                        if key in spec and spec[key] not in (hit.get("details") or ""):
                            probs.append(f"{spec['m']} details lack {spec[key]}")
                if cnt["update"] != len(exp):
                    probs.append(f"update={cnt['update']} want {len(exp)}")
    if "touched" in case:
        n = cnt["add"] + cnt["update"]
        if not (case["touched"][0] <= n <= case["touched"][1]):
            probs.append(f"add+update={n} want {case['touched']}")
    if "reopen" in case:
        for sub in case["reopen"]:
            if tid(sub) not in ids("reopen"):
                probs.append(f"reopen missing {sub} (reopen={cnt['reopen']} update={cnt['update']} add={cnt['add']})")
    if "suggestions" in case and cnt["suggestions"] < case["suggestions"]:
        probs.append(f"suggestions={cnt['suggestions']} want >={case['suggestions']}")
    reply = r.get("reply") or ""
    if case.get("reply") and not reply.strip():
        probs.append("no reply")
    if re.search(r"[#＃]\d", reply):
        probs.append("reply shows a row number")
    if r.get("unresolved"):
        probs.append(f"unresolved refs: {r['unresolved']}")
    return probs


passed = 0
selected = [c for c in CASES if not ONLY or c["name"] in ONLY]
for case in selected:
    r, err = run(case)
    if r is None:
        print(f"ERR  {case['name']:22} {err}")
        continue
    probs = check(case, r)
    passed += not probs
    did = " ".join(f"{k}={len(r.get(k) or [])}" for k in ("add", "complete", "reopen", "update", "remove", "suggestions") if r.get(k))
    print(f"{'ok' if not probs else 'FAIL':4} {case['name']:22} {did} | {(r.get('reply') or '')[:60]}" + ("" if not probs else f" || {'; '.join(probs)}"))
    sys.stdout.flush()
os.unlink(TODOS.name)
print(f"\n{passed}/{len(selected)} passed")
