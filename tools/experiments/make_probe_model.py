"""Builds ProbeTiny.mlpackage: a tiny audio classifier with RANDOM (untrained) weights.

Purpose (docs/research/BACKGROUND_INFERENCE_INVESTIGATION.md): a runtime-feasibility probe for
Core ML / SoundAnalysis while the app is in the background. Its predictions are meaningless; it
only answers "does inference execute, on which compute units, and does SNClassifySoundRequest
accept a custom model there". No training, no downloaded weights.

Usage: .venv/bin/python tools/experiments/make_probe_model.py <output.mlpackage>
"""
import sys

import coremltools as ct
import torch
from torch import nn

SAMPLES = 15_600  # 0.975 s at 16 kHz (the block size Create ML sound classifiers use)
LABELS = [f"probe_class_{i}" for i in range(8)]


class ProbeTiny(nn.Module):
    def __init__(self):
        super().__init__()
        # A fixed "filterbank" convolution, then a small 2-D stack that is large enough for
        # Core ML to consider the GPU / Neural Engine when the configuration allows them.
        self.frontend = nn.Conv1d(1, 64, 400, stride=160)
        self.net = nn.Sequential(
            nn.Conv2d(1, 64, 3, padding=1), nn.ReLU(),
            nn.Conv2d(64, 128, 3, stride=2, padding=1), nn.ReLU(),
            nn.Conv2d(128, 128, 3, padding=1), nn.ReLU(),
            nn.Conv2d(128, 128, 3, stride=2, padding=1), nn.ReLU(),
        )
        self.head = nn.Linear(128, len(LABELS))

    def forward(self, audio):  # audio: [SAMPLES]
        x = torch.relu(self.frontend(audio.reshape(1, 1, SAMPLES))).unsqueeze(1)  # [1, 1, 64, 96]
        x = self.net(x).mean(dim=(2, 3))
        return torch.softmax(self.head(x), dim=1).reshape(len(LABELS))


def main(output):
    torch.manual_seed(0)
    model = ProbeTiny().eval()
    traced = torch.jit.trace(model, torch.zeros(SAMPLES))
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audioSamples", shape=(SAMPLES,))],
        classifier_config=ct.ClassifierConfig(LABELS),
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32,
    )
    mlmodel.short_description = "Hearing Sense background-inference probe. Random weights; outputs are meaningless."
    mlmodel.save(output)
    print(mlmodel.get_spec().description)


if __name__ == "__main__":
    main(sys.argv[1])
