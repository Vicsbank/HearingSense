# Hearing Sense 审计报告

日期：2026-10-09　环境：MacBook Pro M1 Max 32 GB，macOS 27.2，Python 3.12 venv（见 `requirements.txt`）

本报告只包含**前向推理、格式转换与评估**的结果；本次会话没有进行任何训练、反向传播或参数更新。
每条结论标注为「已验证」（有可复现的命令与输出）或「假设/未验证」。

---

## 1. 结论摘要

1. **两个旧模型都能在 Apple Silicon 上加载运行**（CPU 与 MPS 均可，所有权重键匹配）。
2. **旧模型不适合实时环境识别**：流派模型对白噪声、静音、语音都给出接近 100% 置信度的流派；情感模型的准确率与“总是猜最多的一类”基本相同。
3. **候选替代方案**（Essentia 预训练模型：Discogs-EffNet + 情绪分类头 + MusiCNN 效价/唤醒度回归头）已转换为单个 Core ML 模型，与参考实现的数值误差 ≤ 4.2×10⁻⁶，单窗口推理 22 ms（CPU+GPU，实测）。
4. **新模型在嘈杂环境下明显退化，并且对输入音量敏感**（见第 5 节）。这是目前最主要的技术问题。
5. 本地只有 12 首（全部古典）带标签的音频，**无法得出可信的多类别准确率**。需要你批准下载评估数据集（第 6 节）。

---

## 2. 现有组件盘点

| 组件 | 文件 | 状态 | 依据 |
|---|---|---|---|
| 情感模型 EfficientNet-B0 + 自定义头，9 类 GEMS | `src/emotion_model.py`, `models/emotion_efficientnet.pth` (4.34 M 参数) | 可加载、可推理 | 已验证：`load_state_dict` 全部键匹配 |
| 流派模型 CNN+GRU，GTZAN 10 类 | `src/genre_model.py`, `models/genre_crnn.pth` (0.38 M 参数) | 可加载、可推理 | 已验证 |
| 推理脚本 | `src/infer.py` | 可运行 | 已验证 |
| 训练脚本 | `src/train_emotion.py`, `src/train_genre.py` | 无法复现：本地缺 GTZAN 与 388/400 首 Emotify 音频 | 已验证（文件不存在） |
| FastAPI 网页版 | `src/app.py`, `src/templates/` | 依赖浏览器；上传文件会永久保存在 `uploads/` | 已验证（代码审查） |
| Emotify 标注 | `data/emotify/*.csv` | 曲目编号与流派映射正确（1–100 古典、101–200 摇滚、201–300 电子、301–400 流行）；`processed_data.csv` 与原始标注重新计算的差异为 1e-16 | 已验证 |
| Windows 专有依赖 | — | 代码中没有发现；路径均使用 `pathlib`，设备自动选择 cuda/mps/cpu | 已验证（代码审查） |

旧模型速度（随机输入，两个模型各一次前向，20 次平均）：CPU 287 ms，MPS 78 ms（已测得；是一次性的内联计时，没有保存成脚本）。

---

## 3. 已验证的问题

复现命令：`.venv/bin/python tools/audit_legacy.py` → `results/audit/legacy_audit.json`

**V1 旧流派模型无法拒绝非音乐。**
白噪声 → pop（概率 1.000）；近乎静音 → hiphop（1.000）；合成语音 → classical（0.924）或 pop（0.699）。模型没有“非音乐/不确定”输出，在真实房间里会持续显示错误流派。

**V2 旧流派模型训练与推理的预处理不一致。**
训练：GTZAN 30 秒切成 10 段（每段 3 秒），再随机补零到 5.5 秒（`train_genre.py` 中 `pad_trunc`）。推理：连续 5.5 秒真实音频（`infer.py`）。
两种方式对同一音频会给出不同结果，例如 Emotify classical/11：推理方式 classical 0.56，训练方式 jazz 0.58。

**V3 旧流派模型存在数据泄漏。**
`train_genre.py` 先切片再随机划分，同一首歌的片段同时出现在训练集与测试集（README 已注明）。GTZAN 本身还有重复片段、错误标注和同一艺人大量重复（Sturm 2013）。仓库中没有保存任何流派评估结果。

