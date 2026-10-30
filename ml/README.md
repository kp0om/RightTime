# RightTime 학습 코드 (Colab)

| 파일 | 역할 |
|---|---|
| `features.py` | 앱 JSON → 학습 표. 시간·걸음·가속도·활동 특징, T=30/60/120초 라벨, 날짜 단위 시간순 분할 |
| `baselines.py` | 다수 클래스·규칙·Logistic Regression·Random Forest 비교, ablation |
| `mpu_extract.py` | 외부 데이터 Telefónica MPU(342명)의 ESM 알림 프로브를 같은 형식의 표로 추출 (게시→클릭 시간, 직전 활동·가속도·시간) |
| `common.py` | 외부 데이터와 앱 데이터를 같은 입력(시간·활동·폰 움직임)으로 맞춤 |
| `righttime_model.py` | 일반 모델 학습·평가, 전달 정책 가상 실험, 내 데이터 가중치 반영(개인화), 로지스틱 계수 저장 |
| `make_fake_data.py` | 코드 점검용 가짜 데이터 (실제 결과로 쓰지 않음) |
| `RightTime_baseline.ipynb` | Colab에서 위 과정을 순서대로 실행 |

**실행:** Colab에서 `RightTime_baseline.ipynb`를 열고(파일 > 노트북 열기 > GitHub 탭 > `kp0om/RightTime`), 위에서부터 실행한다. 앱에서 내보낸 JSON을 올리라는 칸이 나오면 파일을 고른다.

**라벨:** 알림을 전달 후 T초 이내에 탭했으면 1, 늦게 탭했거나 지웠거나 응답이 없으면 0.

**주의:** 수집 데이터(`data/`, `*.json`)는 공개 저장소에 올리지 않는다.

## 외부 데이터: Telefónica Mobile Phone Use (MPU)
Pielot et al., "Beyond Interruptibility", IMWUT 1(3), 2017, DOI 10.1145/3130956. 데이터: IEEE DataPort, DOI 10.15783/jh3s-h006.
MPU 앱은 1~1.5시간마다 설문 알림(ESM)을 보내고 클릭 시각을 남겼다. RightTime 수집 단계와 같은 구조라 일반 모델 학습에 쓴다.
원본과 추출 결과는 재배포하지 않는다(데이터셋 이용 조건: 출처 표기, 개인정보 보호).

## 전달 알고리즘 v0
- 수용성 모델: 외부 데이터로 학습한 일반 모델 (로지스틱 회귀 / GBDT)
- 정책: 전달 기회(앱이 깨어나는 순간)마다 p ≥ θ이면 바로 전달, 마감까지 없으면 마감 직전에 전달(fail-safe)
- 개인화: 내 데이터 n개의 전체 비중을 n / (n + k)로 둔다 (기본 k=50). n=0이면 일반 모델, n=50이면 절반, 많아질수록 내 데이터 쪽.

    python ml/mpu_extract.py mpu.zip mpu_probes.csv
    python ml/righttime_model.py mpu_probes.csv --app righttime-YYYYMMDD-HHMM.json --save model.json
