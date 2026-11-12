"""내 iPhone 데이터 분석: 공개 데이터(MPU) 패턴과 비교, 공통 모델 적용, 개인화, 전달 정책 가상 실험.

사용: python personal_analysis.py mpu_probes.csv righttime-data.json
앱을 열 수 없던 기간(설정 초기화 후 신뢰 전, 무료 서명 만료 후)의 알림은 응답을 기록할 수 없었으므로 뺀다.
"""
import argparse

import numpy as np
import pandas as pd

from common import COMMON_COLUMNS, app_table, mpu_table
from righttime_model import best_theta, deliver_policy, fit, make_model, scores, windows

LABEL = "label_60s"
# 앱이 열리지 않던 기간 (UTC). 앱 깨어남 기록이 끊긴 구간으로 정했다.
OUTAGES = [("2026-11-01T13:00Z", "2026-11-03T06:18Z"),   # 기기 초기화 후 개발자 신뢰 전
           ("2026-11-05T11:20Z", "2100-01-01T00:00Z")]   # 무료 서명 만료 후


def valid_rows(me):
    t = me.delivered_at.dt.tz_convert("UTC")
    ok = pd.Series(True, index=me.index)
    for a, b in OUTAGES:
        ok &= ~((t >= pd.Timestamp(a)) & (t < pd.Timestamp(b)))
    return me[ok].copy()


def rate_table(df, col, bins=None, labels=None):
    x = pd.cut(df[col], bins=bins, labels=labels) if bins is not None else df[col]
    g = df.groupby(x, observed=True)[LABEL]
    return pd.DataFrame({"n": g.size(), "rate": g.mean().round(3)})


def describe(name, df):
    print(f"\n## {name}: {len(df)}개, 60초 내 확인율 {df[LABEL].mean():.3f}")
    d = df.assign(
        act=np.select([df.act_now_walking == 1, df.act_now_automotive == 1, df.act_now_stationary == 1],
                      ["이동(걷기)", "이동(차량)", "정지"], "기타/없음"),
        act_age_min=np.expm1(df.act_now_age_log) / 60,
        hour=df.delivered_at.dt.hour,
    )
    print(rate_table(d, "act").to_string())
    print(rate_table(d, "act_age_min", [0, 5, 60, 1e9], ["<5분", "5~60분", "60분+"]).to_string())
    print(rate_table(d, "act_changes_30m", [-1, 0, 2, 1e9], ["0회", "1~2회", "3회+"]).to_string())
    print(rate_table(d, "hour", [8, 12, 17, 22], ["9~12시", "12~17시", "17~22시"]).to_string())
    if d.phone_motion_avg_log.notna().sum():
        q = d.phone_motion_avg_log.quantile([0, 0.5, 1]).to_numpy()
        print("폰 움직임 (내 데이터 중앙값 기준):")
        print(rate_table(d.dropna(subset=["phone_motion_avg_log"]), "phone_motion_avg_log",
                         [q[0] - 1e-9, q[1], q[2] + 1e-9], ["낮음", "높음"]).to_string())


def leave_one_day_out(pop, me, kind, k):
    """하루씩 빼서 평가. k=None은 공통 모델만, k=0은 내 데이터만."""
    p = pd.Series(np.nan, index=me.index)
    days = me.delivered_at.dt.date
    base = fit(kind, pop, LABEL) if k is None else None
    for day in days.unique():
        test, train = me[days == day], me[days != day]
        if k is None:
            m = base
        elif k == 0:
            if train[LABEL].nunique() < 2:
                continue
            m = make_model(kind).fit(train[COMMON_COLUMNS], train[LABEL])
        else:
            m = fit(kind, pop, LABEL, train, k=k)
        p[test.index] = m.predict_proba(test[COMMON_COLUMNS])[:, 1]
    return p


def simulate_personal(me, p, seed=0):
    """θ는 평가하는 날을 뺀 나머지 날의 구간에서 고른다 (같은 날로 θ를 맞추지 않는다)."""
    rng = np.random.default_rng(seed)
    groups = windows(me.assign(p=p))
    out = {"즉시 전달": [], "무작위": [], "RightTime": [], "oracle": []}
    for i, g in enumerate(groups):
        day = g.delivered_at.dt.date.iloc[0]
        others = [h for h in groups if h.delivered_at.dt.date.iloc[0] != day]
        theta = best_theta(others, LABEL)
        y = g[LABEL].to_numpy()
        out["즉시 전달"].append(y[0])
        out["무작위"].append(y[rng.integers(len(y))])
        out["RightTime"].append(y[deliver_policy(g.p.to_numpy(), theta)])
        out["oracle"].append(y.max())
    return len(groups), {k: float(np.mean(v)) for k, v in out.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mpu_csv")
    ap.add_argument("app_json")
    args = ap.parse_args()

    pop = mpu_table(args.mpu_csv)
    me_all = app_table(args.app_json)
    me = valid_rows(me_all)
    print(f"내 데이터 {len(me_all)}개 중 앱이 정상이던 기간 {len(me)}개 사용 "
          f"({me.delivered_at.min():%m/%d}~{me.delivered_at.max():%m/%d}, {me.delivered_at.dt.date.nunique()}일)")
    tapped = me[me.response_s.notna()] if "response_s" in me else None
    if tapped is not None and len(tapped):
        print(f"탭한 알림 {len(tapped)}개, 응답 시간 중앙값 {tapped.response_s.median():.0f}초")

    describe("공개 데이터 MPU (342명)", pop)
    describe("내 데이터", me)

    print("\n## 하루씩 빼고 평가 (AUROC, 60초 내 확인)")
    preds = {}
    for name, kind, k in [("공통 모델 그대로", "gbdt", None), ("공통 모델 그대로", "logistic", None),
                          ("개인화 k=50", "logistic", 50), ("개인화 k=10", "logistic", 10),
                          ("내 데이터만", "logistic", 0)]:
        p = leave_one_day_out(pop, me, kind, k)
        ok = p.notna()
        s = scores(me[LABEL][ok].to_numpy(), p[ok].to_numpy())
        preds[(name, kind)] = p
        print(f"  {name:12s} {kind:9s} AUROC {s['auroc']:.3f}  (평가 {ok.sum()}개)")

    print("\n## 전달 정책 가상 실험 (내 데이터, 4시간 구간 = reminder 1개)")
    for key in [("공통 모델 그대로", "gbdt"), ("개인화 k=50", "logistic")]:
        p = preds[key]
        n, res = simulate_personal(me, p.fillna(p.median()))
        print(f"  [{key[0]} {key[1]}] 구간 {n}개: " + ", ".join(f"{k} {v:.3f}" for k, v in res.items()))


if __name__ == "__main__":
    main()
