"""今朝の新着案件を GitHub Issue の本文にまとめる（Issue 作成で GitHub から持ち主にメールが届く）。

新着 = firstSeen が今日（日本時間）・分野タグあり・終了していない案件。
新着があれば mail_title.txt / mail_body.md を書き出し、件数を標準出力に出す。
"""
import json
import sys
from datetime import datetime, timedelta, timezone

SITE = "https://tshibayama0518.github.io/shizuoka-bid-watch/"

today = datetime.now(timezone(timedelta(hours=9))).strftime("%Y-%m-%d")
data = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "docs/data.json", encoding="utf-8"))

new = [it for it in data["items"] if it.get("firstSeen") == today and it.get("tags") and not it.get("closed")]
new.sort(key=lambda it: (not it.get("deadline"), it.get("deadline") or ""))

if new:
    lines = [f"入札ラボ 今朝の新着案件です（{today}）", ""]
    for it in new:
        org = it.get("org") or ""
        city = it.get("city") or ""
        if city and city not in org:
            org = f"{org}（{city}）"
        lines.append(f"### {it['title']}")
        lines.append(f"- 発注元：{org}")
        lines.append(f"- 締切：{it.get('deadline') or '資料で確認'}")
        budget = it.get("budget")
        if isinstance(budget, (int, float)) and budget > 0:
            lines.append(f"- 予算：{int(budget):,}円")
        lines.append(f"- 分野：{' / '.join(it['tags'])}")
        lines.append(f"- {it['url']}")
        lines.append("")
    lines.append(f"一覧はこちら：{SITE}")
    lines.append("")
    lines.append("※入札ラボの毎朝の自動通知です。")
    open("mail_title.txt", "w", encoding="utf-8").write(f"【入札ラボ】新着案件 {len(new)}件（{today}）")
    open("mail_body.md", "w", encoding="utf-8").write("\n".join(lines) + "\n")

print(len(new))