**V4 旧情感模型的建模方式与标签不匹配，且准确率接近基线。**
- GEMS 标注是多选（每人最多选 3 项），每首歌 9 个维度的比例之和为 1.14–2.75（平均 1.93），却被当作单标签分布用 CrossEntropy 训练，评估时取 argmax。
- 类别极不平衡：以 argmax 作为“真实类别”时，amazement 在 400 首中只有 3 首。
- 我按原脚本复现了验证集划分（`train_test_split(test_size=0.2, random_state=42)`），各类数量与 `results/emotion/confusion_matrix.png` 的行和**完全一致**，说明复现正确。
- 原混淆矩阵对角线 23/80 = **28.8%**；“总是预测 joyful_activation”的基线为 21/80 = **26.2%**。模型从不预测 amazement、tenderness、power、sadness。
- 验证时每首歌随机取一个 5 秒片段，结果不可复现；用验证集挑选最佳 epoch 后没有独立测试集，所以 28.8% 本身已偏乐观。

**V5 旧情感模型输出接近均匀分布。** 所有测试输入的 top-1 概率只有 0.15–0.38（9 类）；白噪声的 top-1 是 tension。

**V6 Emotify 中情绪与流派高度相关。** 每个流派恰好 100 首，且各流派的主情绪分布明显不同（例如 calmness 主要来自古典）。模型可能学到的是“流派”而不是“情绪”。新评估中我按流派做组内相关来控制这一点。

**V7 文档与代码互相矛盾。**
- `research_plan.docx`：流派用 EfficientNet，情感用 CRNN。
- 幻灯片：情感用 CRNN，流派用 EfficientNet，且流派只有 4 类（rock/classical/pop/electronic）。
- 代码：**情感用 EfficientNet（9 类 GEMS），流派用 CRNN（GTZAN 10 类）**。
- 幻灯片第 9 页把情感模型的 AUC 曲线标为 “Genre Recognition Model”。

**V8 依赖兼容性。** 最新 torch 2.14 未经 coremltools 9.0 测试；torchaudio ≥ 2.9 移除了旧代码使用的 `torchaudio.load` 后端。已固定为 torch/torchaudio 2.7.0。

## 4. 假设 / 未验证

- 幻灯片引用的 “Smith & Doe, 2023”、“Müller, 2022”、“Zhao et al., 2024” 我无法核实来源，其中 “Smith & Doe” 很像占位符。建议在科学展材料中替换为可查证的文献。
- Discogs-EffNet 的训练数据（Discogs-4M，未公开）可能包含 GTZAN 或其他公开数据集中的商业歌曲，若如此，在这些数据集上的评估会偏乐观。
- 分类头是在 `discogs-effnet-bs64-1`（TensorFlow）的嵌入上训练的；我使用的是同一版本的 `bsdynamic` ONNX 导出，假设权重相同（同一发布、同一版本号）。
- Essentia 情绪分类头的官方指标（例如 mood_happy 交叉验证准确率 0.87）来自 230–450 首的内部小数据集，是作者报告值，不是我测得的。

---

## 5. 候选模型与初步评估

### 5.1 选择 Essentia 模型作为首个候选的理由

| 候选 | 流派 | 情绪 | 预训练权重 | 许可 | Core ML | 备注 |
|---|---|---|---|---|---|---|
| 旧 CRNN / EfficientNet | GTZAN 10 类 | 9 类 GEMS | 有 | 自训练 | 可行 | 见第 3 节问题 |
| **Discogs-EffNet + 头 (Essentia)** | 400 种 Discogs 风格（含 Hard Rock 等） | 攻击性/快乐/放松/悲伤/派对 + MTG-Jamendo 56 个情绪主题 | 有 (ONNX) | CC BY-NC-SA 4.0（非商业可用） | **已转换并验证** | 无需训练即可得到流派与情绪 |
| MusiCNN + DEAM/emoMusic 头 | — | 效价/唤醒度（1–9） | 有 (ONNX) | CC BY-NC-SA 4.0 | **已转换并验证** | 与 EffNet 共用同一前端 |
| PANNs CNN14 / EfficientAT (AudioSet) | 粗粒度流派 | 7 个 AudioSet 情绪类（作者报告的 AP 较低） | 有 | MIT / CC BY 4.0 | 可行 | 适合做“音乐/语音/噪声”门控，尚未测试 |
| Apple SoundAnalysis 内置分类器 | 无流派 | 无 | 系统自带 | 系统 API | 原生 | 303 类，含 music / speech / silence；可做门控，尚未测试 |
| MERT-95M / CLAP | 需训练探针 / 零样本 | 需训练 | 有 | CC BY-NC 4.0 等 | 较重 | 需要训练，暂不考虑 |

