FROM python:3.14-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY src/common src/common
COPY src/classification src/classification
RUN pip install --no-cache-dir -r src/classification/requirements.txt
CMD ["uvicorn", "src.classification.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
