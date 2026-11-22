import logging
import math
import os
import tempfile
import threading
from collections import Counter
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

import httpx
import joblib
from fastapi import Depends, FastAPI, HTTPException
from pydantic import BaseModel, Field
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import f1_score
from sklearn.model_selection import train_test_split
from sklearn.pipeline import make_pipeline

from src.common.auth import get_principal, require_admin
from src.common.observability import configure


app = FastAPI(title="Заявка: классификация")
configure(app, "classification")
model_path = Path(os.getenv("MODEL_PATH", "/data/model.joblib"))
model_lock = threading.Lock()
model = None
model_stamp = None
logger = logging.getLogger("classification")
Category = Literal["it", "equipment", "household"]


class TextInput(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    description: str = Field(min_length=1, max_length=10000)


class TrainingSample(BaseModel):
    text: str = Field(min_length=1, max_length=10201)
    category: Category


def load_model():
    global model, model_stamp
    try:
        stamp = model_path.stat().st_mtime_ns
    except FileNotFoundError:
        return None
    with model_lock:
        if model_stamp != stamp:
            try:
                # Only service-created artifacts from the private model volume are loaded.
                candidate = joblib.load(model_path)
                model = candidate["model"]
                model_stamp = stamp
            except Exception:
                logger.error("Unable to load model artifact")
                return None
        return model


@app.get("/health")
def health():
    return {"status": "ok", "model_available": load_model() is not None}


@app.post("/classify", dependencies=[Depends(get_principal)])
def classify(data: TextInput):
    classifier = load_model()
    if classifier is None:
        return {"category": None, "available": False}
    category = str(classifier.predict([f"{data.title.strip()}\n{data.description.strip()}"])[0])
    return {"category": category, "available": True}


def training_data():
    base_url = os.getenv("KEYCLOAK_URL", "http://keycloak:8080").rstrip("/")
    realm = os.getenv("KEYCLOAK_REALM", "zayavka")
    try:
        with httpx.Client(timeout=30) as client:
            response = client.post(f"{base_url}/realms/{realm}/protocol/openid-connect/token", data={
                "grant_type": "client_credentials",
                "client_id": os.getenv("KEYCLOAK_CLIENT_ID", "classification-worker"),
                "client_secret": os.environ["KEYCLOAK_CLIENT_SECRET"],
            })
            response.raise_for_status()
            token = response.json()["access_token"]
            response = client.get(
                os.getenv("TRAINING_API_URL", "http://tickets:8000/internal/training-data"),
                headers={"Authorization": f"Bearer {token}"},
            )
            response.raise_for_status()
            return [TrainingSample.model_validate(row) for row in response.json()]
    except Exception:
        logger.error("Training data request failed")
        raise HTTPException(502, "Не удалось получить обучающую выборку") from None


def fit_model(samples: list[TrainingSample]):
    counts = Counter(sample.category for sample in samples)
    if len(counts) < 2 or min(counts.values()) < 3:
        raise HTTPException(422, "Нужны минимум две категории и три проверенные заявки в каждой")
    texts = [sample.text for sample in samples]
    labels = [sample.category for sample in samples]
    test_size = max(len(counts), math.ceil(len(samples) * 0.25))
    train_x, test_x, train_y, test_y = train_test_split(
        texts, labels, test_size=test_size, stratify=labels, random_state=42,
    )
    classifier = make_pipeline(
        TfidfVectorizer(analyzer="char_wb", ngram_range=(3, 5)),
        LogisticRegression(max_iter=1000, random_state=42),
    )
    classifier.fit(train_x, train_y)
    score = float(f1_score(test_y, classifier.predict(test_x), average="macro", zero_division=0))
    classifier.fit(texts, labels)
    metadata = {
        "samples": len(samples), "macro_f1": score,
        "trained_at": datetime.now(timezone.utc).isoformat(),
    }
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=model_path.parent, suffix=".joblib", delete=False) as file:
            temporary = Path(file.name)
        joblib.dump({"model": classifier, **metadata}, temporary)
        os.replace(temporary, model_path)
    finally:
        if temporary:
            temporary.unlink(missing_ok=True)
    logger.info("Classification model trained")
    return metadata


@contextmanager
def training_lock():
    model_path.parent.mkdir(parents=True, exist_ok=True)
    lock = model_path.with_suffix(".lock").open("a+b")
    try:
        if os.name == "nt":
            import msvcrt

            if lock.tell() == 0:
                lock.write(b"0")
                lock.flush()
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        lock.close()
        raise HTTPException(409, "Обучение уже выполняется") from None
    try:
        yield
    finally:
        # Closing the file also releases the OS lock after errors or process exit.
        lock.close()


@app.post("/train", dependencies=[Depends(require_admin)])
def train():
    with training_lock():
        return fit_model(training_data())
