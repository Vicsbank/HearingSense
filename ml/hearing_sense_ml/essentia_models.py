"""Essentia 预训练模型 (MTG, CC BY-NC-SA 4.0) 的 PyTorch 封装。

ONNX 文件由 tools/download_pretrained.py 下载，这里用 onnx2torch 转成 PyTorch 模块，
再组合成一个端到端的 `MusicAnalyzer`：16 kHz 波形 -> 风格 / 情绪 / 效价-唤醒度。

注意：各个二分类头的类别顺序并不一致（例如 mood_happy 是 [happy, non_happy]，
mood_sad 是 [non_sad, sad]），所以正类下标一律从各自的 JSON 元数据里查，绝不硬编码。
"""
import json
import math

import torch
import torch.nn as nn
from onnx2torch import convert

from .frontend import MelFrontend, num_frames, samples_for_frames, SAMPLE_RATE
from .paths import ESSENTIA_MODELS

EFFNET = "discogs-effnet-bsdynamic-1"
MUSICNN = "msd-musicnn-1"
EFFNET_PATCH, EFFNET_HOP = 128, 62    # Essentia TensorflowPredictEffnetDiscogs 默认值
MUSICNN_PATCH, MUSICNN_HOP = 187, 93  # Essentia TensorflowPredictMusiCNN 默认值

# 输出名 -> (ONNX 模型, 正类名称)
BINARY_HEADS = {
    "aggressive": ("mood_aggressive-discogs-effnet-1", "aggressive"),
    "happy": ("mood_happy-discogs-effnet-1", "happy"),
    "party": ("mood_party-discogs-effnet-1", "party"),
    "relaxed": ("mood_relaxed-discogs-effnet-1", "relaxed"),
    "sad": ("mood_sad-discogs-effnet-1", "sad"),
    "danceable": ("danceability-discogs-effnet-1", "danceable"),
    "voice": ("voice_instrumental-discogs-effnet-1", "voice"),
}
MOODTHEME = "mtg_jamendo_moodtheme-discogs-effnet-1"
AV_HEADS = ["deam-msd-musicnn-2", "emomusic-msd-musicnn-2"]  # 输出顺序均为 (valence, arousal)，取值 1–9


def metadata(name):
    return json.loads((ESSENTIA_MODELS / f"{name}.json").read_text())


def load_onnx(name):
    path = ESSENTIA_MODELS / f"{name}.onnx"
    if not path.exists():
        raise FileNotFoundError(f"{path} 不存在，请先运行 tools/download_pretrained.py")
    return convert(str(path)).eval()


def patch_starts(n_frames, patch, hop):
    """在窗口内均匀放置补丁，首尾对齐窗口边界；补丁间距不超过 Essentia 的默认帧移"""
    if n_frames < patch:
        raise ValueError(f"窗口只有 {n_frames} 帧，少于补丁长度 {patch}")
    count = math.ceil((n_frames - patch) / hop) + 1
    if count == 1:
        return [0]
    return [round(i * (n_frames - patch) / (count - 1)) for i in range(count)]


def window_samples(seconds):
    """把秒数换成恰好对齐整数帧的样本数"""
    return samples_for_frames(num_frames(int(round(seconds * SAMPLE_RATE))))


class MusicAnalyzer(nn.Module):
    """(1, N) 16 kHz 波形 -> 各项输出（窗口内所有补丁的平均值）

    styles          (400,)  Discogs 风格激活 (sigmoid，多标签)
    moods           (7,)    BINARY_HEADS 中各正类的概率，顺序与 MOOD_OUTPUTS 一致
    moodtheme       (56,)   MTG-Jamendo 情绪/主题标签 (sigmoid)
    valence_arousal (2,)    DEAM 与 emoMusic 两个回归头的平均，取值约 1–9
    embedding       (1280,) Discogs-EffNet 嵌入，供以后训练新的分类头
    """

    MOOD_OUTPUTS = list(BINARY_HEADS)

    def __init__(self, n_samples):
        super().__init__()
        self.n_samples = n_samples
        frames = num_frames(n_samples)
        self.effnet_starts = patch_starts(frames, EFFNET_PATCH, EFFNET_HOP)
        self.musicnn_starts = patch_starts(frames, MUSICNN_PATCH, MUSICNN_HOP)
        self.frontend = MelFrontend()
        self.effnet = load_onnx(EFFNET)
        self.musicnn = load_onnx(MUSICNN)
        self.heads = nn.ModuleList(load_onnx(m) for m, _ in BINARY_HEADS.values())
        self.head_pos = [metadata(m)["classes"].index(pos) for m, pos in BINARY_HEADS.values()]
        self.moodtheme = load_onnx(MOODTHEME)
        self.av_heads = nn.ModuleList(load_onnx(m) for m in AV_HEADS)
        for m in AV_HEADS:
            assert metadata(m)["classes"] == ["valence", "arousal"], m

    def forward(self, wave):
        mel = self.frontend(wave)[0]  # (T, 96)
        eff_in = torch.stack([mel[s:s + EFFNET_PATCH] for s in self.effnet_starts])
        styles, emb = self.effnet(eff_in)
        moods = torch.stack([h(emb)[:, p] for h, p in zip(self.heads, self.head_pos)], dim=1)
        moodtheme = self.moodtheme(emb)
        mus_in = torch.stack([mel[s:s + MUSICNN_PATCH] for s in self.musicnn_starts])
        _, mus_emb = self.musicnn(mus_in)
        va = sum(h(mus_emb) for h in self.av_heads) / len(self.av_heads)
        return (styles.mean(0), moods.mean(0), moodtheme.mean(0), va.mean(0), emb.mean(0))


OUTPUT_NAMES = ["styles", "moods", "moodtheme", "valence_arousal", "embedding"]


def style_classes():
    return metadata(EFFNET)["classes"]


def moodtheme_classes():
    return metadata(MOODTHEME)["classes"]
