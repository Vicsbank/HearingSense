"""声学退化：模拟“手机扬声器外放 -> 房间 -> Mac 麦克风”以及各种噪声环境。

用于评估（以后也用于训练时的数据增强）。所有函数都是确定性的（显式传入 rng），
输入输出均为单声道 float32，采样率由参数 sr 指定（评估时在 44.1 kHz 上模拟，再重采样给各模型）。

这些变换只改变“录音条件”，不改变音乐本身，所以不会使流派/情绪标签失效。
但 SNR 过低（例如 < 0 dB）时，人耳也难以判断音乐内容，此时的结果只用来测试“是否会拒绝判断”。
"""
from dataclasses import dataclass

import numpy as np
from scipy import signal

SR = 44100


def rms(x):
    return float(np.sqrt(np.mean(np.square(x, dtype=np.float64)) + 1e-12))


def gain_db(x, db):
    return x * (10 ** (db / 20))


def mix_at_snr(clean, noise, snr_db, rng):
    """把 noise 以给定 SNR（相对 clean 的 RMS）混入；noise 不够长时循环使用，起点随机"""
    if len(noise) < len(clean):
        noise = np.tile(noise, int(np.ceil(len(clean) / len(noise))) + 1)
    start = rng.integers(0, len(noise) - len(clean) + 1)
    n = noise[start:start + len(clean)]
    scale = rms(clean) / (rms(n) * 10 ** (snr_db / 20))
    return clean + n * scale


def synthetic_rir(rt60, rng, drr_db=3.0, sr=SR):
    """指数衰减噪声构成的合成房间冲激响应。drr_db 为直达声与混响能量比，距离越远越小。"""
    length = int(sr * min(1.5 * rt60, 2.0))
    t = np.arange(length) / sr
    tail = rng.standard_normal(length) * np.exp(-6.9078 * t / rt60)  # 60 dB 衰减
    tail[: int(0.003 * sr)] = 0  # 早期反射前的空隙
    tail = signal.lfilter(*signal.butter(1, 4000, fs=sr), tail)  # 空气与墙面吸收高频
    tail *= np.sqrt(10 ** (-drr_db / 10) / (np.sum(tail ** 2) + 1e-12))
    rir = tail
    rir[0] = 1.0
    return rir


def convolve_rir(x, rir):
    y = signal.fftconvolve(x, rir)[: len(x)]
    return y * (rms(x) / (rms(y) + 1e-12))


def phone_speaker(x, rng, drive=2.0, sr=SR):
    """手机外放：低频大幅衰减（小扬声器 ~300 Hz 以下几乎没有）、高频滚降、2–4 kHz 共振、轻度失真"""
    y = signal.sosfilt(signal.butter(4, 300, "highpass", fs=sr, output="sos"), x)
    y = signal.sosfilt(signal.butter(2, 7000, "lowpass", fs=sr, output="sos"), y)
    b, a = signal.iirpeak(3000, Q=1.5, fs=sr)
    y = y + 0.5 * signal.lfilter(b, a, y)
    peak = np.max(np.abs(y)) + 1e-9
    y = np.tanh(drive * y / peak) / np.tanh(drive)  # 大音量时的软削波
    return y * (rms(x) / (rms(y) + 1e-12))


def laptop_mic(x, rng, noise_floor_dbfs=-70.0, sr=SR):
    """笔记本麦克风：80 Hz 高通、轻微高频提升，加上麦克风/前置放大器的本底噪声"""
    y = signal.sosfilt(signal.butter(2, 80, "highpass", fs=sr, output="sos"), x)
    b, a = signal.iirpeak(5000, Q=0.8, fs=sr)
    y = y + 0.2 * signal.lfilter(b, a, y)
    return y + rng.standard_normal(len(y)) * 10 ** (noise_floor_dbfs / 20)


def normalize_level(x, target_dbfs):
    return x * (10 ** (target_dbfs / 20) / (rms(x) + 1e-12))


@dataclass
class Condition:
    """一种录音条件。noise_kind: None / 'babble' / 'ambient' / 'pink'"""
    name: str
    speaker: bool = False
    rt60: float = 0.0
    drr_db: float = 3.0
    noise_kind: str = None
    snr_db: float = None
    level_dbfs: float = -25.0
    description: str = ""
    real_rir: bool = False  # True: 从实测房间脉冲响应 (MIT IR Survey) 中随机选一个，代替合成混响


