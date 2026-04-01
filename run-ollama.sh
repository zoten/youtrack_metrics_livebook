#!/bin/bash

set -e

# if Ollama is bound only to 127.0.0.1, the container cannot reach it
export OLLAMA_HOST=0.0.0.0:11434
ollama run qcwind/qwen2.5-7B-instruct-Q4_K_M
