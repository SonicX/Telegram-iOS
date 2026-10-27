FROM python:3.12-slim
RUN pip install --no-cache-dir telethon==1.36.0
WORKDIR /app
COPY relay.py .
CMD ["python", "relay.py"]