def _noisy(kind, snr, label):
    return Condition(f"phone_{kind}_{snr}dB", speaker=True, rt60=0.4, drr_db=6, noise_kind=kind, snr_db=snr,
                     level_dbfs=-28, description=f"1 m 外放 + {label}，SNR {snr} dB")


CONDITIONS = [
    Condition("clean", level_dbfs=-20, description="原始文件，未经任何处理"),
    Condition("phone_room_1m", speaker=True, rt60=0.4, drr_db=6, level_dbfs=-28,
              description="手机外放，普通房间 (合成混响 RT60 0.4 s)，约 1 m"),
    Condition("phone_realroom", speaker=True, real_rir=True, rt60=0.4, level_dbfs=-28,
              description="手机外放，实测房间脉冲响应 (MIT IR Survey，随机选取)"),
    Condition("phone_room_3m", speaker=True, rt60=0.7, drr_db=-2, level_dbfs=-36,
              description="手机外放，较大房间 (RT60 0.7 s)，约 3 m，音量更低"),
    Condition("phone_quiet", speaker=True, rt60=0.4, drr_db=6, level_dbfs=-50,
              description="1 m 外放，极低音量（接近麦克风本底噪声）"),
    # 信噪比梯度：同一房间设置下只改变噪声强度，得到“准确度随噪声变化”的曲线。0 dB 表示噪声与音乐一样响
    *[_noisy("babble", snr, "背景多人交谈") for snr in (20, 10, 5, 0)],
    *[_noisy("ambient", snr, "真实环境噪声（餐厅/街道/客厅/车站）") for snr in (20, 10, 5, 0)],
]

PRESETS = {
    "all": [c.name for c in CONDITIONS],
    "core": ["clean", "phone_room_1m", "phone_realroom", "phone_babble_10dB", "phone_ambient_10dB", "phone_quiet"],
    "noise": ["clean", "phone_room_1m"] + [c.name for c in CONDITIONS if c.noise_kind],
}


def apply_condition(x, cond, rng, noises, sr=SR):
    """noises: {'babble'|'ambient'|'pink'|'rir': [数组, ...]}，均与 x 同采样率"""
    y = np.asarray(x, np.float64)
    if cond.name == "clean":
        return normalize_level(y, cond.level_dbfs).astype(np.float32)
    if cond.speaker:
        y = phone_speaker(y, rng, sr=sr)
    if cond.rt60 > 0:
        if cond.real_rir and noises.get("rir"):
            rir = noises["rir"][rng.integers(len(noises["rir"]))]
        else:
            rir = synthetic_rir(cond.rt60, rng, drr_db=cond.drr_db, sr=sr)
        y = convolve_rir(y, rir)
    if cond.noise_kind:
        pool = noises.get(cond.noise_kind) or noises.get("pink")
        noise = pool[rng.integers(len(pool))]
        # 噪声也在同一个房间里，同样经过混响
        noise = convolve_rir(noise[: len(y) * 2], synthetic_rir(max(cond.rt60, 0.3), rng, drr_db=0, sr=sr))
        y = mix_at_snr(y, noise, cond.snr_db, rng)
    y = normalize_level(y, cond.level_dbfs)
    y = laptop_mic(y, rng, sr=sr)
    return np.clip(y, -1, 1).astype(np.float32)


def pink_noise(n, rng, sr=SR):
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / sr)
    spec[1:] /= np.sqrt(f[1:])
    spec[0] = 0
    y = np.fft.irfft(spec, n)
    return (y / (rms(y) + 1e-12) * 0.1).astype(np.float32)


def make_babble(speech_clips, rng, n_talkers=4, seconds=30, sr=SR):
    """把若干段语音叠加成“多人交谈”背景"""
    n = sr * seconds
    out = np.zeros(n)
    for _ in range(n_talkers):
        s = speech_clips[rng.integers(len(speech_clips))]
        s = np.tile(s, int(np.ceil(n / len(s))) + 1)
        start = rng.integers(0, len(s) - n + 1)
        out += s[start:start + n] / (rms(s) + 1e-12)
    return (out / (rms(out) + 1e-12) * 0.1).astype(np.float32)
