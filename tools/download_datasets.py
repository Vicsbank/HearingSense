# 下载评估数据集（2026-10-09 经用户批准：选项 A–D，约 4.2 GB）。
# 用法: .venv/bin/python -I tools/download_datasets.py [--only emotify,gtzan]
#
# - 断点续传：未完成的下载保存为 .part，重新运行会从断点继续
# - 完整性：有官方校验值的（DEMAND MD5、GTZAN/MTG-Jamendo SHA-256）逐一核对；
#   没有官方校验值的，首次下载时把 SHA-256 记录到 data/downloads/CHECKSUMS.json，以后核对
# - 安全解压：每个数据集解压到自己的新目录；拒绝含绝对路径或 “..” 的压缩包成员
# - 压缩包保存在 data/downloads/，解压后可删除；已解压的数据集再次运行时会直接跳过
import argparse
import hashlib
import json
import sys
import tarfile
import threading
import time
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DL = ROOT / "data" / "downloads"
CHECKSUMS = DL / "CHECKSUMS.json"
UA = {"User-Agent": "HearingSense-dataset-downloader/1.0"}
ZENODO = "https://zenodo.org/api/records/1227121/files/{}/content"

# (名称, 说明, URL, 预期字节数, 校验 (算法, 值) 或 None, 解压目录)
ITEMS = [
    ("mit_rir", "MIT 真实房间脉冲响应 (271 个)", "https://mcdermottlab.mit.edu/Reverb/IRMAudio/Audio.zip",
     11_660_005, None, "data/noise/mit_rir"),
    ("emotify", "Emotify 完整音频 (4 流派 × 100 首)",
     "https://www2.projects.science.uu.nl/memotion/emotifydata/emotifymusic.zip",
     380_462_461, None, "data/emotify/audio_full"),
    ("demand_cafeteria", "DEMAND 环境噪声：餐厅 (PCAFETER)", ZENODO.format("PCAFETER_16k.zip"),
     107_431_494, ("md5", "99927d148128254141a9417d051510bb"), "data/noise/demand/PCAFETER"),
    ("demand_traffic", "DEMAND 环境噪声：街道 (STRAFFIC)", ZENODO.format("STRAFFIC_16k.zip"),
     118_572_691, ("md5", "2efa87262f272bbf9ba578088e81939c"), "data/noise/demand/STRAFFIC"),
    ("demand_living", "DEMAND 环境噪声：客厅 (DLIVING)", ZENODO.format("DLIVING_16k.zip"),
     80_170_627, ("md5", "46741384d9e434a0bd8b3ec1830b6052"), "data/noise/demand/DLIVING"),
    ("demand_station", "DEMAND 环境噪声：车站 (PSTATION)", ZENODO.format("PSTATION_16k.zip"),
     119_441_094, ("md5", "d7448009f6c2aeb6ba570375df1750a3"), "data/noise/demand/PSTATION"),
    ("librispeech", "LibriSpeech dev-clean 真实人声", "https://www.openslr.org/resources/12/dev-clean.tar.gz",
     337_926_286, None, "data/noise/librispeech"),
    ("mtg_jamendo_00", "MTG-Jamendo 情绪子集 分片 00 (低码率)",
     "https://cdn.freesound.org/mtg-jamendo/autotagging_moodtheme/audio-low/autotagging_moodtheme_audio-low-00.tar",
     516_843_520, ("sha256", "848b0e7e65604f9d6060adf671a2e9373762a909a0c32bc60eb2d1634126a993"),
     "data/mtg_jamendo/audio"),
    ("gtzan", "GTZAN 10 流派 × 100 段", "https://huggingface.co/datasets/marsyas/gtzan/resolve/main/data/genres.tar.gz",
     1_226_192_050, ("sha256", "b28cc067ff6199bd826f5d1a6931458586d64acae7f44b2e882b7a97af057531"), "data/gtzan"),
]
PMEMO_FOLDER = "https://drive.google.com/drive/folders/1qDk6hZDGVlVXgckjLq9LvXLZ9EgK9gw0"
PMEMO_EST = 1_300_000_000


def human(n):
    return f"{n / 1e6:,.1f} MB" if n < 1e9 else f"{n / 1e9:,.2f} GB"


def fmt_time(s):
    s = int(s)
    return f"{s // 3600:d}:{s % 3600 // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:02d}:{s % 60:02d}"


def bar(frac, width=24):
    full = int(frac * width)
    return "█" * full + "░" * (width - full)


class Overall:
    def __init__(self, total):
        self.total, self.done_before = total, 0


CONNECTIONS = 8          # 实测 Zenodo / Hugging Face / Freesound 都按单个连接限速，多连接可成倍提速
MIN_SEGMENT = 4 << 20    # 每段至少 4 MB


