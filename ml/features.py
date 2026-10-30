"""RightTime 앱이 내보낸 JSON을 학습용 표로 바꾼다 (Proposal 3.1 전처리).

한 행 = 전달된 시험 reminder 하나.
라벨 = 전달 후 T초 이내에 알림을 탭했는가 (1/0).
"""
import json
import math
from pathlib import Path

import numpy as np
import pandas as pd

LOCAL_TZ = "Asia/Seoul"
ACTIVITY_STATES = ["stationary", "walking", "running", "automotive", "cycling", "unknown"]
ACTIVITY_WINDOW_S = 30 * 60
LABEL_SECONDS = [30, 60, 120]


def load_prompts(json_path):
    """앱 내보내기 JSON에서 이미 결과가 정해진 알림만 읽는다."""
    data = json.loads(Path(json_path).read_text(encoding="utf-8"))
    prompts = [p for p in data.get("prompts", []) if p.get("outcome") != "pending"]
    return prompts, data.get("wakes", [])


def _ts(value):
    return pd.Timestamp(value).tz_convert(LOCAL_TZ) if value else None


def _activity_label(segment):
    # 앱의 ActivitySegment.label과 같은 우선순위
    for state in ["automotive", "cycling", "running", "walking", "stationary"]:
        if segment.get(state):
            return state
    return "unknown"


def _activity_features(segments, delivered):
    """전달 시점의 활동 상태와 직전 30분 동안 각 상태에 머문 비율."""
    feats = {f"act_now_{s}": 0 for s in ACTIVITY_STATES}
    feats.update({f"act_frac_{s}": 0.0 for s in ACTIVITY_STATES})
    feats["act_now_confidence"] = np.nan
    feats["act_now_age_log"] = np.nan
    feats["act_changes_30m"] = 0

    parsed = sorted(
        ((_ts(s["start"]), _activity_label(s), s.get("confidence", 0)) for s in segments),
        key=lambda x: x[0],
    )
    parsed = [p for p in parsed if p[0] <= delivered]
    # 같은 상태가 이어지는 기록은 하나로 합친다 (신뢰도만 바뀐 업데이트 등)
    parsed = [p for i, p in enumerate(parsed) if i == 0 or p[1] != parsed[i - 1][1]]
    if not parsed:
        return feats

    start, label, confidence = parsed[-1]
    feats[f"act_now_{label}"] = 1
    feats["act_now_confidence"] = confidence
    feats["act_now_age_log"] = math.log1p((delivered - start).total_seconds())

    window_start = delivered - pd.Timedelta(seconds=ACTIVITY_WINDOW_S)
    for i, (seg_start, seg_label, _) in enumerate(parsed):
        seg_end = parsed[i + 1][0] if i + 1 < len(parsed) else delivered
        overlap = (min(seg_end, delivered) - max(seg_start, window_start)).total_seconds()
        if overlap > 0:
            feats[f"act_frac_{seg_label}"] += overlap / ACTIVITY_WINDOW_S
    feats["act_changes_30m"] = sum(1 for s in parsed if s[0] >= window_start)
    return feats


