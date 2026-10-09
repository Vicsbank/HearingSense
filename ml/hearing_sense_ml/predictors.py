"""评估用的预测器封装（只做前向推理）。

- CoreMLMusicModel: 直接运行导出的 HearingSenseMusic.mlpackage，评估的就是将来部署的模型。
- LegacyGenre / LegacyEmotion: 科学展版本的两个旧模型，预处理与 src/infer.py 完全一致，作为基线。
"""
import json
import sys

import librosa
import numpy as np
import torch

from .paths import COREML_OUT, ROOT


class CoreMLMusicModel:
    sample_rate = 16000

    def __init__(self, compute_units="CPU_AND_GPU"):
        import coremltools as ct
        self.labels = json.loads((COREML_OUT / "labels.json").read_text())
        self.window = self.labels["window_samples"]
        self.model = ct.models.MLModel(str(COREML_OUT / "HearingSenseMusic.mlpackage"),
                                       compute_units=getattr(ct.ComputeUnit, compute_units))

    def predict_windows(self, y16, hop=None):
        """对 16 kHz 音频按窗口预测；返回 {输出名: (窗口数, 维度)}"""
        hop = hop or self.window
        out = {k: [] for k in self.labels["outputs"]}
        for s in range(0, len(y16) - self.window + 1, hop):
            r = self.model.predict({"waveform": y16[None, s:s + self.window].astype(np.float32)})
            for k in out:
                out[k].append(np.asarray(r[k], np.float32).reshape(-1))
        return {k: np.stack(v) if v else np.zeros((0, 0), np.float32) for k, v in out.items()}


def _legacy_imports():
    sys.path.insert(0, str(ROOT / "src"))
    import config  # noqa: F401
    return config


class LegacyGenre:
    sample_rate = 44100

    def __init__(self):
        config = _legacy_imports()
        from genre_model import SpectrogramCNN_GRUNet, genre_melspec
        self.classes = config.GENRE_COL
        self.melspec = genre_melspec
        self.model = SpectrogramCNN_GRUNet(len(self.classes))
        self.model.load_state_dict(torch.load(config.model_path_genre, map_location="cpu"))
        self.model.eval()
        self.window = 44100 // 1000 * 5500  # 与 train_genre.pad_trunc 一致

    def predict_windows(self, y44):
        segs = [y44[s:s + self.window] for s in range(0, len(y44) - self.window + 1, self.window)]
        if not segs:
            return np.zeros((0, len(self.classes)), np.float32)
        with torch.no_grad():
            x = torch.stack([self.melspec(torch.tensor(s).float().unsqueeze(0)) for s in segs])
            return torch.softmax(self.model(x), 1).numpy()


class LegacyEmotion:
    sample_rate = 44100

    def __init__(self):
        config = _legacy_imports()
        from emotion_model import EfficientNetModel
        self.classes = [c.strip() for c in config.LABEL_COL]
        self.model = EfficientNetModel(pretrained=False)
        self.model.load_state_dict(torch.load(config.model_path_emo, map_location="cpu"))
        self.model.eval()
        self.window = 5 * 44100

    def predict_logits(self, y44):
        segs = [y44[s:s + self.window] for s in range(0, len(y44) - self.window + 1, self.window)]
        if not segs:
            return np.zeros((0, len(self.classes)), np.float32)
        mels = [librosa.power_to_db(librosa.feature.melspectrogram(y=s, sr=44100, n_mels=128, n_fft=2048,
                                                                   hop_length=512), ref=np.max) for s in segs]
        with torch.no_grad():
            return self.model(torch.tensor(np.array(mels)).float().unsqueeze(1)).numpy()
