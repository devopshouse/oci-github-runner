# 🚀 Makefile to build the GitHub Runner Docker image with the OCI CLI 🚀

# 🔧 Variables
SHELL := /bin/bash
DOCKER_REGISTRY ?= ghcr.io
GITHUB_REPOSITORY ?= $(shell git config --get remote.origin.url | sed -e 's/.*github.com[:/]\([^/]*\/[^/]*\).*/\1/' | sed -e 's/\.git$$//')
IMAGE_NAME ?= $(DOCKER_REGISTRY)/$(GITHUB_REPOSITORY)
UBUNTU_VERSION ?= ubuntu-noble

# 📦 Reads the runner version from .tool-versions
RUNNER_VERSION := $(shell grep "github-runner" .tool-versions | awk '{print $$2}')

# 🎨 Output colors
COLOR_RESET=\033[0m
COLOR_GREEN=\033[32m
COLOR_YELLOW=\033[33m
COLOR_BLUE=\033[34m

.PHONY: help build push build-push

# 🎯 Default target
.DEFAULT_GOAL := help

# 📚 Shows help
help:
	@echo -e "$(COLOR_GREEN)🚀 Makefile to build the GitHub Runner Docker image with the OCI CLI 🚀$(COLOR_RESET)"
	@echo -e "$(COLOR_YELLOW)✨ Usage:$(COLOR_RESET)"
	@echo -e "  $(COLOR_BLUE)make build$(COLOR_RESET)      - 🏗️  Builds the Docker image"
	@echo -e "  $(COLOR_BLUE)make push$(COLOR_RESET)       - 📤 Pushes the image to the registry"
	@echo -e "  $(COLOR_BLUE)make build-push$(COLOR_RESET) - 🚢 Builds and pushes the image to the registry"
	@echo -e "  $(COLOR_BLUE)make help$(COLOR_RESET)       - 💡 Shows this help message"
	@echo -e "$(COLOR_YELLOW)🔍 Variables:$(COLOR_RESET)"
	@echo -e "  $(COLOR_BLUE)RUNNER_VERSION$(COLOR_RESET)  = 🏷️  $(RUNNER_VERSION) (read from .tool-versions)"
	@echo -e "  $(COLOR_BLUE)UBUNTU_VERSION$(COLOR_RESET)  = 🐧 $(UBUNTU_VERSION)"
	@echo -e "  $(COLOR_BLUE)IMAGE_NAME$(COLOR_RESET)      = 🖼️  $(IMAGE_NAME)"

# 🏗️ Builds the Docker image
build:
	@echo -e "$(COLOR_GREEN)🚀 Building Docker image for GitHub Runner version $(RUNNER_VERSION)...$(COLOR_RESET)"
	docker build \
		--build-arg RUNNER_VERSION=$(RUNNER_VERSION) \
		--build-arg UBUNTU_VERSION=$(UBUNTU_VERSION) \
		-t $(IMAGE_NAME):latest \
		-t $(IMAGE_NAME):$(RUNNER_VERSION) \
		.
	@echo -e "$(COLOR_GREEN)✅ Image built successfully! 🎉$(COLOR_RESET)"

# 📤 Pushes the image to the registry
push:
	@echo -e "$(COLOR_GREEN)🔄 Pushing Docker image to the registry...$(COLOR_RESET)"
	docker push $(IMAGE_NAME):latest
	docker push $(IMAGE_NAME):$(RUNNER_VERSION)
	@echo -e "$(COLOR_GREEN)✨ Image pushed successfully! 🚀$(COLOR_RESET)"

# 🚢 Builds and pushes the image
build-push: build push
	@echo -e "$(COLOR_GREEN)🎯 Build and push complete! 🎊$(COLOR_RESET)"
