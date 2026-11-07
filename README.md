# minimax-h3-image-h100-public-hopper

# MiniMax H3 Turbo + Krea 2 Refiner (H100 Hopper Serverless)

RunPod Serverless Worker для высокоскоростной генерации изображений на архитектуре NVIDIA Hopper (H100 SXM, `sm_90`).

### Пример входного payload:
```json
{
  "input": {
    "prompt": "cinematic photography, portrait of a character, dramatic lighting, 8k",
    "aspect_ratio": "16:9",
    "megapixels": 4.0,
    "enable_krea_refiner": true,
    "user_id": "1",
    "image_urls": []
  }
}
