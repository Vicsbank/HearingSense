from torch.utils.data import Dataset, DataLoader
import librosa
import pandas as pd
import torch
import numpy as np
from tqdm.auto import tqdm
import config
import random

class MusicEmoDataset(Dataset):
    def __init__(self, df):
        self.df = df
        self.label_columns = config.LABEL_COL

    def __len__(self):
        return len(self.df)

    def __getitem__(self, idx):
        row = self.df.iloc[idx]
        labels = row[self.label_columns].values.astype(np.float32)
        labels = torch.tensor(labels)
        audio_samples = self.read_audio(config.EMOTIFY_AUDIO_DIR / row.original_path)
        audio_sample = random.choice(audio_samples)
        audio = torch.tensor(audio_sample[np.newaxis]).float()
        return {
            'audios': audio,
            'labels': labels
        }

    def read_audio(self, path):
        y_full, sr = librosa.load(path, sr=44100, mono=True)
        segment_samples = 5 * sr
        segments = [y_full[i:i+segment_samples] for i in range(0, len(y_full), segment_samples)
                    if len(y_full[i:i+segment_samples]) == segment_samples]

        mel_specs = []
        for segment in segments:
            mel_spec = librosa.feature.melspectrogram(y=segment, sr=sr, n_mels=128, n_fft=2048, hop_length=512)
            mel_spec_db = librosa.power_to_db(mel_spec, ref=np.max)
            mel_specs.append(mel_spec_db)
        return mel_specs

if __name__ == "__main__":
    df = pd.read_csv(config.train_csv)
    # 只取本地已有音频的曲目
    df = df[df['original_path'].map(lambda p: (config.EMOTIFY_AUDIO_DIR / p).exists())]
    dataset = MusicEmoDataset(df)
    train_loader = DataLoader(
            dataset,
            batch_size=2,
            shuffle=True,
            num_workers=0,
            drop_last=True,
        )

    pbar = tqdm(enumerate(train_loader), total=len(train_loader), desc="Data extracting")
    for step, batch in pbar:
        inputs = batch['audios']
        print(inputs.shape)
        print(batch['labels'])
        break
