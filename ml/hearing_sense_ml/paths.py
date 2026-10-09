from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = Path(__file__).resolve().parent / "assets"
DATA = ROOT / "data"
MODELS = ROOT / "models"
ESSENTIA_MODELS = MODELS / "pretrained" / "essentia"
COREML_OUT = MODELS / "coreml"
RESULTS = ROOT / "results"
CHECKPOINTS = ROOT / "checkpoints"
