"""Generate two synthetic days of real speech and push them through the running app.

Speech is synthesised with macOS `say` (different voices for the user and other people),
uploaded like Watch recordings, transcribed locally (SenseVoice by default), then processed hourly
(Highlights, Summary, memory) and reflected on. All content is fictional.

  python scripts/demo_day.py --server http://127.0.0.1:8765
"""

import argparse
import json
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

ME_ZH, ME_EN, OTHER_ZH = "Tingting", "Samantha", "Eddy (Chinese (China mainland))"

# (day offset, "HH:MM", speaker, voice, language, text, mark)
SCRIPT = [
    (-2, "09:20", "user", ME_EN, "en", "My main code editor is Neovim, I've used it for years.", False),
    (-2, "13:05", "user", ME_ZH, "zh", "坐飞机我一般选靠窗的座位，可以看风景。", False),
    (-2, "13:06", "S2", OTHER_ZH, "zh", "那下次出差我帮你订靠窗的。", False),
    (-1, "08:30", "user", ME_ZH, "zh", "早上好，老样子，来一杯燕麦拿铁，少冰。", False),
    (-1, "08:31", "S2", OTHER_ZH, "zh", "好的，燕麦拿铁少冰，马上就好。", False),
    (-1, "09:40", "user", ME_ZH, "zh", "我以前每周三打羽毛球，现在改成每周五晚上了，因为周三要开组会。", False),
    (-1, "10:15", "S2", OTHER_ZH, "zh", "这个版本能不能下周四上线？", False),
    (-1, "10:16", "user", ME_ZH, "zh", "可以，我答应下周四之前把记忆系统的合并模块写完，并且补上测试。", True),
    (-1, "10:17", "S2", OTHER_ZH, "zh", "好，那我周五安排评审。", False),
    (-1, "12:20", "user", ME_ZH, "zh", "老板，这碗面别放香菜，我不吃香菜。", False),
    (-1, "14:00", "S2", OTHER_ZH, "zh", "跟你说个消息，我下个月要搬去上海了，新工作在陆家嘴。", False),
    (-1, "14:01", "user", ME_ZH, "zh", "恭喜啊！我妹妹也在上海，她在读医学院，你们可以认识一下。", False),
    (-1, "15:30", "user", ME_EN, "en", "Quick note to self: I switched my main code editor from Neovim to Zed last week.", False),
    (-1, "15:32", "user", ME_ZH, "zh", "我现在坐飞机更喜欢靠过道了，方便起来走动。", False),
    (-1, "17:10", "user", ME_ZH, "zh", "我家那只猫叫年糕，晚上回去要记得给它买猫粮。", True),
    (-1, "19:00", "user", ME_ZH, "zh", "哈，我可太喜欢排队了，今天在超市排了四十分钟。", False),
    (-1, "21:30", "user", ME_ZH, "zh", "今天有点累，但合并模块的思路理清楚了。下周二下午三点要去看牙医，别忘了。", False),
]


def call(server, path, body=None, raw=None, method=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    request = urllib.request.Request(server + "/api/" + path, data, method=method or ("POST" if data else "GET"))
    if body is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=600) as response:
        return json.load(response)


def wait_idle(server, label, timeout=1800):
    started = time.time()
    while time.time() - started < timeout:
        status = call(server, "status")
        if not status["queue"] and not status["current"]:
            return status
        print(f"  {label}: queue={status['queue']} current={status['current']}", flush=True)
        time.sleep(5)
    raise TimeoutError(label)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default="http://127.0.0.1:8765")
    args = parser.parse_args()
    today = datetime.now().astimezone().replace(second=0, microsecond=0)
    work = Path(tempfile.mkdtemp(prefix="auday-demo-"))

    for offset in sorted({row[0] for row in SCRIPT}):
        for n, (day, clock, speaker, voice, language, text, mark) in enumerate(SCRIPT):
            if day != offset:
                continue
            hour, minute = map(int, clock.split(":"))
            start = (today + timedelta(days=day)).replace(hour=hour, minute=minute)
            audio = work / f"{n:02d}.aiff"
            if subprocess.run(["say", "-v", voice, "-o", str(audio), text]).returncode:
                # Voice not installed on this Mac: fall back to the system voice.
                subprocess.run(["say", "-o", str(audio), text], check=True)
            query = urllib.parse.urlencode({"start": start.isoformat(), "ext": "aiff",
                                            "speaker": speaker, "language": language})
            asset = call(args.server, f"audio?{query}", raw=audio.read_bytes())
            if mark:
                call(args.server, "marks", {"start": (start + timedelta(seconds=3)).isoformat()})
            print(f"uploaded {asset['id']} {speaker}: {text}", flush=True)
        # Transcription, then the scheduler processes every finished hour of this day.
        wait_idle(args.server, f"day {offset} transcription")
        time.sleep(25)
        wait_idle(args.server, f"day {offset} hourly AI")

    for offset in sorted({row[0] for row in SCRIPT}):
        date = (today + timedelta(days=offset)).date().isoformat()
        call(args.server, "reflection", {"date": date})
        wait_idle(args.server, f"reflection {date}")
    status = call(args.server, "status")
    print(json.dumps(status["counts"], ensure_ascii=False))
    for item in status["activity"]:
        print(("  " if item["ok"] else "! ") + item["ts"] + " " + item["text"])


if __name__ == "__main__":
    main()
