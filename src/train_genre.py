# 流派分类模型 (SpectrogramCNN_GRUNet) 在 GTZAN 上的训练脚本
# 用法: python src/train_genre.py
# 需要先把 GTZAN 的 genres_original/ 放到 data/gtzan/ 下，见 data/README.md
import os
import random

import numpy as np
import pandas as pd
import torch
import torch.nn as nn
import torch.optim as optim
import torchaudio
import matplotlib.pyplot as plt
import seaborn as sns
from tqdm import tqdm
from sklearn.model_selection import train_test_split
from sklearn.metrics import confusion_matrix, precision_score, recall_score, f1_score, roc_auc_score, roc_curve
from sklearn.preprocessing import label_binarize

import config
from genre_model import SpectrogramCNN_GRUNet, genre_melspec, GENRE_SR, GENRE_SEGMENT_MS

device = torch.device(config.device)
RESULTS_GENRE = config.RESULTS_DIR / "genre"


def split_audio(audio_file, output_dir, num_segments=5, original_name=""):
    try:
        waveform, sample_rate = torchaudio.load(audio_file)
    except RuntimeError:
        print(f"Failed to load: {audio_file}")
        return  # Exit if loading fails to prevent further processing

    # Segment length calculation
    total_duration = waveform.size(1) / sample_rate
    segment_duration = total_duration / num_segments

    os.makedirs(output_dir, exist_ok=True)

    # Split the audio into segments and save each segment as a separate file
    for i in range(num_segments):
        start = int(i * segment_duration * sample_rate)
        end = int((i + 1) * segment_duration * sample_rate)

        # Ensure end does not exceed the waveform length
        if end > waveform.size(1):
            end = waveform.size(1)

        segment_waveform = waveform[:, start:end]

        # Construct unique name for the segment based on original file name
        segment_name = f"{original_name}_segment_{i + 1}.wav"
        output_file = os.path.join(output_dir, segment_name)

        torchaudio.save(output_file, segment_waveform, sample_rate)


def split_audio_files(input_dir, output_dir, num_segments=5):
    # Iterate through each class folder
    for class_folder in os.listdir(input_dir):
        class_path = os.path.join(input_dir, class_folder)
        if os.path.isdir(class_path):
            output_class_path = os.path.join(output_dir, class_folder)
            os.makedirs(output_class_path, exist_ok=True)

            for audio_file in os.listdir(class_path):
                audio_file_path = os.path.join(class_path, audio_file)
                if os.path.isfile(audio_file_path):
                    split_audio(audio_file_path, output_class_path, num_segments, audio_file)


def build_gtzan_df(split_dir):
    file_genre = []
    file_path = []
    for folder in os.listdir(split_dir):
        files_path = os.path.join(split_dir, folder)
        if not os.path.isdir(files_path):
            continue
        for audio in os.listdir(files_path):
            file_genre.append(folder)
            file_path.append(os.path.join(files_path, audio))
    return pd.DataFrame({"Genre": file_genre, "Path": file_path})


class AudioUtil():
    @staticmethod
    def open(audio_file):
        sig, sr = torchaudio.load(audio_file)
        return (sig, sr)
    @staticmethod
    def rechannel(aud, new_channel):
        sig, sr = aud
        if (sig.shape[0] == new_channel):
            return aud
        if (new_channel == 1):
            resig = sig[:1, :]
        else:
            resig = torch.cat([sig, sig])

        return ((resig, sr))
    @staticmethod
    def resample(aud, newsr):
        sig, sr = aud
        if (sr == newsr):
            return aud

        num_channels = sig.shape[0]
        resig = torchaudio.transforms.Resample(sr, newsr)(sig[:1,:])
        if (num_channels > 1):
            retwo = torchaudio.transforms.Resample(sr, newsr)(sig[1:,:])
            resig = torch.cat([resig, retwo])
        return ((resig, newsr))
    @staticmethod
    def pad_trunc(aud, max_ms):
        sig, sr = aud
        num_rows, sig_len = sig.shape
        max_len = sr//1000 * max_ms

        if (sig_len > max_len):
            # Truncate the signal to the given length
            sig = sig[:,:max_len]

        elif (sig_len < max_len):
            # Length of padding to add at the beginning and end of the signal
            pad_begin_len = random.randint(0, max_len - sig_len)
            pad_end_len = max_len - sig_len - pad_begin_len

            # Pad with 0s
            pad_begin = torch.zeros((num_rows, pad_begin_len))
            pad_end = torch.zeros((num_rows, pad_end_len))

            sig = torch.cat((pad_begin, sig, pad_end), 1)

        return (sig, sr)


class AudioDataset(torch.utils.data.Dataset):
    def __init__(self, dataframe):
        self.class_names = sorted(dataframe['Genre'].unique())
        self.class_to_index = {class_name: i for i, class_name in enumerate(self.class_names)}
        self.file_list = [(row['Path'], self.class_to_index[row['Genre']]) for index, row in dataframe.iterrows()]

        self.sr = GENRE_SR
        self.duration = GENRE_SEGMENT_MS
        self.channel = 1

    def __len__(self):
        return len(self.file_list)

    def __getitem__(self, idx):
        audio_file, class_id = self.file_list[idx]

        aud = AudioUtil.open(audio_file)
        resample = AudioUtil.resample(aud, self.sr)
        rechannel = AudioUtil.rechannel(resample, self.channel)
        sig, sr = AudioUtil.pad_trunc(rechannel, self.duration)
        melspectrogram = genre_melspec(sig, sr)

        return melspectrogram, class_id


