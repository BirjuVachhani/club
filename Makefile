.PHONY: help build run stop logs clean dev docs analyze test

IMAGE  ?= club
TAG    ?= dev
PORT   ?= 10234
NAME   ?= club-dev

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

# ── Docker ──────────────────────────────────────────────────

build: ## Build the Docker image
	docker build -f docker/Dockerfile -t $(IMAGE):$(TAG) .

run: ## Run the container (uses .env.dev)
	docker compose -f docker-compose.dev.yml up -d

stop: ## Stop the container
	docker compose -f docker-compose.dev.yml down

logs: ## Tail container logs
	docker logs -f $(NAME)

clean: stop ## Stop AND permanently delete the club_data volume (prompts for confirmation)
	@echo ""
	@echo "WARNING: this will permanently delete the 'club_data' volume"
	@echo "         (SQLite DB + published tarballs)."
	@echo ""
	@read -p "Type 'yes' to confirm: " CONFIRM; \
	if [ "$$CONFIRM" = "yes" ]; then \
	  docker volume rm club_data 2>/dev/null || true; \
	  echo "Volume removed."; \
	else \
	  echo "Aborted. Nothing changed."; \
	fi

# ── Local dev (no Docker) ──────────────────────────────────

dev: ## Run Dart server + SvelteKit dev server (empty DB)
	./scripts/dev-server.sh

dev-dummy: ## Run dev server with pre-seeded dummy data
	./scripts/dev-server.sh --dummy

seed: ## (Re)generate dummy data from pub.dev
	./dummy_data/seed.sh

# ── Docs site ──────────────────────────────────────────────

docs: ## Build and preview the docs site
	cd sites/docs && npm run build && npm run preview

docs-dev: ## Run docs site in dev mode
	cd sites/docs && npm run dev

# ── Code quality ───────────────────────────────────────────

analyze: ## Analyze all Dart packages
	@for pkg in club_core club_db club_storage club_server club_api club_cli; do \
		echo "=== $$pkg ==="; \
		dart analyze packages/$$pkg; \
	done

test: ## Run all Dart tests
	@for pkg in club_core club_db club_storage club_server club_api club_cli; do \
		echo "=== $$pkg ==="; \
		cd packages/$$pkg && dart test 2>/dev/null || true; \
		cd ../..; \
	done

codegen: ## Run build_runner code generation
	cd packages/club_core && dart run build_runner build --delete-conflicting-outputs

web-build: ## Build the SvelteKit frontend
	cd packages/club_web && npm run build

web-install: ## Install frontend dependencies
	cd packages/club_web && npm install

deps: ## Install all dependencies
	dart pub get
	cd packages/club_web && npm install
	cd sites/docs && npm install
