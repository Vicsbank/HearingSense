# Data

评估数据由 `tools/download_datasets.py` 下载（2026-10-09 经用户批准，约 4.2 GB）：
```bash
.venv/bin/python -I tools/download_datasets.py            # 全部
.venv/bin/python -I tools/download_datasets.py --only emotify,gtzan
```
脚本支持断点续传，核对官方校验值（没有官方值的在首次下载时记录到 `downloads/CHECKSUMS.json`），
并把每个数据集安全解压到各自的目录。压缩包保存在 `downloads/`，确认数据可用后可以删除。

所有数据只用于**非商业的研究与评估**。下表的许可信息除注明“未核实”外，均已对照来源确认。

| 目录 | 数据集 | 用途 | 许可 |
|---|---|---|---|
| `emotify/` | Emotify：400 段 1 分钟音乐（古典/摇滚/流行/电子各 100），GEMS 诱发情绪标注 | 4 类流派测试；与旧情感模型公平对比；GEMS 相关性 | 下载页未写明许可（未核实），按学术研究使用 |
| `gtzan/` | GTZAN：10 流派 × 100 段 30 秒 | 10 类流派测试 | 无明确许可，含商业录音，仅限研究 |
| `mtg_jamendo/` | MTG-Jamendo 情绪/主题子集，分片 00（约 200 首） | 多标签流派、情绪标签检验 | 元数据 CC BY-NC-SA 4.0；音频为各曲目的 CC 许可；仅限非商业研究 |
| `pmemo/` | PMEmo 2019：794 首流行歌副歌，效价/唤醒度标注 | 效价/唤醒度回归的公平测试 | 研究用途（下载后核对其许可说明） |
| `noise/librispeech/` | LibriSpeech dev-clean：40 位说话人的朗读语音 | 背景人声干扰；测试能否排除语音 | CC BY 4.0 |
| `noise/demand/` | DEMAND：餐厅、街道、客厅、车站的真实环境噪声（16 kHz，16 声道阵列，评估只用第 1 声道） | 嘈杂环境测试 | CC BY 4.0 |
| `noise/mit_rir/` | MIT IR Survey：270 个日常场所的实测房间脉冲响应 | 真实房间混响 | 未核实，按学术研究使用 |
| `test_signals/` | macOS `say` 生成的合成语音 | 没有真实语音时的替代品 | 本机生成 |
| `test_signals/window3/` | Window 3 的 20 句合成语音（`tools/make_speech_test_signals.sh` 生成，句子见 `tools/speech_test_sentences.tsv`） | 语音转写 → 摘要流水线的端到端检查（含否定句）；**合成语音，不能代表真人语音的准确率** | 本机生成，不入库 |
| `esc50/` | ESC-50：2000 段 5 秒环境声，50 类，5 折（2026-10-10 经用户批准下载，约 646 MB；压缩包在 `downloads/esc50/`） | 后台识别研究窗口的跨模型基准（`docs/research/BACKGROUND_MODEL_BENCHMARK.md`） | CC BY-NC 3.0，仅限非商业研究 |
| `samples/` | 原科学展的测试歌曲 | 无标签，只观察稳定性 | — |

## 注意事项

- **评估泄漏风险**：旧流派模型在 GTZAN 上训练过（且按片段划分，几乎每首歌都有片段进入训练集），
  所以它在 GTZAN 上的结果会偏高。Discogs-EffNet 的训练数据未公开，可能包含 GTZAN 中的商业歌曲。
- **旧情感模型**只能在它自己的验证集（Emotify 中 80 首，可用 `train_test_split(test_size=0.2, random_state=42)` 复现）上公平评估。
- **新模型的效价/唤醒度**由 DEAM 和 emoMusic 训练，不能用这两个数据集评估；PMEmo 没有参与训练。
- MTG-Jamendo 的 `mtg_jamendo_moodtheme` 分类头只能在官方 split-0 **测试集**曲目上评估。
- GTZAN 的已知问题（重复片段、错误标注、同一艺人大量重复）：Sturm, B. L. (2013), arXiv:1306.1461。

## 旧训练流程（科学展版本）

- Emotify 原始标注：`emotify/annotations.csv`（8,407 条评分）；`emotify/processed_data.csv` 每首歌一行，
  情绪分数为评分者平均值，`original_path` 相对于音频目录。重新生成：`python src/emotion_preprocess.py`。
- 旧代码 (`src/`) 仍然读取 `emotify/audio/`（原有的 12 首）与 `gtzan/genres_original/`。

## 引用

- Aljanaki, A., Wiering, F., & Veltkamp, R. C. (2016). Studying emotion induced by music through a crowdsourcing game. *Information Processing & Management, 52*(1), 115–128.
- Tzanetakis, G., & Cook, P. (2002). Musical genre classification of audio signals. *IEEE Transactions on Speech and Audio Processing, 10*(5), 293–302.
- Bogdanov, D., Won, M., Tovstogan, P., Porter, A., & Serra, X. (2019). The MTG-Jamendo dataset for automatic music tagging. *ICML Workshop on Machine Learning for Music Discovery*.
- Zhang, K., Zhang, H., Li, S., Yang, C., & Sun, L. (2018). The PMEmo dataset for music emotion recognition. *ACM ICMR*.
- Panayotov, V., Chen, G., Povey, D., & Khudanpur, S. (2015). LibriSpeech: An ASR corpus based on public domain audio books. *ICASSP*.
- Thiemann, J., Ito, N., & Vincent, E. (2013). The Diverse Environments Multi-channel Acoustic Noise Database (DEMAND). *Proceedings of Meetings on Acoustics, 19*.
- Traer, J., & McDermott, J. H. (2016). Statistics of natural reverberation enable perceptual separation of sound and space. *PNAS, 113*(48), E7856–E7865.
