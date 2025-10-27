#!/usr/bin/env bash

# 1. Clean up all unused build cache to ensure space and a fresh environment
echo "Pruning all unused Docker build cache..."
docker builder prune --all --force

# 2. Perform the multi-platform/advanced build using docker buildx bake
# NOTE: Replace 'my-target' with the actual target name defined in your build config file (e.g., docker-compose.yml)
echo "Starting Docker Buildx bake process..."
docker buildx bake