### 5.2 转换验证（已验证）

`ml/export_coreml.py` → `models/coreml/HearingSenseMusic.mlpackage`（29 MB）+ `labels.json` + `export_report.json`

- Mel 前端放在 Core ML 图内，App 只需输入 16 kHz 波形；前端与 Essentia `TensorflowInputMusiCNN` 的最大误差 6.2×10⁻⁷。
- Core ML 与“NumPy 前端 + ONNX Runtime”参考管线对比：5 段真实音频，所有输出最大误差 ≤ 4.2×10⁻⁶。
- 单个 5 秒窗口延迟（中位数）：仅 CPU 59 ms，CPU+GPU 22 ms，全部计算单元 21 ms。
- 各二分类头的类别顺序不一致（如 mood_happy 为 [happy, non_happy]，mood_sad 为 [non_sad, sad]），代码从 JSON 元数据查找正类下标，不硬编码。

### 5.3 本地冒烟评估（12 首 Emotify 古典曲目，单一类别）

命令：`.venv/bin/python ml/evaluate.py --dataset emotify_local` → `results/eval/emotify_local/summary.md`

> 注意：只有一个类别，所以“准确率”只等于古典类的召回率，不能说明区分不同流派的能力；噪声为合成替代品（TTS 语音、粉红噪声）。

新模型开放集流派准确率（5 秒窗口，“App 会显示的顶层流派是否为 Classical”）：

| 条件 | 准确率 [95% CI] |
|---|---|
| 干净音频 | 0.910 [0.861, 0.951] |
| 手机外放，1 m | 0.812 [0.750, 0.875] |
| 手机外放，3 m | 0.958 [0.924, 0.986] |
| + 背景人声 10 dB | 0.569 [0.479, 0.646] |
| + 背景人声 0 dB | 0.132 [0.076, 0.188] |
| + 环境噪声 10 dB | 0.410 [0.326, 0.486] |
| + 环境噪声 0 dB | 0.056 [0.021, 0.097] |
| 极低音量 | 0.410 [0.326, 0.493] |

旧模型在退化条件下对这 12 首古典给出了更高的“准确率”，但同一模型把合成语音也判为 classical（0.924），所以这更可能是偏向而非能力。需要多类别数据才能比较。

**已观察到的失败模式（已验证）：**
- 噪声下预测漂向 Electronic（Experimental / Ambient / Field Recording）；人声干扰下漂向 Pop（Chanson）。
- **输入电平敏感**：把每个窗口归一化到不同电平，古典识别率在 −30 dBFS 时 0.97、−12 dBFS 时 0.60。模型把“安静”当作古典的线索。因此不能用纯古典数据挑选归一化电平，必须用多流派数据校准。
- 只靠 Discogs 输出无法拒绝非音乐：语音与环境噪声窗口的最高流派激活全部超过显示阈值（0.10）；只有静音被正确拒绝。**需要独立的“音乐/非音乐”门控。**

### 5.4 Emotify GEMS 相关性（12 首，仅方向检验）

干净音频下：唤醒度与 calmness ρ = −0.85 [−0.99, −0.43]，效价与 joyful_activation ρ = 0.79 [0.26, 0.99]，方向符合预期；但 sad 与 sadness 几乎不相关（ρ = −0.05），且样本太小、置信区间很宽，不能作为结论。

---

## 6. 下一步

1. 下载多类别评估数据（待你批准，见对话中的下载清单）。
2. 在多流派**校准集**上选择输入电平归一化与显示阈值，在独立**测试集**上报告结果（两者按曲目/艺人分开，避免在测试集上调参）。
3. 评估“音乐/非音乐”门控候选：Apple SoundAnalysis 内置分类器、AudioSet 模型（EfficientAT/PANNs）。
4. 如果预训练模型在噪声下仍不可接受，提出带噪声增强的分类头微调方案，并按协议提交《训练审批报告》。**在你批准之前不会训练。**
