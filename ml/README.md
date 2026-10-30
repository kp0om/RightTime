# RightTime 학습 코드 (Colab)

| 파일 | 역할 |
|---|---|
| `features.py` | 앱 JSON → 학습 표. 시간·걸음·가속도·활동 특징, T=30/60/120초 라벨, 날짜 단위 시간순 분할 |
| `baselines.py` | 다수 클래스·규칙·Logistic Regression·Random Forest 비교, ablation |
| `make_fake_data.py` | 코드 점검용 가짜 데이터 (실제 결과로 쓰지 않음) |
| `RightTime_baseline.ipynb` | Colab에서 위 과정을 순서대로 실행 |

**실행:** Colab에서 `RightTime_baseline.ipynb`를 열고(파일 > 노트북 열기 > GitHub 탭 > `kp0om/RightTime`), 위에서부터 실행한다. 앱에서 내보낸 JSON을 올리라는 칸이 나오면 파일을 고른다.

**라벨:** 알림을 전달 후 T초 이내에 탭했으면 1, 늦게 탭했거나 지웠거나 응답이 없으면 0.

**주의:** 수집 데이터(`data/`, `*.json`)는 공개 저장소에 올리지 않는다.
