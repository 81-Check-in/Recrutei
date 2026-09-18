FROM python:3.11-slim

# OCR de currículos escaneados: Tesseract (português) e Poppler (PDF → imagem)
RUN apt-get update \
    && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-por poppler-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Roda uma vez e encerra; o agendamento é o Cron Schedule do Railway.
CMD ["python", "main.py"]
