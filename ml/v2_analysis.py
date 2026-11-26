"""앱 v2/v3 기록(righttime-v2.json)으로 실제 효용을 확인한다.

사용: python v2_analysis.py righttime-v2.json [personalized_logistic_v1.json]

1. 전달 방식별 60초 내 확인율: AI 판단(policy) vs 무작위(explore, probe) vs 마감(failsafe)
   무작위 전달이 같은 기간에 섞여 있으므로, AI 판단 확인율과 바로 비교할 수 있다.
2. 실시간 학습: 각 응답 직전 모델의 예측(pBeforeUpdate)으로 매긴 AUROC를 앞 절반과 뒤 절반으로 나눠 보고,
   시작 모델(학습 전) 예측과 같은 샘플에서 비교한다.
"""
import argparse
import json
import math

import numpy as np
import pandas as pd

RANDOM_KINDS = ["explore", "probe"]


def load(path):
    d = json.load(open(path, encoding="utf-8"))
    s = pd.DataFrame(d.get("samples", []))
    if s.empty:
        raise SystemExit("샘플이 없습니다")
    for c in ["deliveredAt", "respondedAt"]:
        if c in s:
            s[c] = pd.to_datetime(s[c], utc=True)
    s = s[s.label.notna()].copy()
    s["label"] = s.label.astype(int)
    s["response_s"] = (s.respondedAt - s.deliveredAt).dt.total_seconds() if "respondedAt" in s else np.nan
    return s.sort_values("deliveredAt").reset_index(drop=True)


def boot_diff(a, b, n=5000, seed=0):
    rng = np.random.default_rng(seed)
    a, b = np.asarray(a), np.asarray(b)
    diffs = [rng.choice(a, a.size).mean() - rng.choice(b, b.size).mean() for _ in range(n)]
    return np.percentile(diffs, [2.5, 97.5])


def initial_p(model, feats):
    x = np.array([[m if v is None or (isinstance(v, float) and math.isnan(v)) else v
                   for v, m in zip(row, model["impute"])] for row in feats], dtype=float)
    z = (x - np.array(model["mean"])) / np.where(np.array(model["scale"]) == 0, 1, model["scale"])
    return 1 / (1 + np.exp(-(z @ np.array(model["coef"]) + model["intercept"])))


def auc(y, p):
    """순위 기반 AUROC (동점은 평균 순위)."""
    y, p = np.asarray(y), np.asarray(p, dtype=float)
    pos, neg = (y == 1).sum(), (y == 0).sum()
    if pos == 0 or neg == 0:
        return float("nan")
    ranks = pd.Series(p).rank().to_numpy()
    return (ranks[y == 1].sum() - pos * (pos + 1) / 2) / (pos * neg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("app_json")
    ap.add_argument("initial_model", nargs="?")
    args = ap.parse_args()
    s = load(args.app_json)
    print(f"라벨 있는 전달 {len(s)}개 ({s.deliveredAt.min():%m/%d}~{s.deliveredAt.max():%m/%d})")

    print("\n## 전달 방식별 60초 내 확인율")
    g = s.groupby("kind")
    print(pd.DataFrame({"n": g.size(), "확인율": g.label.mean().round(3),
                        "응답 중앙값(초)": g.response_s.median().round(0)}).to_string())

    ai = s[s.kind == "policy"].label
    rnd = s[s.kind.isin(RANDOM_KINDS)].label
    if len(ai) and len(rnd):
        lo, hi = boot_diff(ai, rnd)
        print(f"\nAI 판단 {ai.mean():.3f} (n={len(ai)}) vs 무작위 {rnd.mean():.3f} (n={len(rnd)}): "
              f"차이 {ai.mean() - rnd.mean():+.3f}, 95% 구간 [{lo:+.3f}, {hi:+.3f}]")

    print("\n## 실시간 학습 (응답 직전 예측으로 평가)")
    learned = s[s.learned & s.pBeforeUpdate.notna()].reset_index(drop=True)
    if len(learned) >= 10:
        half = len(learned) // 2
        for name, part in [("앞 절반", learned[:half]), ("뒤 절반", learned[half:]), ("전체", learned)]:
            line = f"  {name} n={len(part)} AUROC(학습 중 모델) {auc(part.label, part.pBeforeUpdate):.3f}"
            if args.initial_model:
                m = json.load(open(args.initial_model))
                p0 = initial_p(m, part.features.tolist())
                line += f" / 시작 모델 {auc(part.label, p0):.3f}"
            print(line)
    else:
        print("  학습한 샘플이 10개 미만이라 생략")


if __name__ == "__main__":
    main()