def create_data_loader(dataframe, max_batch_size=16, shuffle=True):
    audio_dataset = AudioDataset(dataframe)
    return torch.utils.data.DataLoader(audio_dataset, batch_size=max_batch_size, shuffle=shuffle)


def train(model, train_loader, val_loader, num_epochs=100):
    optimizer = optim.Adam(model.parameters(), lr=0.001)
    criterion = nn.CrossEntropyLoss()
    best_accuracy = 0.0

    for epoch in range(num_epochs):
        model.train()
        running_loss = 0.0

        train_iterator = tqdm(train_loader, total=len(train_loader), desc=f"Epoch {epoch+1}/{num_epochs}", leave=False)

        for batch_idx, (inputs, labels) in enumerate(train_iterator):
            inputs = inputs.float().to(device)
            labels = labels.to(device)

            optimizer.zero_grad()
            outputs = model(inputs)
            loss = criterion(outputs, labels)
            loss.backward()
            optimizer.step()

            running_loss += loss.item() * inputs.size(0)
            train_iterator.set_postfix(loss=running_loss / ((batch_idx + 1) * train_loader.batch_size))

        epoch_loss = running_loss / len(train_loader.dataset)

        # Validation
        model.eval()
        correct = 0
        total = 0
        with torch.no_grad():
            for inputs, labels in val_loader:
                inputs, labels = inputs.float().to(device), labels.to(device)
                outputs = model(inputs)
                _, predicted = torch.max(outputs, 1)
                total += labels.size(0)
                correct += (predicted == labels).sum().item()

        val_accuracy = correct / total
        print(f"Epoch [{epoch+1}/{num_epochs}], Training Loss: {epoch_loss:.4f}, Validation Accuracy: {val_accuracy:.2%}")

        # Save the best model based on validation accuracy
        if val_accuracy > best_accuracy:
            best_accuracy = val_accuracy
            torch.save(model.state_dict(), config.model_path_genre)

    print(f"Best validation accuracy: {best_accuracy:.2%}")


def evaluate(model, test_loader, class_names):
    num_classes = len(class_names)
    model.load_state_dict(torch.load(config.model_path_genre, map_location=device))
    model.eval()

    predicted_labels = []
    true_labels = []
    all_predicted_probs = []

    with torch.no_grad():
        for inputs, labels in test_loader:
            inputs, labels = inputs.float().to(device), labels.to(device)
            outputs = model(inputs)
            _, predicted = torch.max(outputs, 1)
            predicted_labels.extend(predicted.cpu().numpy())
            true_labels.extend(labels.cpu().numpy())
            all_predicted_probs.append(torch.softmax(outputs, dim=1).cpu().numpy())

    test_accuracy = np.mean(np.array(predicted_labels) == np.array(true_labels))
    print(f"Test Accuracy: {test_accuracy:.2%}")

    precision = precision_score(true_labels, predicted_labels, average='weighted')
    recall = recall_score(true_labels, predicted_labels, average='weighted')
    f1 = f1_score(true_labels, predicted_labels, average='weighted')

    all_predicted_probs = np.concatenate(all_predicted_probs, axis=0)
    true_labels_bin = label_binarize(true_labels, classes=range(num_classes))
    roc_auc = roc_auc_score(true_labels_bin, all_predicted_probs, multi_class='ovr')

    RESULTS_GENRE.mkdir(parents=True, exist_ok=True)

    plt.figure(figsize=(10, 8))
    sns.heatmap(confusion_matrix(true_labels, predicted_labels), annot=True, fmt="d", cmap="Blues",
                xticklabels=class_names, yticklabels=class_names)
    plt.xlabel('Predicted Labels')
    plt.ylabel('True Labels')
    plt.title('Confusion Matrix')
    plt.savefig(RESULTS_GENRE / 'confusion_matrix.png')
    plt.show()

    fpr, tpr, _ = roc_curve(true_labels_bin.ravel(), all_predicted_probs.ravel())
    plt.figure(figsize=(8, 6))
    plt.plot(fpr, tpr, label='ROC curve (area = %0.2f)' % roc_auc)
    plt.plot([0, 1], [0, 1], linestyle='--')
    plt.xlabel('False Positive Rate')
    plt.ylabel('True Positive Rate')
    plt.title('ROC Curve')
    plt.legend(loc='best')
    plt.savefig(RESULTS_GENRE / 'roc_curve.png')
    plt.show()

    print(f"Precision: {precision:.4f}")
    print(f"Recall: {recall:.4f}")
    print(f"F1 Score: {f1:.4f}")
    print(f"ROC AUC Score: {roc_auc:.4f}")


def main():
    if not config.GTZAN_SPLIT_DIR.exists():
        split_audio_files(config.GTZAN_AUDIO_DIR, config.GTZAN_SPLIT_DIR, num_segments=10)
    gtzan_df = build_gtzan_df(config.GTZAN_SPLIT_DIR)

    # 注意: 先切片再随机划分，同一首歌的片段会同时出现在训练集和测试集
    train_df, test_df = train_test_split(gtzan_df, test_size=0.2, random_state=42)
    train_df, val_df = train_test_split(train_df, test_size=0.1, random_state=42)

    train_loader = create_data_loader(train_df)
    val_loader = create_data_loader(val_df)
    test_loader = create_data_loader(test_df)
    class_names = train_loader.dataset.class_names

    model = SpectrogramCNN_GRUNet(num_classes=len(class_names)).to(device)
    train(model, train_loader, val_loader)
    evaluate(model, test_loader, class_names)


if __name__ == "__main__":
    main()
