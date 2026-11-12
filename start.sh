#!/bin/bash

echo "=== Setting up models directory ==="

if [ -d "/runpod-volume/ComfyUI/models" ]; then
    echo "Found models in /runpod-volume/ComfyUI/models. Creating symlink..."
    rm -rf /workspace/ComfyUI/models
    ln -s /runpod-volume/ComfyUI/models /workspace/ComfyUI/models
elif [ -d "/runpod-volume/models" ]; then
    echo "Found models in /runpod-volume/models. Creating symlink..."
    rm -rf /workspace/ComfyUI/models
    ln -s /runpod-volume/models /workspace/ComfyUI/models
else
    echo "WARNING: Models directory not found in /runpod-volume!"
fi

echo "Models linked status:"
ls -la /workspace/ComfyUI/models || true

# 1. Архитектура CUDA под NVIDIA H100 SXM (Hopper sm_90)
export TORCH_CUDA_ARCH_LIST="9.0"
export CUDA_ARCH="90"
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"

# 2. Патч SageAttention под Hopper (sm90)
python3 -c '
path = "/workspace/ComfyUI/custom_nodes/ComfyUI-KJNodes/nodes/ltxv_nodes.py"
try:
    with open(path, "r", encoding="utf-8") as f:
        code = f.read()
    code = code.replace("if _cuda_archs is None:", "if False:")
    code = code.replace("_cuda_archs[0]", "\"sm90\"")
    with open(path, "w", encoding="utf-8") as f:
        f.write(code)
    print("Successfully patched Kijai SageAttention for sm90 (H100)!")
except Exception as e:
    print(f"Patch warning: {e}")
' || true

# 3. Патч для Krea 2 Refiner (MXFP8) и безопасный запуск SageAttention
python3 -c '
ops_path = "/workspace/ComfyUI/comfy/ops.py"
try:
    with open(ops_path, "r", encoding="utf-8") as f:
        code = f.read()
    if "torch.float8_e8m0fnu" in code:
        code = code.replace("torch.float8_e8m0fnu", "getattr(torch, \"float8_e8m0fnu\", torch.uint8)")
    with open(ops_path, "w", encoding="utf-8") as f:
        f.write(code)
    print("Successfully patched comfy/ops.py!")
except Exception as e:
    print(f"Ops patch warning: {e}")

float_path = "/workspace/ComfyUI/comfy/float.py"
try:
    with open(float_path, "r", encoding="utf-8") as f:
        code = f.read()
    if "torch.float8_e8m0fnu" in code:
        code = code.replace("torch.float8_e8m0fnu", "getattr(torch, \"float8_e8m0fnu\", torch.uint8)")
    with open(float_path, "w", encoding="utf-8") as f:
        f.write(code)
    print("Successfully patched comfy/float.py!")
except Exception as e:
    print(f"Float patch warning: {e}")

kitchen_sage = "/usr/local/lib/python3.11/dist-packages/comfy_kitchen/sage_attention.py"
try:
    with open(kitchen_sage, "r", encoding="utf-8") as f:
        code = f.read()

    attn_override = (
        "def int8_attention(query, key, value, *args, **kwargs):\n"
        "    import torch.nn.functional as F\n"
        "    return F.scaled_dot_product_attention(query, key, value)\n\n"
        "def _orig_int8_attention("
    )

    if "def int8_attention(" in code and "_orig_int8_attention" not in code:
        code = code.replace("def int8_attention(", attn_override)
        print("Successfully bypassed int8_attention to PyTorch SDPA in start.sh!")

    with open(kitchen_sage, "w", encoding="utf-8") as f:
        f.write(code)
except Exception as e:
    print(f"Kitchen Sage patch warning: {e}")

site_path = "/usr/local/lib/python3.11/dist-packages/sitecustomize.py"
try:
    with open(site_path, "w", encoding="utf-8") as f:
        f.write("import torch\nif not hasattr(torch, \"float8_e8m0fnu\"):\n    torch.float8_e8m0fnu = torch.uint8\n")
    print("Successfully created sitecustomize.py for PyTorch MXFP8!")
except Exception as e:
    print(f"Sitecustomize warning: {e}")
' || true

# 4. Запуск ComfyUI в фоне (БЕЗ --novram, все модели остаются в 80GB VRAM H100)
cd /workspace/ComfyUI
python -u main.py --listen 127.0.0.1 --port 8188 --disable-dynamic-vram > /workspace/comfyui.log 2>&1 &
COMFY_PID=$!

echo "Waiting for ComfyUI and custom nodes to initialize (PID: $COMFY_PID)..."
while true; do
    if ! kill -0 $COMFY_PID 2>/dev/null; then
        echo "=========================================="
        echo "ERROR: ComfyUI crashed! Dumping log:"
        echo "=========================================="
        cat /workspace/comfyui.log
        echo "=========================================="
        sleep 60
        exit 1
    fi

    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8188/object_info/easy%20seed")
    if [ "$STATUS" -eq 200 ]; then
        echo "ComfyUI and ComfyUI-Easy-Use are fully loaded and ready on H100!"
        break
    fi
    sleep 2
done

# Выводим в консоль предупреждения и ошибки импорта кастомных нод
echo "=== Checking ComfyUI log for custom node errors ==="
grep -iE "error|failed|cannot import|traceback" /workspace/comfyui.log || echo "No critical import errors found."
echo "==================================================="

# 5. Запуск RunPod Serverless Handler
python -u rp_handler.py
