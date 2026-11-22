FROM python:3.14-slim
WORKDIR /app
COPY src/common src/common
COPY src/tickets src/tickets
RUN pip install --no-cache-dir -r src/tickets/requirements.txt
ENV PYTHONUNBUFFERED=1
CMD ["uvicorn", "src.tickets.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
