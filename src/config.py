# config.py

import torch
from pathlib import Path

# --- 路径：全部相对于项目根目录 ---
ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
EMOTIFY_DIR = DATA_DIR / "emotify"
EMOTIFY_AUDIO_DIR = EMOTIFY_DIR / "audio"           # 子文件夹: classical/ rock/ electronic/ pop/
EMOTIFY_ANNOTATIONS = EMOTIFY_DIR / "annotations.csv"
GTZAN_AUDIO_DIR = DATA_DIR / "gtzan" / "genres_original"
GTZAN_SPLIT_DIR = DATA_DIR / "gtzan" / "split"
MODELS_DIR = ROOT / "models"
RESULTS_DIR = ROOT / "results"
UPLOAD_DIR = ROOT / "uploads"

train_csv = EMOTIFY_DIR / "processed_data.csv"
model_path_emo = MODELS_DIR / "emotion_efficientnet.pth"
model_path_genre = MODELS_DIR / "genre_crnn.pth"

# 列名前的空格与 Emotify 原始 CSV 保持一致
LABEL_COL = [
    ' amazement', ' solemnity', ' tenderness', ' nostalgia',
    ' calmness', ' power', ' joyful_activation', ' tension', ' sadness']

GENRE_COL = [
    'blues', 'classical', 'country', 'disco', 'hiphop', 'jazz', 'metal', 'pop', 'reggae', 'rock']


seed = 42
num_workers = 0

if torch.cuda.is_available():
    device = 'cuda'
elif torch.backends.mps.is_available():
    device = 'mps'
else:
    device = 'cpu'

epochs = 30  # 20 最好
batch_size = 128
criterion = 'CE'

optimizer = 'AdamW'
lr = 5e-4
weight_decay = 1e-5

scheduler = 'CosineAnnealingLR'
min_lr = 1e-6
T_max = epochs