class RangeUnsupported(Exception):
    pass


class Progress:
    """多个下载线程共享的字节计数，主线程负责刷新进度行"""

    def __init__(self, start, expected, overall):
        self.got, self.start, self.expected, self.overall = start, start, expected, overall
        self.t0, self.lock = time.time(), threading.Lock()

    def add(self, n):
        with self.lock:
            self.got += n

    def show(self, conns=1):
        got = self.got
        speed = (got - self.start) / max(time.time() - self.t0, 1e-6)
        eta = (self.expected - got) / speed if speed > 0 else 0
        tot = self.overall.done_before + got
        # 保持在约 60 列以内：终端面板较窄，超宽会换行导致 \r 无法覆盖
        sys.stdout.write(f"\r\033[K  {bar(got / self.expected, 12)} {100 * got / self.expected:3.0f}% "
                         f"{got / 1e6:.0f}/{self.expected / 1e6:.0f}MB {speed / 1e6:4.1f}MB/s ×{conns} "
                         f"ETA {fmt_time(eta)} 总{100 * tot / self.overall.total:3.0f}%")
        sys.stdout.flush()


def fetch_range(url, path, start, end, progress, stop):
    """把 [start, end) 下载到 path；path 已有的字节视为已完成（断点续传）"""
    for attempt in range(6):
        have = path.stat().st_size if path.exists() else 0
        if start + have >= end:
            return
        req = urllib.request.Request(url, headers={**UA, "Range": f"bytes={start + have}-{end - 1}"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                if r.status != 206:
                    raise RangeUnsupported()
                with open(path, "ab") as f:
                    while not stop.is_set():
                        chunk = r.read(1 << 16)
                        if not chunk:
                            break
                        f.write(chunk)
                        progress.add(len(chunk))
            if stop.is_set():
                return
        except (OSError, TimeoutError):
            if attempt == 5:
                raise
            time.sleep(2 * (attempt + 1))


def download(url, dest, expected, overall, label, connections=CONNECTIONS):
    """分段并行下载。已有的 .part（旧版单连接下载留下的）作为前缀保留，只并行下载剩余部分；
    分段文件名包含字节范围，中断后重新运行会复用已下载的分段。服务器不支持分段时退回单连接。"""
    part = dest.with_suffix(dest.suffix + ".part")
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size == expected:
        print(f"  已存在，跳过下载 ({human(expected)})")
        return
    prefix = part.stat().st_size if part.exists() else 0
    remaining = expected - prefix
    n = max(1, min(connections, remaining // MIN_SEGMENT))
    bounds = [(prefix + remaining * i // n, prefix + remaining * (i + 1) // n) for i in range(n)]
    segs = [dest.with_name(f"{dest.name}.seg-{a}-{b}") for a, b in bounds]
    progress = Progress(prefix + sum(p.stat().st_size for p in segs if p.exists()), expected, overall)
    stop = threading.Event()
    threads, errors = [], []

    def worker(a, b, path):
        try:
            fetch_range(url, path, a, b, progress, stop)
        except Exception as e:  # noqa: BLE001  交给主线程统一处理
            errors.append(e)
            stop.set()

    for (a, b), path in zip(bounds, segs):
        t = threading.Thread(target=worker, args=(a, b, path), daemon=True)
        t.start()
        threads.append(t)
    try:
        while any(t.is_alive() for t in threads):
            progress.show(n)
            time.sleep(0.25)
    except KeyboardInterrupt:
        stop.set()
        print("\n  已中断；已下载的分段会保留，重新运行可续传")
        sys.exit(130)
    progress.show(n)
    print()
    if any(isinstance(e, RangeUnsupported) for e in errors):
        print("  服务器不支持分段下载，改用单连接")
        for p in segs:
            p.unlink(missing_ok=True)
        return download(url, dest, expected, overall, label, connections=1) if connections > 1 else \
            sys.exit(f"  ✗ {label}: 服务器不支持续传")
    if errors:
        raise errors[0]
    for (a, b), path in zip(bounds, segs):
        if not path.exists() or path.stat().st_size != b - a:
            sys.exit(f"  ✗ {label}: 分段 {path.name} 不完整，重新运行可续传")
    with open(part, "ab") as out:  # 按顺序把分段接到前缀之后
        for path in segs:
            with open(path, "rb") as f:
                while chunk := f.read(1 << 22):
                    out.write(chunk)
    if part.stat().st_size != expected:
        sys.exit(f"  ✗ {label}: 大小不符 ({part.stat().st_size} != {expected})")
    for path in segs:
        path.unlink()
    part.rename(dest)


def file_hash(path, algo):
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def verify(name, path, checksum, recorded):
    if checksum:
        algo, want = checksum
        got = file_hash(path, algo)
        if got != want:
            path.rename(path.with_suffix(path.suffix + ".bad"))
            sys.exit(f"  ✗ {name}: {algo} 校验失败，文件已改名为 .bad")
        print(f"  ✓ {algo} 与官方校验值一致")
    sha = file_hash(path, "sha256")
    if name in recorded and recorded[name] != sha:
        sys.exit(f"  ✗ {name}: SHA-256 与之前记录的不一致")
    if name not in recorded and not checksum:
        print("  ✓ 无官方校验值，已记录 SHA-256 供以后核对")
    recorded[name] = sha


def save_checksums(recorded):
    """先读取再合并写入：允许两个下载进程（各自负责不同数据集）同时运行"""
    merged = json.loads(CHECKSUMS.read_text()) if CHECKSUMS.exists() else {}
    merged.update(recorded)
    CHECKSUMS.write_text(json.dumps(merged, indent=1, sort_keys=True))


def safe_extract(archive, target):
    target = Path(target)
    marker = target / ".extracted_ok"
    if marker.exists():
        print("  已解压，跳过")
        return
    target.mkdir(parents=True, exist_ok=True)
    print(f"  解压到 {target.relative_to(ROOT)} …", flush=True)
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as z:
            for m in z.namelist():
                p = Path(m)
                if p.is_absolute() or ".." in p.parts:
                    sys.exit(f"  ✗ 压缩包含不安全路径: {m}")
            z.extractall(target)
            n = len(z.namelist())
    else:
        with tarfile.open(archive) as t:
            t.extractall(target, filter="data")  # 拒绝绝对路径、越界路径和设备文件
            n = len(t.getnames())
    marker.write_text(time.strftime("%Y-%m-%d %H:%M:%S"))
    print(f"  ✓ 解压完成，{n} 个条目")


def download_pmemo(recorded):
    import gdown
    out = DL / "pmemo"
    out.mkdir(parents=True, exist_ok=True)
    print("  通过 gdown 下载 Google Drive 文件夹（进度条由 gdown 显示）")
    files = gdown.download_folder(PMEMO_FOLDER, output=str(out), quiet=False, resume=True, use_cookies=False)
    if not files:
        sys.exit("  ✗ PMEmo 下载失败（Google Drive 可能限流），稍后重新运行即可续传")
    for f in map(Path, files):
        recorded[f"pmemo/{f.name}"] = file_hash(f, "sha256")
        if f.suffix == ".zip":
            safe_extract(f, ROOT / "data" / "pmemo" / f.stem)
    print(f"  ✓ PMEmo: {len(files)} 个文件")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="逗号分隔的名称，例如 emotify,gtzan,pmemo")
    args = ap.parse_args()
    only = set(filter(None, args.only.split(",")))
    items = [i for i in ITEMS if not only or i[0] in only]
    want_pmemo = not only or "pmemo" in only
    total = sum(i[3] for i in items) + (PMEMO_EST if want_pmemo else 0)
    overall = Overall(total)
    DL.mkdir(parents=True, exist_ok=True)
    recorded = json.loads(CHECKSUMS.read_text()) if CHECKSUMS.exists() else {}
    n = len(items) + want_pmemo
    print(f"共 {n} 项，约 {human(total)}" + ("（PMEmo 为估计值）" if want_pmemo else "") + "\n")
    t0 = time.time()
    for k, (name, desc, url, size, checksum, target) in enumerate(items, 1):
        print(f"[{k}/{n}] {desc}  ({human(size)})")
        if (ROOT / target / ".extracted_ok").exists():
            print("  已下载并解压（压缩包可能已删除），跳过\n")
            overall.done_before += size
            continue
        fname = url.split("/")[-2] if url.endswith("/content") else url.split("/")[-1]
        archive = DL / name / fname
        for attempt in range(1, 6):
            try:
                download(url, archive, size, overall, name)
                break
            except (OSError, TimeoutError) as e:  # URLError、连接重置、超时都是 OSError
                if attempt == 5:
                    sys.exit(f"\n  ✗ {name}: 连续 5 次失败 ({e})。重新运行脚本会从断点续传")
                print(f"\n  网络中断 ({e})，{5 * attempt} 秒后从断点重试 ({attempt}/5)…")
                time.sleep(5 * attempt)
        verify(name, archive, checksum, recorded)
        save_checksums(recorded)
        safe_extract(archive, ROOT / target)
        overall.done_before += size
        print()
    if want_pmemo:
        print(f"[{n}/{n}] PMEmo 2019（约 {human(PMEMO_EST)}，Google Drive）")
        download_pmemo(recorded)
        save_checksums(recorded)
    print(f"\n全部完成，用时 {fmt_time(time.time() - t0)}。压缩包在 data/downloads/，确认数据可用后可删除。")


if __name__ == "__main__":
    main()
