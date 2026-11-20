FROM python:3.12-slim
WORKDIR /app
ENV PYTHONPATH=/app
COPY requirements.lock .
RUN pip install --no-cache-dir --require-hashes -r requirements.lock
COPY processor/ processor/
COPY tests/ tests/
CMD ["python", "-m", "processor.main"]
