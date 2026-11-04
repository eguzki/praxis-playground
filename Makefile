.PHONY: help setup clean gateway deploy-gateway up down logs jwt-tokens test

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: jwt-tokens gateway deploy-gateway ## Full setup: generate tokens, build and start gateway

jwt-tokens: ## Generate JWT tokens and JWKS
	@echo "Generating JWT tokens..."
	@./jwt/generate.sh

gateway: ## Build praxis-gateway with current configuration (.env or environment)
	@echo "Building praxis-gateway..."
	@echo "  Config: $${PRAXIS_CONFIG:-token-rate-limit.yaml}"
	@echo "  Features: $${PRAXIS_FEATURES:-full,token-rate-limit-filter}"
	@docker compose build praxis-gateway

deploy-gateway: down up ## Stop and start gateway (restart with current image)
	@echo "Gateway running at http://localhost:8080"
	@echo "Metrics at http://localhost:9901/metrics"

up: ## Start all services
	@echo "Starting services..."
	@docker compose up -d

down: ## Stop all services
	@docker compose down

logs: ## Tail praxis-gateway logs
	@docker compose logs -f praxis-gateway

clean: ## Stop and remove all containers, networks, volumes
	@echo "Cleaning up..."
	@docker compose down -v

test: ## Run tests for current configuration
	@./test/run-all.sh
