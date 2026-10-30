"""RightTime 수용성 모델과 전달 정책 v0.

1) 외부 데이터(MPU 342명)로 일반 모델을 학습하고, 처음 보는 사용자로 평가한다.
2) 내 데이터가 있으면 더 큰 가중치로 함께 학습한다(개인화).
   내 데이터 한 개의 가중치는 '내 데이터가 전체 가중치에서 차지할 몫'이 n / (n + k)가 되도록 정한다.
   n=0이면 일반 모델 그대로, n=k이면 절반, n이 커질수록 내 데이터 쪽으로 기운다.
3) 전달 정책을 가상 실험으로 무작위 전달·즉시 전달과 비교한다.

    python ml/righttime_model.py mpu_probes.csv [--app righttime.json] [--label-seconds 60]
"""
import argparse
import json

import numpy as np
import pandas as pd
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, roc_auc_score
from sklearn.model_selection import GroupShuffleSplit
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

from common import COMMON_COLUMNS, app_table, mpu_table

PERSONAL_K = 50  # 내 데이터가 이 개수만큼 쌓이면 일반 데이터와 같은 비중


def make_model(kind):
    if kind == "logistic":
        return make_pipeline(SimpleImputer(strategy="median"), StandardScaler(),
                             LogisticRegression(max_iter=2000, C=0.5))
    return make_pipeline(SimpleImputer(strategy="median"),
                         GradientBoostingClassifier(n_estimators=150, max_depth=3, learning_rate=0.1,
                                                    subsample=0.8, random_state=0))


def personal_weights(n_pop, n_me, k=PERSONAL_K):
    """일반 데이터 각 1, 내 데이터 각 w. 내 데이터의 전체 비중이 n_me / (n_me + k)가 되게 한다."""
    if n_me == 0:
        return 0.0
    share = n_me / (n_me + k)
    return share / (1 - share) * n_pop / n_me


def fit(kind, pop, label, me=None, k=PERSONAL_K):
    X, y = pop[COMMON_COLUMNS], pop[label]
    w = np.ones(len(pop))
    if me is not None and len(me):
        w_me = personal_weights(len(pop), len(me), k)
        X = pd.concat([X, me[COMMON_COLUMNS]])
        y = pd.concat([y, me[label]])
        w = np.concatenate([w, np.full(len(me), w_me)])
    model = make_model(kind)
    model.fit(X, y, **{f"{model.steps[-1][0]}__sample_weight": w})
    return model


def scores(y, p):
    both = len(np.unique(y)) == 2
    return {"n": len(y), "pos_rate": float(np.mean(y)),
            "auroc": roc_auc_score(y, p) if both else np.nan,
            "pr_auc": average_precision_score(y, p) if both else np.nan}


# ---------- 전달 정책 ----------

def deliver_policy(p_list, theta):
    """기회가 올 때마다 p ≥ θ이면 그때 전달, 끝까지 없으면 마지막 기회(마감 직전)에 전달."""
    for i, p in enumerate(p_list):
        if p >= theta:
            return i
    return len(p_list) - 1


def simulate(df, p, label, window_hours=4, theta=None, seed=0):
    """사용자·날짜별 window_hours 구간을 reminder 하나로 보고, 구간 안의 알림 시점들을 전달 기회로 본다.
    각 정책이 고른 시점의 실제 결과(T초 내 확인)를 평균한다."""
    rng = np.random.default_rng(seed)
    groups = windows(df.assign(p=p), window_hours)
    if theta is None:
        theta = best_theta(groups, label)
    out = {"immediate": [], "random": [], "model_best_of_window": [], "policy": [], "oracle": []}
    waits = []
    for g in groups:
        y = g[label].to_numpy()
        out["immediate"].append(y[0])
        out["random"].append(y[rng.integers(len(y))])
        out["model_best_of_window"].append(y[int(np.argmax(g.p.to_numpy()))])  # 미래를 아는 상한 (참고)
        i = deliver_policy(g.p.to_numpy(), theta)
        out["policy"].append(y[i])
        waits.append(i)
        out["oracle"].append(y.max())
    result = {k: float(np.mean(v)) for k, v in out.items()}
    result.update({"windows": len(groups), "theta": float(theta), "mean_wait_steps": float(np.mean(waits))})
    return result


def windows(df, window_hours=4):
    d = df.assign(block=df.delivered_at.dt.floor(f"{window_hours}h")).sort_values("delivered_at")
    return [g for _, g in d.groupby(["group", "block"]) if len(g) >= 2]


