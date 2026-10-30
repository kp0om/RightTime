"""외부 데이터(MPU)와 RightTime 앱 데이터를 같은 입력 형식으로 맞춘다.

두 데이터 모두에서 계산할 수 있고 iPhone에서도 얻을 수 있는 입력만 쓴다.
"""
import numpy as np
import pandas as pd

from features import ACTIVITY_STATES, LABEL_SECONDS, build_table, load_prompts

START_HOUR, END_HOUR = 9, 22

COMMON_COLUMNS = (
    ["hour_sin", "hour_cos", "is_weekend",
     "act_now_age_log", "act_changes_30m",
     "phone_motion_avg_log", "phone_motion_max_log"]
    + [f"act_now_{s}" for s in ACTIVITY_STATES]
    + [f"act_frac_{s}" for s in ACTIVITY_STATES]
)


def _finish(df):
    df["phone_motion_avg_log"] = np.log1p(df["phone_motion_avg"].clip(0, 50))
    df["phone_motion_max_log"] = np.log1p(df["phone_motion_max"].clip(0, 50))
    return df


def mpu_table(csv_path):
    d = pd.read_csv(csv_path, parse_dates=["delivered_at"])
    d = d[(d.hour >= START_HOUR) & (d.hour < END_HOUR)].copy()
    hours = d.hour + d.delivered_at.dt.minute / 60
    d["hour_sin"] = np.sin(2 * np.pi * hours / 24)
    d["hour_cos"] = np.cos(2 * np.pi * hours / 24)
    d["is_weekend"] = (d.weekday >= 5).astype(int)
    for s in ACTIVITY_STATES:
        d[f"act_now_{s}"] = (d.act_now == s).astype(int)
    d["act_now_age_log"] = np.log1p(d.act_now_age_s)
    d["phone_motion_avg"] = d.acc_avg
    d["phone_motion_max"] = d.acc_max
    for t in LABEL_SECONDS:
        d[f"label_{t}s"] = (d.response_s <= t).astype(int)
    d["group"] = d.uuid
    d["source"] = "mpu"
    return _finish(d).reset_index(drop=True)


def app_table(json_path, user="me"):
    prompts, _ = load_prompts(json_path)
    d = build_table(prompts)
    if d.empty:
        return d
    d = d[(d.delivered_at.dt.hour >= START_HOUR) & (d.delivered_at.dt.hour < END_HOUR)].copy()
    d["group"] = user
    d["source"] = "app"
    return _finish(d).reset_index(drop=True)
