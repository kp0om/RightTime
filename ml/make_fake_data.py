"""코드 점검용 가짜 데이터 생성기. 실제 실험 결과로 쓰지 않는다.

    python ml/make_fake_data.py data/fake.json
"""
import json
import random
import sys
from datetime import datetime, timedelta, timezone

random.seed(0)
KST = timezone(timedelta(hours=9))


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fake_prompt(when):
    walking = random.random() < 0.3
    still_prob = 0.25 if walking else 0.6
    tapped = random.random() < still_prob
    response = random.expovariate(1 / 50) if tapped else None
    activity_start = when - timedelta(minutes=random.randint(1, 120))
    series = [round(1.0 + random.gauss(0, 0.25 if walking else 0.02), 3) for _ in range(1500)]
    prompt = {
        "id": f"fake-{when.timestamp():.0f}",
        "text": "가짜 알림",
        "scheduledAt": iso(when),
        "deliveredAt": iso(when),
        "outcome": "tapped" if tapped else random.choice(["noResponse", "dismissed"]),
        "context": {
            "windowSeconds": 300,
            "accelSampleCount": 15000,
            "accelMagMean": 1.0, "accelMagStd": 0.25 if walking else 0.02,
            "accelMagMin": 0.4 if walking else 0.95, "accelMagMax": 1.8 if walking else 1.05,
            "accelMag5Hz": series,
            "activities": [{
                "start": iso(activity_start), "stationary": not walking, "walking": walking,
                "running": False, "automotive": False, "cycling": False, "unknown": False,
                "confidence": 2,
            }],
            "steps5m": random.randint(200, 500) if walking else random.randint(0, 10),
            "steps30m": random.randint(300, 2000),
            "collectedAt": iso(when + timedelta(minutes=10)),
            "notes": [],
        },
    }
    if tapped:
        prompt["respondedAt"] = iso(when + timedelta(seconds=response))
    return prompt


def main(path):
    start = datetime(2026, 10, 29, tzinfo=KST)
    prompts = []
    for day in range(18):
        for _ in range(7):
            when = start + timedelta(days=day, hours=random.uniform(9, 22))
            prompts.append(fake_prompt(when))
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"prompts": prompts, "wakes": [], "settings": {}}, f, ensure_ascii=False)
    print(f"가짜 알림 {len(prompts)}개 → {path}")


if __name__ == "__main__":
    main(sys.argv[1])