def theta_for(model, df, label):
    """train 사용자에서 정책 확인율이 가장 높은 θ를 고른다."""
    p = model.predict_proba(df[COMMON_COLUMNS])[:, 1]
    return best_theta(windows(df.assign(p=p)), label)


def best_theta(groups, label):
    candidates = np.quantile(np.concatenate([g.p.to_numpy() for g in groups]), np.linspace(0.3, 0.95, 27))
    def value(theta):
        return np.mean([g[label].to_numpy()[deliver_policy(g.p.to_numpy(), theta)] for g in groups])
    return max(candidates, key=value)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mpu_csv")
    ap.add_argument("--app", help="RightTime 앱에서 내보낸 JSON (있으면 개인화)")
    ap.add_argument("--label-seconds", type=int, default=60)
    ap.add_argument("--save", help="최종 모델 계수를 JSON으로 저장 (logistic)")
    args = ap.parse_args()
    label = f"label_{args.label_seconds}s"

    pop = mpu_table(args.mpu_csv)
    tr_idx, te_idx = next(GroupShuffleSplit(test_size=0.3, random_state=0).split(pop, groups=pop.group))
    train, test = pop.iloc[tr_idx], pop.iloc[te_idx]
    print(f"외부 데이터: train {train.group.nunique()}명 {len(train)}개 / test {test.group.nunique()}명 {len(test)}개, "
          f"{label} 양성 {test[label].mean():.3f}")

    print("\n[1] 일반 모델, 처음 보는 사용자 평가")
    models = {}
    for kind in ["logistic", "gbdt"]:
        models[kind] = fit(kind, train, label)
        s = scores(test[label].to_numpy(), models[kind].predict_proba(test[COMMON_COLUMNS])[:, 1])
        print(f"  {kind:9s} AUROC {s['auroc']:.3f}  PR-AUC {s['pr_auc']:.3f}")

    print("\n[2] 전달 정책 가상 실험 (4시간 구간 = reminder 1개, 구간 안 알림 시점 = 전달 기회)")
    thetas = {}
    for kind, model in models.items():
        thetas[kind] = theta_for(model, train, label)
        sim = simulate(test, model.predict_proba(test[COMMON_COLUMNS])[:, 1], label, theta=thetas[kind])
        print(f"  [{kind}] 구간 {sim['windows']}개, θ={sim['theta']:.3f}, 평균 대기 {sim['mean_wait_steps']:.2f}회")
        for k in ["immediate", "random", "policy", "model_best_of_window", "oracle"]:
            print(f"    {k:22s} {label} 확인율 {sim[k]:.3f}")

    if args.app:
        me = app_table(args.app)
        print(f"\n[3] 개인화: 내 데이터 {len(me)}개")
        if len(me) >= 10:
            me = me.sort_values("delivered_at")
            cut = int(len(me) * 0.7)
            me_train, me_test = me.iloc[:cut], me.iloc[cut:]
            for k in [None, 10, PERSONAL_K, 200]:
                m = fit("gbdt", pop, label) if k is None else fit("gbdt", pop, label, me_train, k)
                s = scores(me_test[label].to_numpy(), m.predict_proba(me_test[COMMON_COLUMNS])[:, 1])
                share = 0 if k is None else len(me_train) / (len(me_train) + k)
                print(f"  내 데이터 비중 {share:.2f} (k={k}) → 내 test AUROC {s['auroc']:.3f}  양성 {s['pos_rate']:.2f}")
        else:
            print("  내 데이터가 10개 미만이라 평가는 건너뜀")

    if args.save:
        final = fit("logistic", pop, label, app_table(args.app) if args.app else None)
        imputer, scaler, lr = final.steps[0][1], final.steps[1][1], final.steps[2][1]
        json.dump({
            "features": COMMON_COLUMNS, "label": label,
            "impute": imputer.statistics_.tolist(), "mean": scaler.mean_.tolist(), "scale": scaler.scale_.tolist(),
            "coef": lr.coef_[0].tolist(), "intercept": float(lr.intercept_[0]),
            "theta": float(theta_for(final, pop, label)),
        }, open(args.save, "w"), ensure_ascii=False, indent=1)
        print(f"\n로지스틱 모델 계수 저장 → {args.save}")


if __name__ == "__main__":
    main()
