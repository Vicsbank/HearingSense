"""Candidate third-party classifiers as PyTorch modules that take a **waveform** and return
per-class scores, so the feature extraction is part of the converted Core ML model.

Forward-only: every module is built in eval mode from published pretrained weights. Nothing
here trains, fine-tunes or updates parameters.

- YAMNet (Google, AudioSet, 521 classes, 16 kHz): MobileNet-v1 re-implemented here and loaded
  from the official Keras weights (yamnet.h5). Verified against Google's official TFLite model
  in verify_parity.py.
- EfficientAT mn10_as / dymn04_as (Schmid et al., AudioSet, 527 classes, 32 kHz): the official
  model code and checkpoints; only the mel front end is re-expressed with a convolution so that
  it converts to Core ML. Verified against the repository's own AugmentMelSTFT.

The STFT is a strided 1-D convolution whose kernels are window × DFT basis; this is numerically
the same transform as torch.stft / tf.signal.stft and converts to Core ML without custom layers.
"""
import contextlib
import csv
import math
import os
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

ROOT = Path(__file__).resolve().parents[3]
THIRD_PARTY = ROOT / "models" / "third_party"
YAMNET_DIR = THIRD_PARTY / "yamnet"
EFFICIENTAT_REPO = THIRD_PARTY / "efficientat" / "repo"
EFFICIENTAT_WEIGHTS = {
    "mn10_as": THIRD_PARTY / "efficientat" / "weights" / "mn10_as_mAP_471.pt",
    "dymn04_as": THIRD_PARTY / "efficientat" / "weights" / "dymn04_as.pt",
}


