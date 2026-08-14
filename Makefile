.PHONY: install test seed api ui mcp lint

install:
	pip install -r requirements.txt
	pip install -e .

test:
	pytest -q

seed:
	bash scripts/setup_minio_buckets.sh
	python scripts/seed_dataset.py

api:
	python -m src.services.api

ui:
	streamlit run src/ui/app.py --server.port=8501

mcp:
	python -m src.agent.mcp_gateway

lint:
	ruff check src tests scripts
