.PHONY: help setup clean gateway gateway-basic gateway-experimental deploy-gateway up down logs logs-experimental jwt-tokens test run-experimental stop-experimental

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: jwt-tokens gateway-basic deploy-gateway ## Full setup: tokens, basic gateway, start

jwt-tokens: ## Generate JWT tokens and JWKS
	@echo "Generating JWT tokens..."
	@./jwt/generate.sh

gateway-basic: ## Build BASIC gateway (pull released image, minimal proxy config)
	@./build/build-basic.sh

gateway-experimental: ## Build EXPERIMENTAL gateway on the HOST (compile experimental-ratelimit)
	@./build/build-experimental.sh

run-experimental: ## Start host experimental gateway + supporting compose services
	@./build/run-experimental.sh start

stop-experimental: ## Stop host experimental gateway + supporting compose services
	@./build/run-experimental.sh stop

gateway: gateway-basic ## Alias for gateway-basic (the default build)

deploy-gateway: down up ## Stop and start gateway (restart with current image)
	@echo "Gateway running at http://localhost:8080"
	@echo "Metrics at http://localhost:9901/metrics"

up: ## Start all services
	@echo "Starting services..."
	@docker compose up -d

down: ## Stop all services
	@docker compose down

logs: ## Tail praxis-gateway logs (basic/docker gateway)
	@docker compose logs -f praxis-gateway

logs-experimental: ## Tail the host experimental gateway log
	@tail -f gateway-local.log

clean: ## Stop and remove all containers, networks, volumes
	@echo "Cleaning up..."
	@docker compose down -v

test: ## Run tests for current configuration (reads .env for PRAXIS_CONFIG)
	@set -a; [ -f .env ] && . ./.env; set +a; ./test/run-all.sh
