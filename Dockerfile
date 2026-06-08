FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV UV_SYSTEM_PYTHON=1

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY research/requirements.txt /app/research/requirements.txt
COPY quant_research/requirements.txt /app/quant_research/requirements.txt

RUN pip install --no-cache-dir -r /app/research/requirements.txt \
    && pip install --no-cache-dir -r /app/quant_research/requirements.txt

COPY quant_research /app/quant_research
COPY config /app/config
COPY research /app/research

ENTRYPOINT ["python", "-m", "quant_research.cli"]
