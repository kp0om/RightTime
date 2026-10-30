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


def activity_features(starts, states, t):
    """상태가 바뀐 시각 목록으로 현재 상태, 지속 시간, 직전 30분 상태 비율과 변화 횟수를 만든다."""
    feats = {"act_now": states[-1], "act_now_age_s": (t - starts[-1]).total_seconds()}
    window_start = t - WINDOW
    frac = dict.fromkeys(STATES, 0.0)
    ends = starts[1:] + [t]
    for state, a, b in zip(states, starts, ends):
        overlap = min(b, t) - max(a, window_start)
        if overlap > pd.Timedelta(0):
            frac[state] += overlap / WINDOW
    feats.update({f"act_frac_{s}": v for s, v in frac.items()})
    feats["act_changes_30m"] = sum(1 for a in starts if a >= window_start)
    return feats


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
    # iPhone(Core Motion)과 맞추기 위해 같은 상태가 이어지는 기록은 하나로 합친다 (still↔tilting 등)
    act = act[act.state != act.state.shift()]
    act_ts = pd.DatetimeIndex(act.ts)
    act_states = act.state.to_numpy()
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
        # 직전 30분 안에서 바뀐 기록 + 그 직전 상태 하나만 본다 (전체 이력을 매번 보면 느림)
        end = act_ts.searchsorted(t, side="right")
        begin = max(act_ts.searchsorted(t - WINDOW, side="left") - 1, 0)
        if end > 0:
            row.update(activity_features(list(act_ts[begin:end]), list(act_states[begin:end]), t))
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
