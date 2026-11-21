# Two images from one file:
#   runtime (the last stage: what Fly builds): the server only, run as a user with no rights;
#   test (docker-compose.yml builds this one): the same, plus pytest and the tests, for `npm run proc:test` and the
#     browser tests' local processing server.
FROM python:3.12-slim AS base
WORKDIR /app
ENV PYTHONPATH=/app
COPY requirements.lock .
RUN pip install --no-cache-dir --require-hashes -r requirements.lock
# The server never runs as root: it only calls out to Supabase and writes its temporary files to /tmp.
RUN useradd --system --uid 10001 --no-create-home processor
COPY processor/ processor/

FROM base AS test
COPY requirements-test.lock .
RUN pip install --no-cache-dir --require-hashes -r requirements-test.lock
COPY tests/ tests/
# pytest keeps its cache beside the tests.
RUN mkdir -p /app/.pytest_cache && chown processor /app/.pytest_cache
USER processor
CMD ["pytest", "-q"]

FROM base AS runtime
USER processor
CMD ["python", "-m", "processor.main"]
