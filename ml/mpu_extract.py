"""Telefónica Mobile Phone Use(MPU) 데이터에서 ESM 알림 프로브를 RightTime 형식의 표로 뽑는다.

MPU 앱은 약 1~1.5시간마다 감정 설문 알림(ESM)을 보내고, 게시·클릭·응답·시간초과 시각을 남겼다.
이는 RightTime 수집 단계(무작위 시각 시험 알림 → 탭까지 걸린 시간)와 같은 구조라서,
'알림 전달 → T초 이내 클릭' 라벨과 직전 활동·가속도·시간 특징을 그대로 만들 수 있다.

    python ml/mpu_extract.py /path/to/mpu.zip out.csv
"""
import sys
import zipfile

import numpy as np
import pandas as pd

USECOLS = ["uuid", "ts", "sensor_id", "DayOfWeek", "HourOfDay", "Acc_Avg", "Acc_Max",
           "Esm_Posted", "Esm_Timedout", "Esm_Clicked", "Esm_Responded",
           "UserAct_Type", "UserAct_p", "Screen_Value"]
ACT_MAP = {  # Google Activity Recognition → RightTime(Core Motion) 상태
    "still": "stationary", "tilting": "stationary", "on_foot": "walking", "walking": "walking",
    "running": "running", "in_vehicle": "automotive", "on_bicycle": "cycling", "unknown": "unknown",
}
STATES = ["stationary", "walking", "running", "automotive", "cycling", "unknown"]
WINDOW = pd.Timedelta(minutes=30)


def probes_for_user(df):
    df["ts"] = pd.to_datetime(df["ts"])
    esm = df[df.sensor_id == "Esm"].copy()
    if esm.empty:
        return []
    for c in ["Esm_Posted", "Esm_Timedout", "Esm_Clicked", "Esm_Responded"]:
        esm[c] = pd.to_datetime(esm[c], errors="coerce")
    # 같은 프로브가 여러 줄로 남으므로 게시 시각으로 묶는다
    probes = esm.groupby("Esm_Posted").agg(
        clicked=("Esm_Clicked", "min"), responded=("Esm_Responded", "min"), timedout=("Esm_Timedout", "min"),
    ).reset_index()

    act = df[df.sensor_id == "UserAct"][["ts", "UserAct_Type"]].dropna().sort_values("ts")
    act["state"] = act.UserAct_Type.map(ACT_MAP).fillna("unknown")
    acc = df[df.sensor_id == "Acc"][["ts", "Acc_Avg", "Acc_Max"]].dropna().sort_values("ts")
    screen = df[df.sensor_id == "Screen"][["ts", "Screen_Value"]].dropna().sort_values("ts")

    rows = []
    for p in probes.itertuples():
        t = p.Esm_Posted
        row = {
            "uuid": df.uuid.iloc[0], "delivered_at": t, "hour": t.hour, "weekday": t.weekday(),
            "response_s": (p.clicked - t).total_seconds() if pd.notna(p.clicked) else np.nan,
            "responded": int(pd.notna(p.responded)), "timed_out": int(pd.notna(p.timedout)),
        }
        before = act[act.ts <= t]
        if len(before):
            last = before.iloc[-1]
            row["act_now"] = last.state
            row["act_now_age_s"] = (t - last.ts).total_seconds()
            # 직전 30분 동안 각 상태에 머문 비율
            seg = before[before.ts >= t - WINDOW]
            starts = [max(t - WINDOW, x) for x in ([last.ts] if seg.empty else [])]
            times = list(seg.ts) + [t]
            states = list(seg.state)
            prior = before[before.ts < t - WINDOW]
            if len(prior):
                times = [t - WINDOW] + times
                states = [prior.iloc[-1].state] + states
            frac = dict.fromkeys(STATES, 0.0)
            for s, a, b in zip(states, times[:-1], times[1:]):
                frac[s] += (b - a) / WINDOW
            row.update({f"act_frac_{s}": v for s, v in frac.items()})
            row["act_changes_30m"] = len(seg)
        a = acc[(acc.ts <= t) & (acc.ts >= t - pd.Timedelta(minutes=10))]
        if len(a):
            row["acc_avg"], row["acc_max"] = a.iloc[-1].Acc_Avg, a.iloc[-1].Acc_Max
        s = screen[screen.ts <= t]
        row["screen_state"] = s.iloc[-1].Screen_Value if len(s) else np.nan  # iOS에서는 못 얻는 값 (분석용)
        rows.append(row)
    return rows


def main(zip_path, out_path):
    rows = []
    with zipfile.ZipFile(zip_path) as z:
        names = sorted(n for n in z.namelist() if n.startswith("mobile_phone_use/data/u") and n.endswith(".csv"))
        for i, name in enumerate(names):
            with z.open(name) as f:
                df = pd.read_csv(f, usecols=lambda c: c in USECOLS, low_memory=False)
            rows += probes_for_user(df)
            if i % 25 == 0:
                print(f"{i + 1}/{len(names)} 사용자, 프로브 누적 {len(rows)}", flush=True)
    out = pd.DataFrame(rows)
    out.to_csv(out_path, index=False)
    print(f"완료: 사용자 {out.uuid.nunique()}명, 프로브 {len(out)}개 → {out_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
