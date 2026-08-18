.PHONY: install test seed check deploy smoke load workbench ui api

install:
	pip install -r requirements.txt
	pip install -e .

test:
	pytest -q

check:
	bash scripts/check_prerequisites.sh

deploy:
	bash scripts/deploy_lab.sh

seed:
	bash scripts/setup_minio_buckets.sh || true
	bash scripts/fetch_dataset.sh || true
	bash scripts/seed_minio.sh

smoke:
	bash scripts/smoke_test.sh

load:
	bash scripts/run_load_test.sh

workbench:
	bash scripts/setup_workbench.sh

api:
	python -m src.services.api

ui:
	streamlit run src/ui/app.py --server.port=8501

discovery:
	python -m src.discovery.api

mcp:
	python -m src.agent.mcp_gateway
