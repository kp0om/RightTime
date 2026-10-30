"""기준선 모델 비교: 다수 클래스, 규칙 기반, Logistic Regression, Random Forest (Proposal 3.2, 3.4).

사용법:
    python ml/baselines.py data/righttime-YYYYMMDD-HHMM.json --label-seconds 60
"""
import argparse

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (average_precision_score, confusion_matrix, f1_score,
                             precision_score, recall_score, roc_auc_score)
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

from features import FEATURE_COLUMNS, FEATURE_GROUPS, LABEL_SECONDS, build_table, load_prompts, time_split


def make_models():
    return {
        "logistic_regression": make_pipeline(
            SimpleImputer(strategy="median", add_indicator=True),
            StandardScaler(),
            LogisticRegression(class_weight="balanced", max_iter=1000),
        ),
        "random_forest": make_pipeline(
            SimpleImputer(strategy="median", add_indicator=True),
            RandomForestClassifier(n_estimators=300, max_depth=4, min_samples_leaf=3,
                                   class_weight="balanced", random_state=0),
        ),
    }


def rule_scores(df):
    """규칙 기반: 정지 상태이고 최근 5분 걸음이 적으면 확인할 것이라고 본다."""
    still = (df["act_now_stationary"] == 1) & (df["steps_5m"].fillna(0) < 20)
    return still.astype(float).to_numpy()


def evaluate(y_true, scores, threshold):
    y_pred = (scores >= threshold).astype(int)
    both_classes = len(np.unique(y_true)) == 2
    return {
        "n": len(y_true),
        "positive_rate": float(np.mean(y_true)) if len(y_true) else np.nan,
        "f1": f1_score(y_true, y_pred, zero_division=0),
        "precision": precision_score(y_true, y_pred, zero_division=0),
        "recall": recall_score(y_true, y_pred, zero_division=0),
        "auroc": roc_auc_score(y_true, scores) if both_classes else np.nan,
        "pr_auc": average_precision_score(y_true, scores) if both_classes else np.nan,
        "confusion": confusion_matrix(y_true, y_pred, labels=[0, 1]).tolist(),
    }


def best_threshold(y_true, scores):
    """validation에서 F1이 가장 높은 기준 θ를 고른다."""
    candidates = np.unique(np.concatenate([scores, [0.5]]))
    return max(candidates, key=lambda t: f1_score(y_true, (scores >= t).astype(int), zero_division=0))


def run(df, label, columns=FEATURE_COLUMNS):
    train, val, test = (df[df.split == s] for s in ["train", "val", "test"])
    y_train, y_val, y_test = (part[label].to_numpy() for part in (train, val, test))
    results = {}

    results["majority"] = evaluate(y_test, np.full(len(test), float(np.mean(y_train) >= 0.5)), 0.5)
    results["rule"] = evaluate(y_test, rule_scores(test), 0.5)

    if len(np.unique(y_train)) < 2:
        print(f"[경고] train에 {label} 클래스가 하나뿐이라 학습 모델은 건너뜀")
        return results

    for name, model in make_models().items():
        model.fit(train[columns], y_train)
        val_scores = model.predict_proba(val[columns])[:, 1] if len(val) else np.array([])
        threshold = best_threshold(y_val, val_scores) if len(np.unique(y_val)) == 2 else 0.5
        test_scores = model.predict_proba(test[columns])[:, 1]
        results[name] = evaluate(y_test, test_scores, threshold) | {"threshold": float(threshold)}
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("json_path")
    parser.add_argument("--label-seconds", type=int, default=60, choices=LABEL_SECONDS)
    parser.add_argument("--ablation", action="store_true", help="입력 그룹을 하나씩 빼고 다시 평가")
    args = parser.parse_args()

    prompts, wakes = load_prompts(args.json_path)
    df = time_split(build_table(prompts))
    label = f"label_{args.label_seconds}s"

    print(f"샘플 {len(df)}개, 기간 {df.date.min()} ~ {df.date.max()}, 앱 깨어남 {len(wakes)}회")
    print("결과 분포:", df.outcome.value_counts().to_dict())
    print("context 있음:", int(df.has_context.sum()), "/ 가속도 있음:", int((df.accel_count > 0).sum()))
    for t in LABEL_SECONDS:
        print(f"  T={t}s 양성 비율 {df[f'label_{t}s'].mean():.2f}")
    print("분할:", df.split.value_counts().to_dict())

    results = run(df, label)
    table = pd.DataFrame(results).T[["n", "positive_rate", "f1", "precision", "recall", "auroc", "pr_auc"]]
    print(f"\n[test, {label}]")
    print(table.round(3).to_string())

    if args.ablation:
        print(f"\n[ablation, random_forest test F1/AUROC, {label}]")
        for group, cols in FEATURE_GROUPS.items():
            kept = [c for c in FEATURE_COLUMNS if c not in cols]
            r = run(df, label, kept).get("random_forest")
            if r:
                print(f"  -{group:9s} F1 {r['f1']:.3f}  AUROC {r['auroc']:.3f}")


if __name__ == "__main__":
    main()