class ConvSTFT(nn.Module):
    """|STFT|² (or |STFT|) of a [B, T] waveform as a convolution. Output: [B, n_fft/2+1, frames]."""

    def __init__(self, n_fft, window, hop, power):
        super().__init__()
        length = window.numel()  # the window may be shorter than n_fft (zero-padded transform)
        n = torch.arange(length, dtype=torch.float64)
        k = torch.arange(n_fft // 2 + 1, dtype=torch.float64).unsqueeze(1)
        angle = 2 * math.pi * k * n / n_fft
        window = window.to(torch.float64)
        kernels = torch.cat([torch.cos(angle) * window, -torch.sin(angle) * window]).unsqueeze(1)
        self.register_buffer("kernels", kernels.to(torch.float32))
        self.hop = hop
        self.bins = n_fft // 2 + 1
        self.power = power

    def forward(self, x):
        y = F.conv1d(x.unsqueeze(1), self.kernels, stride=self.hop)
        energy = y[:, : self.bins] ** 2 + y[:, self.bins:] ** 2
        return energy if self.power == 2 else torch.sqrt(energy)


# ---------------------------------------------------------------------------------- YAMNet

YAMNET_SAMPLE_RATE = 16_000
YAMNET_PATCH_SAMPLES = 15_600  # 96 frames: 400 + 95 * 160 samples = 0.975 s
YAMNET_PATCH_HOP_SAMPLES = 7_680  # 48 frames = 0.48 s
_YAMNET_LAYERS = [  # (kind, stride, filters) from the official yamnet.py
    ("conv", 2, 32), ("sep", 1, 64), ("sep", 2, 128), ("sep", 1, 128), ("sep", 2, 256), ("sep", 1, 256),
    ("sep", 2, 512), ("sep", 1, 512), ("sep", 1, 512), ("sep", 1, 512), ("sep", 1, 512), ("sep", 1, 512),
    ("sep", 2, 1024), ("sep", 1, 1024),
]


def _htk_mel(hz):
    return 1127.0 * np.log1p(np.asarray(hz, dtype=np.float64) / 700.0)


def yamnet_mel_matrix(bands=64, bins=257, sample_rate=16_000, low=125.0, high=7_500.0):
    """tf.signal.linear_to_mel_weight_matrix: HTK mel scale, triangles in the mel domain, the DC
    bin excluded, no area normalization. Returns [bands, bins]."""
    linear = np.linspace(0.0, sample_rate / 2, bins)[1:]
    spectrogram_mel = _htk_mel(linear)[:, None]
    edges = np.linspace(_htk_mel(low), _htk_mel(high), bands + 2)
    lower, center, upper = edges[:-2][None], edges[1:-1][None], edges[2:][None]
    weights = np.maximum(0.0, np.minimum((spectrogram_mel - lower) / (center - lower),
                                         (upper - spectrogram_mel) / (upper - center)))
    return np.pad(weights, [[1, 0], [0, 0]]).T.astype(np.float32)


class _SamePadConv(nn.Module):
    """3×3 convolution + batch norm (no scale, eps 1e-4) + ReLU with TensorFlow 'same' padding
    (for stride 2 on even sizes TensorFlow pads only after the data)."""

    def __init__(self, inputs, outputs, kernel, stride, depthwise):
        super().__init__()
        self.pad = (0, 0, 0, 0) if kernel == 1 else ((1, 1, 1, 1) if stride == 1 else (0, 1, 0, 1))
        self.conv = nn.Conv2d(inputs, outputs, kernel, stride, bias=False, groups=inputs if depthwise else 1)
        self.bn = nn.BatchNorm2d(outputs, eps=1e-4, affine=True)

    def forward(self, x):
        return F.relu(self.bn(self.conv(F.pad(x, self.pad))))


class YAMNet(nn.Module):
    """Waveform patch [B, 15600] at 16 kHz → sigmoid scores [B, 521]."""

    def __init__(self):
        super().__init__()
        hann = 0.5 - 0.5 * torch.cos(2 * math.pi * torch.arange(400, dtype=torch.float64) / 400)  # periodic
        self.stft = ConvSTFT(n_fft=512, window=hann, hop=160, power=1)
        self.register_buffer("mel", torch.from_numpy(yamnet_mel_matrix()))
        layers, names, channels = [], [], 1
        for index, (kind, stride, filters) in enumerate(_YAMNET_LAYERS, start=1):
            if kind == "conv":
                layers.append(_SamePadConv(channels, filters, 3, stride, depthwise=False))
                names.append(f"layer{index}/conv")
            else:
                layers.append(_SamePadConv(channels, channels, 3, stride, depthwise=True))
                names.append(f"layer{index}/depthwise_conv")
                layers.append(_SamePadConv(channels, filters, 1, 1, depthwise=False))
                names.append(f"layer{index}/pointwise_conv")
            channels = filters
        self.layers = nn.Sequential(*layers)
        self.layer_names = names
        self.logits = nn.Linear(1024, 521)

    def features(self, waveform):
        mel = torch.matmul(self.mel, self.stft(waveform))  # [B, 64, 96]
        return torch.log(mel + 0.001).transpose(1, 2).unsqueeze(1)  # [B, 1, time 96, mel 64]

    def forward(self, waveform):
        x = self.layers(self.features(waveform)).mean(dim=(2, 3))
        return torch.sigmoid(self.logits(x))

    def load_keras_weights(self, path):
        import h5py

        with h5py.File(path, "r") as file, torch.no_grad():
            for name, layer in zip(self.layer_names, self.layers):
                group = file[name]
                kernel_name = [key for key in group[name] if "kernel" in key][0]
                kernel = torch.from_numpy(np.array(group[name][kernel_name]))
                if "depthwise" in kernel_name:
                    kernel = kernel.permute(2, 3, 0, 1)  # [h, w, channels, 1] → [channels, 1, h, w]
                else:
                    kernel = kernel.permute(3, 2, 0, 1)  # [h, w, in, out] → [out, in, h, w]
                assert layer.conv.weight.shape == kernel.shape, (name, layer.conv.weight.shape, kernel.shape)
                layer.conv.weight.copy_(kernel)
                bn = group["bn"][f"{name}/bn"]
                layer.bn.bias.copy_(torch.from_numpy(np.array(bn["beta:0"])))
                layer.bn.running_mean.copy_(torch.from_numpy(np.array(bn["moving_mean:0"])))
                layer.bn.running_var.copy_(torch.from_numpy(np.array(bn["moving_variance:0"])))
                layer.bn.weight.fill_(1.0)  # Keras layer has scale=False
            dense = file["logits"]["logits"]
            self.logits.weight.copy_(torch.from_numpy(np.array(dense["kernel:0"])).T)
            self.logits.bias.copy_(torch.from_numpy(np.array(dense["bias:0"])))
        return self


def load_yamnet():
    return YAMNet().load_keras_weights(YAMNET_DIR / "yamnet.h5").eval()


def yamnet_labels():
    with open(YAMNET_DIR / "yamnet_class_map.csv") as file:
        return [row["display_name"] for row in csv.DictReader(file)]


def yamnet_patches(waveform):
    """Splits a 1-D 16 kHz waveform into the model's 0.975 s patches with a 0.48 s hop. Audio
    shorter than one patch is zero-padded at the end; a trailing partial patch is dropped, as in
    the reference implementation."""
    waveform = np.asarray(waveform, dtype=np.float32)
    if len(waveform) < YAMNET_PATCH_SAMPLES:
        waveform = np.pad(waveform, (0, YAMNET_PATCH_SAMPLES - len(waveform)))
    count = 1 + (len(waveform) - YAMNET_PATCH_SAMPLES) // YAMNET_PATCH_HOP_SAMPLES
    return np.stack([waveform[i * YAMNET_PATCH_HOP_SAMPLES: i * YAMNET_PATCH_HOP_SAMPLES + YAMNET_PATCH_SAMPLES]
                     for i in range(count)])


# ------------------------------------------------------------------------------ EfficientAT

EFFICIENTAT_SAMPLE_RATE = 32_000


@contextlib.contextmanager
def _efficientat_imports():
    """The repository reads `metadata/…` relative to the working directory at import time."""
    previous = os.getcwd()
    os.chdir(EFFICIENTAT_REPO)
    sys.path.insert(0, str(EFFICIENTAT_REPO))
    try:
        yield
    finally:
        sys.path.remove(str(EFFICIENTAT_REPO))
        os.chdir(previous)


def efficientat_labels():
    with open(EFFICIENTAT_REPO / "metadata" / "class_labels_indices.csv") as file:
        return [row["display_name"] for row in csv.DictReader(file)]


def load_efficientat_backbone(name):
    """The official architecture with the official checkpoint (spectrogram in, logits out)."""
    with _efficientat_imports():
        from helpers.utils import NAME_TO_WIDTH
        if name.startswith("dymn"):
            from models.dymn.model import get_model
        else:
            from models.mn.model import get_model
        with contextlib.redirect_stdout(None):  # the repository prints the whole architecture
            model = get_model(width_mult=NAME_TO_WIDTH(name), pretrained_name=None)
    state = torch.load(EFFICIENTAT_WEIGHTS[name], map_location="cpu", weights_only=True)
    model.load_state_dict(state)
    return model.eval()


def load_efficientat_reference_frontend():
    """The repository's own mel front end (torch.stft based), in eval mode: no augmentation."""
    with _efficientat_imports():
        from models.preprocess import AugmentMelSTFT
        with contextlib.redirect_stdout(None):
            return AugmentMelSTFT(n_mels=128, sr=32_000, win_length=800, hopsize=320).eval()


class EfficientAT(nn.Module):
    """Waveform [B, T] at 32 kHz → sigmoid scores [B, 527]. Same computation as
    AugmentMelSTFT(eval) followed by the backbone, with the STFT as a convolution."""

    def __init__(self, backbone):
        super().__init__()
        import torchaudio

        window = F.pad(torch.hann_window(800, periodic=False, dtype=torch.float64), (112, 112))  # centred in n_fft
        self.stft = ConvSTFT(n_fft=1024, window=window, hop=320, power=2)
        mel, _ = torchaudio.compliance.kaldi.get_mel_banks(128, 1024, 32_000, 0.0, 15_000.0, vtln_low=100.0,
                                                          vtln_high=-500.0, vtln_warp_factor=1.0)
        self.register_buffer("mel", F.pad(mel, (0, 1)))
        self.backbone = backbone

    def features(self, waveform):
        x = waveform[:, 1:] - 0.97 * waveform[:, :-1]  # pre-emphasis
        x = F.pad(x.unsqueeze(1), (512, 512), mode="reflect").squeeze(1)  # torch.stft(center=True)
        mel = torch.matmul(self.mel, self.stft(x))
        return (torch.log(mel + 0.00001) + 4.5) / 5.0  # [B, 128, frames]

    def forward(self, waveform):
        logits, _ = self.backbone(self.features(waveform).unsqueeze(1))
        return torch.sigmoid(logits)


def load_efficientat(name):
    return EfficientAT(load_efficientat_backbone(name)).eval()


def batch_one_copy(module):
    """A copy for Core ML conversion in which DyMN's dynamic convolutions are written for a
    batch of one. The original folds the batch into the channel dimension with sizes computed at
    run time, which the converter cannot trace; for one sample the computation is the same
    (kernel = attention-weighted sum of the K kernels, then an ordinary convolution). The
    converted model is compared with the unmodified module in convert_coreml.py."""
    import copy
    import types

    def forward(self, x, g=None):
        assert self.att_groups == 1 and self.bias is None
        residuals = self.residuals(g[0].reshape(1, -1)).reshape(1, 1, 1, self.k)
        attention = F.softmax(residuals / self.temperature, dim=-1)
        weight = (attention @ self.weight).reshape(self.out_channels, self.in_channels // self.groups,
                                                  self.kernel_size, self.kernel_size)
        return F.conv2d(x, weight, None, self.stride, self.padding, self.dilation, self.groups)

    clone = copy.deepcopy(module)
    for child in clone.modules():
        if type(child).__name__ == "DynamicConv":
            child.forward = types.MethodType(forward, child)
    return clone


def parameter_count(module):
    return sum(parameter.numel() for parameter in module.parameters())
