import sys
import librosa
import torch
import numpy as np
import torchaudio
from emotion_model import EfficientNetModel
from genre_model import SpectrogramCNN_GRUNet, genre_melspec, GENRE_SR, GENRE_SEGMENT_MS
from config import device, model_path_emo, model_path_genre, LABEL_COL, GENRE_COL

# Global variables for models
model_emo = None
model_genre = None

def load_model_emo():
    """Load the emotion prediction model"""
    global model_emo
    if model_emo is None:
        model_emo = EfficientNetModel(pretrained=False)  # 权重来自本地文件，不需要下载 ImageNet 权重
        model_emo.load_state_dict(torch.load(model_path_emo, map_location=torch.device(device)))
        model_emo = model_emo.to(device)
        model_emo.eval()
        print(f"情感预测模型加载成功，使用设备: {device}")
    return model_emo

def load_model_genre():
    """Load the genre classification model"""
    global model_genre
    if model_genre is None:
        model_genre = SpectrogramCNN_GRUNet(num_classes=len(GENRE_COL))
        model_genre.load_state_dict(torch.load(model_path_genre, map_location=torch.device(device)))
        model_genre = model_genre.to(device)
        model_genre.eval()
        print(f"流派分类模型加载成功，使用设备: {device}")
    return model_genre

def pred(audio_path):
    """Prediction function for emotion and genre"""
    current_model_emo = load_model_emo()
    current_model_genre = load_model_genre()

    try:
        # --- Emotion Prediction ---
        # 与 emotion_dataset.py 相同的预处理: 44.1 kHz 单声道，5 秒片段，128 Mel
        y_full, sr = librosa.load(audio_path, sr=44100, mono=True)
        segment_samples = 5 * sr
        segments = [y_full[i:i + segment_samples] for i in range(0, len(y_full), segment_samples)
                    if len(y_full[i:i + segment_samples]) == segment_samples]

        if not segments:
            print("音频文件太短，无法提取有效片段 for emotion prediction")
            return None, None, None, None

        mel_specs = []
        for segment in segments:
            mel_spec = librosa.feature.melspectrogram(y=segment, sr=sr, n_mels=128, n_fft=2048, hop_length=512)
            mel_spec_db = librosa.power_to_db(mel_spec, ref=np.max)
            mel_specs.append(mel_spec_db)

        mel_specs = torch.tensor(np.array(mel_specs)).float().to(device)

        with torch.no_grad():
            logits_emo = current_model_emo(mel_specs.unsqueeze(dim=1))  # Add channel dimension
            final_logits_emo = logits_emo.mean(dim=0)  # Average over segments
            probabilities_emo = torch.softmax(final_logits_emo, dim=0)  # 与训练时的交叉熵一致
            top3_probs_emo, top3_indices_emo = torch.topk(probabilities_emo, 3)

        # --- Genre Prediction ---
        waveform, sr = torchaudio.load(audio_path)
        if sr != GENRE_SR:
            waveform = torchaudio.transforms.Resample(sr, GENRE_SR)(waveform)
        if waveform.shape[0] > 1:
            waveform = torch.mean(waveform, dim=0, keepdim=True)  # Convert to mono

        # 5.5 秒片段，与训练时一致
        segment_length = GENRE_SR // 1000 * GENRE_SEGMENT_MS
        num_segments = waveform.size(1) // segment_length
        segments = [waveform[:, i * segment_length:(i + 1) * segment_length] for i in range(num_segments)]

        if len(segments) == 0:
            print("音频文件太短，无法提取有效片段 for genre prediction")
            return None, None, None, None

        mel_spectrograms = torch.stack([genre_melspec(segment) for segment in segments]).to(device)

        with torch.no_grad():
            logits_genre = current_model_genre(mel_spectrograms)
            probabilities_genre = torch.softmax(logits_genre, dim=1)
            avg_probabilities = probabilities_genre.mean(dim=0)  # Average over segments
            top1_prob_genre, top1_index_genre = torch.max(avg_probabilities, dim=0)

        return top3_probs_emo, top3_indices_emo, top1_prob_genre.item(), top1_index_genre.item()

    except Exception as e:
        print(f"预测过程中出错: {e}")
        return None, None, None, None

def predict_with_labels(audio_path):
    """Predict and return results with labels for emotion and genre"""
    top3_probs_emo, top3_indices_emo, top1_prob_genre, top1_index_genre = pred(audio_path)

    if top3_indices_emo is not None and top1_index_genre is not None:
        indices_emo_list = top3_indices_emo.cpu().numpy()
        probs_emo_list = top3_probs_emo.cpu().numpy()
        top3_labels_emo = [LABEL_COL[i].strip() for i in indices_emo_list]

        return {
            'emotion': {
                'indices': indices_emo_list.tolist(),
                'labels': top3_labels_emo,
                'probabilities': probs_emo_list.tolist()
            },
            'genre': {
                'index': top1_index_genre,
                'label': GENRE_COL[top1_index_genre],
                'probability': top1_prob_genre
            }
        }
    return None

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print('用法: python src/infer.py "data/samples/Shattered Roads.mp3"')
        sys.exit(1)
    audio_path = sys.argv[1]

    print(f"正在预测音频文件: {audio_path}")
    result = predict_with_labels(audio_path)

    if result is not None:
        print("-" * 50)
        print("情感预测结果:")
        print(f"Top 3 预测标签: {result['emotion']['labels']}")
        print(f"对应的概率: {result['emotion']['probabilities']}")
        print("-" * 50)
        print("流派预测结果:")
        print(f"预测标签: {result['genre']['label']}")
        print(f"对应的概率: {result['genre']['probability']}")
    else:
        print("预测失败")