def _accel_features(context):
    feats = {
        "accel_count": context.get("accelSampleCount", 0),
        "accel_mean": context.get("accelMagMean", np.nan),
        "accel_std": context.get("accelMagStd", np.nan),
        "accel_min": context.get("accelMagMin", np.nan),
        "accel_max": context.get("accelMagMax", np.nan),
    }
    feats["accel_range"] = feats["accel_max"] - feats["accel_min"]

    # 5 Hz 시계열: -1은 샘플 없는 칸
    series = np.array(context.get("accelMag5Hz", []), dtype=float)
    valid = series[series >= 0] if series.size else series
    last_60s = series[-300:] if series.size else series
    last_60s = last_60s[last_60s >= 0] if last_60s.size else last_60s
    feats["accel_coverage"] = valid.size / series.size if series.size else 0.0
    feats["accel_std_last60s"] = float(np.std(last_60s)) if last_60s.size > 10 else np.nan
    # 중력(약 1 g)에서 크게 벗어난 칸의 비율 = 움직임 정도
    feats["accel_moving_frac"] = float(np.mean(np.abs(valid - 1.0) > 0.1)) if valid.size else np.nan
    # 외부 데이터(MPU)의 Acc_Avg/Acc_Max(직전 30초, 중력 제외, m/s²)에 맞춘 근사값.
    # 5 Hz 구간 평균이라 순간 최댓값은 MPU보다 작게 나온다.
    last_30s = series[-150:] if series.size else series
    last_30s = last_30s[last_30s >= 0] if last_30s.size else last_30s
    linear = np.abs(last_30s - 1.0) * 9.81
    feats["phone_motion_avg"] = float(np.mean(linear)) if linear.size else np.nan
    feats["phone_motion_max"] = float(np.max(linear)) if linear.size else np.nan
    return feats


def build_table(prompts):
    rows = []
    for p in prompts:
        delivered = _ts(p.get("deliveredAt") or p["scheduledAt"])
        responded = _ts(p.get("respondedAt"))
        context = p.get("context") or {}

        row = {
            "id": p["id"],
            "text": p.get("text", ""),
            "delivered_at": delivered,
            "date": delivered.date(),
            "outcome": p["outcome"],
            "response_s": (responded - delivered).total_seconds() if responded is not None else np.nan,
            "has_context": int(bool(context)),
            # 시간 특징 (sin/cos 인코딩)
            "hour_sin": math.sin(2 * math.pi * (delivered.hour + delivered.minute / 60) / 24),
            "hour_cos": math.cos(2 * math.pi * (delivered.hour + delivered.minute / 60) / 24),
            "is_weekend": int(delivered.weekday() >= 5),
            "steps_5m": context.get("steps5m", np.nan),
            "steps_30m": context.get("steps30m", np.nan),
        }
        row.update(_accel_features(context))
        row.update(_activity_features(context.get("activities", []), delivered))
        for t in LABEL_SECONDS:
            tapped_in_time = p["outcome"] == "tapped" and row["response_s"] <= t
            row[f"label_{t}s"] = int(tapped_in_time)
        rows.append(row)

    return pd.DataFrame(rows).sort_values("delivered_at").reset_index(drop=True)


FEATURE_COLUMNS = (
    ["hour_sin", "hour_cos", "is_weekend", "steps_5m", "steps_30m",
     "accel_count", "accel_mean", "accel_std", "accel_min", "accel_max", "accel_range",
     "accel_coverage", "accel_std_last60s", "accel_moving_frac",
     "act_now_confidence", "act_now_age_log", "act_changes_30m"]
    + [f"act_now_{s}" for s in ACTIVITY_STATES]
    + [f"act_frac_{s}" for s in ACTIVITY_STATES]
)

# ablation용 입력 그룹 (Proposal 3.4)
FEATURE_GROUPS = {
    "time": ["hour_sin", "hour_cos", "is_weekend"],
    "steps": ["steps_5m", "steps_30m"],
    "accel": [c for c in FEATURE_COLUMNS if c.startswith("accel_")],
    "activity": [c for c in FEATURE_COLUMNS if c.startswith("act_")],
}


def time_split(df, fractions=(0.6, 0.2, 0.2)):
    """날짜 단위로 시간 순서대로 나눈다. 같은 날이 train과 test에 섞이지 않게 한다."""
    counts = df.groupby("date").size()
    cumulative = counts.cumsum() / counts.sum()
    train_days = cumulative[cumulative <= fractions[0] + 1e-9].index
    val_days = cumulative[(cumulative > fractions[0] + 1e-9) & (cumulative <= fractions[0] + fractions[1] + 1e-9)].index
    split = np.where(df["date"].isin(train_days), "train", np.where(df["date"].isin(val_days), "val", "test"))
    return df.assign(split=split)
