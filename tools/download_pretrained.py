# 下载 Essentia 预训练模型 (ONNX + 元数据 JSON)，约 27 MB。
# 模型许可: CC BY-NC-SA 4.0 (MTG, Universitat Pompeu Fabra) —— 仅限非商业用途，衍生作品须使用相同许可。
# 用法: .venv/bin/python tools/download_pretrained.py
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "models" / "pretrained" / "essentia"
BASE = "https://essentia.upf.edu/models"

# 相对路径 -> SHA-256 (首次下载时记录；None 表示尚未固定)
FILES = {
    "feature-extractors/discogs-effnet/discogs-effnet-bsdynamic-1": None,
    "feature-extractors/musicnn/msd-musicnn-1": None,
    "classification-heads/mood_aggressive/mood_aggressive-discogs-effnet-1": None,
    "classification-heads/mood_happy/mood_happy-discogs-effnet-1": None,
    "classification-heads/mood_relaxed/mood_relaxed-discogs-effnet-1": None,
    "classification-heads/mood_sad/mood_sad-discogs-effnet-1": None,
    "classification-heads/mood_party/mood_party-discogs-effnet-1": None,
    "classification-heads/danceability/danceability-discogs-effnet-1": None,
    "classification-heads/voice_instrumental/voice_instrumental-discogs-effnet-1": None,
    "classification-heads/mtg_jamendo_moodtheme/mtg_jamendo_moodtheme-discogs-effnet-1": None,
    "classification-heads/deam/deam-msd-musicnn-2": None,
    "classification-heads/emomusic/emomusic-msd-musicnn-2": None,
}
HASHES = DEST / "SHA256SUMS.json"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    pinned = json.loads(HASHES.read_text()) if HASHES.exists() else {}
    for rel in FILES:
        for ext in (".onnx", ".json"):
            name = Path(rel).name + ext
            out = DEST / name
            if not out.exists():
                print(f"下载 {name}")
                urllib.request.urlretrieve(f"{BASE}/{rel}{ext}", out)
            digest = sha256(out)
            if name in pinned and pinned[name] != digest:
                sys.exit(f"校验失败: {name} 的 SHA-256 与记录不一致，请删除后重新下载")
            pinned[name] = digest
    HASHES.write_text(json.dumps(pinned, indent=1, sort_keys=True))
    total = sum(p.stat().st_size for p in DEST.glob("*.onnx"))
    print(f"完成: {len(pinned)} 个文件, ONNX 合计 {total / 1e6:.1f} MB -> {DEST}")


if __name__ == "__main__":
    main()
