FROM python:3.14-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY src/common src/common
COPY src/analytics src/analytics
RUN pip install --no-cache-dir -r src/analytics/requirements.txt
CMD ["uvicorn", "src.analytics.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
