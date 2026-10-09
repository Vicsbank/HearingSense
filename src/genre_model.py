import torch
import torch.nn as nn
from torchaudio import transforms

GENRE_SR = 44100
GENRE_SEGMENT_MS = 5500  # 每段 5.5 秒


def genre_melspec(sig, sr=GENRE_SR):
    """单声道波形 (1, samples) -> Mel 频谱 (1, 64, frames)，训练和推理共用"""
    spec = transforms.MelSpectrogram(sr, n_fft=1024, hop_length=None, n_mels=64)(sig)
    spec = transforms.AmplitudeToDB(top_db=80)(spec)
    return spec


class SpectrogramCNN_GRUNet(nn.Module):
    def __init__(self, num_classes=10):
        super(SpectrogramCNN_GRUNet, self).__init__()

        # --- 1. Convolutional Layers ---
        self.conv1 = nn.Conv2d(1, 32, kernel_size=(3, 3), padding=1)
        self.bn1 = nn.BatchNorm2d(32)
        self.conv2 = nn.Conv2d(32, 64, kernel_size=(3, 3), padding=1)
        self.bn2 = nn.BatchNorm2d(64)
        self.conv3 = nn.Conv2d(64, 128, kernel_size=(3, 3), padding=1)
        self.bn3 = nn.BatchNorm2d(128)
        self.pool = nn.MaxPool2d(kernel_size=(2, 2), stride=(2, 2))
        self.drop = nn.Dropout(0.25)

        # --- 2. GRU Layer Configuration ---
        # 64 个 Mel 频带经过 3 次池化后剩 8 -> GRU input size = 128 * 8 = 1024
        self.gru_input_size = 128 * 8
        self.gru1 = nn.GRU(input_size=self.gru_input_size, hidden_size=68, batch_first=True, num_layers=1)
        self.gru2 = nn.GRU(input_size=68, hidden_size=68, batch_first=True, num_layers=1)

        # --- 3. Fully Connected Layers ---
        self.fc1 = nn.Linear(68, 512)
        self.fc2 = nn.Linear(512, num_classes)
        self.drop_fc = nn.Dropout(0.5)

    def forward(self, x):
        # --- CNN Feature Extraction ---
        x = self.pool(torch.relu(self.bn1(self.conv1(x))))
        x = self.drop(x)

        x = self.pool(torch.relu(self.bn2(self.conv2(x))))
        x = self.drop(x)

        x = self.pool(torch.relu(self.bn3(self.conv3(x))))
        x = self.drop(x)

        # Reshape for GRU layer input: [batch, seq_len, features]
        b, c, h, w = x.size()
        x = x.view(b, w, c * h)

        # --- GRU Sequence Modeling ---
        x, _ = self.gru1(x)
        x, _ = self.gru2(x)

        # Use the final hidden state for classification
        x = x[:, -1, :]

        # --- Fully Connected Layer ---
        x = torch.relu(self.fc1(x))
        x = self.drop_fc(x)
        x = self.fc2(x)
        return x
