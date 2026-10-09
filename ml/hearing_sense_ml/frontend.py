"""Essentia `TensorflowInputMusiCNN` 的精确复现。

Discogs-EffNet 与 MusiCNN 都使用这个前端:
16 kHz 单声道, 帧长 512, 帧移 256, 对称 Hann 窗, 功率谱,
96 个 Slaney-Mel 三角滤波器 (unit_tri 归一化), 再做 log10(1 + 10000·x)。

滤波器矩阵直接从 Essentia 的 MelBands 提取 (assets/*.npy)，
tests/test_frontend.py 会在安装了 essentia 时与 Essentia 本身逐帧比对。

`MelFrontend` 用 conv1d 实现 STFT，因此可以直接放进 Core ML 图里：
App 只需送入 16 kHz 原始波形，预处理在训练、评估与部署中完全一致。
"""
import math

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

from .paths import ASSETS

SAMPLE_RATE = 16000
FRAME = 512
HOP = 256
N_MELS = 96
N_BINS = FRAME // 2 + 1


def hann_symmetric(n=FRAME):
    return 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / (n - 1))


def mel_filterbank():
    """(257, 96) float32，从 Essentia MelBands 提取"""
    return np.load(ASSETS / "essentia_melbands_16k_512_96.npy").astype(np.float32)


def num_frames(n_samples):
    return (n_samples - FRAME) // HOP + 1


def samples_for_frames(n_frames):
    return FRAME + HOP * (n_frames - 1)


def reference_melbands(x):
    """float64 NumPy 参考实现: (N,) -> (T, 96)。帧从第 0 个样本开始，不做中心补零。"""
    x = np.asarray(x, np.float64)
    t = num_frames(len(x))
    idx = np.arange(FRAME)[None, :] + HOP * np.arange(t)[:, None]
    power = np.abs(np.fft.rfft(x[idx] * hann_symmetric(), axis=1)) ** 2
    return np.log10(1 + 10000 * (power @ mel_filterbank().astype(np.float64)))


class MelFrontend(nn.Module):
    """(B, N) 16 kHz 波形 -> (B, T, 96) 对数 Mel 频带"""

    def __init__(self):
        super().__init__()
        k = np.arange(N_BINS)[:, None]
        n = np.arange(FRAME)[None, :]
        w = hann_symmetric()
        cos = np.cos(2 * np.pi * k * n / FRAME) * w
        sin = -np.sin(2 * np.pi * k * n / FRAME) * w
        kernel = np.concatenate([cos, sin])[:, None, :].astype(np.float32)  # (514, 1, 512)
        self.register_buffer("dft", torch.from_numpy(kernel))
        self.register_buffer("mel", torch.from_numpy(mel_filterbank()))

    def forward(self, wave):
        spec = F.conv1d(wave.unsqueeze(1), self.dft, stride=HOP)  # (B, 514, T)
        re, im = spec[:, :N_BINS], spec[:, N_BINS:]
        power = re * re + im * im
        mel = torch.matmul(power.transpose(1, 2), self.mel)  # (B, T, 96)
        # log10 写成 log / ln(10)，Core ML 转换更稳妥
        return torch.log(1 + 10000 * mel) * (1 / math.log(10))
