FROM python:3.11-slim

# OCR de currículos escaneados: Tesseract (português) e Poppler (PDF → imagem)
RUN apt-get update \
    && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-por poppler-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Fica ligado: os pedidos do RH (tentar de novo, currículo enviado, reanálise) saem em até ~30 s e a caixa de e-mail é lida no
# intervalo e na janela de Configurações (padrão: a cada 10 min, seg a sáb, 07:30 às 18:00). No Railway deixe o Cron Schedule VAZIO.
# Prefere o Cron Schedule? Troque por ["python", "main.py", "--agendada"] e use "*/5 * * * *" (o mínimo do Railway).
CMD ["python", "main.py", "--continuo"]
