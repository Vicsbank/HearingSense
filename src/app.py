import shutil
import os
from pathlib import Path
import warnings
from fastapi import FastAPI, Request, UploadFile, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from config import device, model_path_emo, model_path_genre, UPLOAD_DIR
from infer import predict_with_labels, load_model_emo, load_model_genre

# Ignore warnings
warnings.filterwarnings("ignore", category=UserWarning)

app = FastAPI()
templates = Jinja2Templates(directory=Path(__file__).resolve().parent / "templates")

# Global variables for models
model_emo = None
model_genre = None

@app.get("/app", response_class=HTMLResponse)
async def read_app(request: Request):
    return templates.TemplateResponse("app.html", {"request": request})

@app.get("/", response_class=HTMLResponse)
async def read_homepage(request: Request):
    return templates.TemplateResponse("homepage.html", {"request": request})

@app.on_event("startup")
async def startup_event():
    global model_emo, model_genre
    print("Starting application and loading models...")
    model_emo = load_model_emo()
    model_genre = load_model_genre()
    if model_emo and model_genre:
        print("✅ Models loaded successfully!")
    else:
        print("❌ Model loading failed! Please check model file paths")

@app.get("/health")
def health_check():
    return {
        "status": "healthy",
        "model_loaded": model_emo is not None and model_genre is not None
    }

@app.get("/model_status")
def model_status():
    return {
        "model_loaded": model_emo is not None and model_genre is not None,
        "device": device,
        "model_path_emo": str(model_path_emo),
        "model_path_genre": str(model_path_genre),
    }

UPLOAD_DIR.mkdir(exist_ok=True)

@app.post("/uploadfile/")
async def create_upload_file(file: UploadFile):
    allowed_extensions = ('.mp3', '.wav', '.flac', '.m4a', '.aac')
    if not file.filename.lower().endswith(allowed_extensions):
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported audio file format. Supported formats: {', '.join(allowed_extensions)}"
        )

    destination = UPLOAD_DIR / Path(file.filename).name

    try:
        print(f"Saving file: {file.filename}")
        with destination.open("wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        print(f"File saved to: {destination}")

        print("Performing prediction...")
        result = predict_with_labels(str(destination))

        if result is not None:
            print("Prediction successful!")
            print(f"Emotion Top 3 predicted labels: {result['emotion']['labels']}")
            print(f"Corresponding probabilities: {result['emotion']['probabilities']}")
            print(f"Genre predicted label: {result['genre']['label']}")
            print(f"Corresponding probability: {result['genre']['probability']}")

            response = {
                "success": True,
                "filename": file.filename,
                "file_size": destination.stat().st_size,
                "predictions": {
                    "emotion": {
                        "top3_labels": result['emotion']['labels'],
                        "top3_probabilities": result['emotion']['probabilities'],
                        "top3_indices": result['emotion']['indices']
                    },
                    "genre": {
                        "label": result['genre']['label'],
                        "probability": result['genre']['probability'],
                        "index": result['genre']['index']
                    }
                },
                "message": "Prediction successful"
            }
        else:
            print("Prediction failed")
            response = {
                "success": False,
                "filename": file.filename,
                "error": "Prediction failed, please check audio file format or model status",
                "message": "Prediction failed"
            }
    except Exception as e:
        if destination.exists():
            try:
                os.remove(destination)
                print(f"Deleted erroneous file: {destination}")
            except OSError:
                pass
        error_msg = f"Error processing file: {str(e)}"
        print(f"Error: {error_msg}")
        raise HTTPException(status_code=500, detail=error_msg)
    finally:
        file.file.close()
    return response

@app.post("/predict_by_path/")
async def predict_by_path(file_path: str):
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="File not found")

    try:
        result = predict_with_labels(file_path)
        if result is not None:
            return {
                "success": True,
                "file_path": file_path,
                "predictions": {
                    "emotion": {
                        "top3_labels": result['emotion']['labels'],
                        "top3_probabilities": result['emotion']['probabilities'],
                        "top3_indices": result['emotion']['indices']
                    },
                    "genre": {
                        "label": result['genre']['label'],
                        "probability": result['genre']['probability'],
                        "index": result['genre']['index']
                    }
                }
            }
        else:
            return {
                "success": False,
                "file_path": file_path,
                "error": "Prediction failed"
            }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error during prediction: {str(e)}")

if __name__ == "__main__":
    import uvicorn
    print("Starting FastAPI application at http://127.0.0.1:8000 ...")
    uvicorn.run(app, host="127.0.0.1", port=8000)
