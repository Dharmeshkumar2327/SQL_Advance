# Convenience targets. Run `make help` to list them.
PGHOST     ?= localhost
PGPORT     ?= 5432
PGUSER     ?= postgres
PGDATABASE ?= upi_fraud
PSQL        = psql -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d $(PGDATABASE) -q
PYTHON     ?= python3

.PHONY: help install db data data-small pipeline rules tune investigate perf dashboard charts docker-up docker-run clean

help:          ## show this help
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*## "}{printf "  %-14s %s\n", $$1, $$2}'

install:       ## install Python dependencies
	$(PYTHON) -m pip install -r requirements.txt

db:            ## create the database if missing
	@psql -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$(PGDATABASE)'" | grep -q 1 \
	  || psql -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d postgres -c "CREATE DATABASE $(PGDATABASE)"

data:          ## generate the full synthetic dataset (~590k txns)
	$(PYTHON) data_generator/generate_data.py

data-small:    ## generate a small dataset (~120k txns)
	$(PYTHON) data_generator/generate_data.py --accounts 10000 --txns 120000

pipeline: db   ## load data + run all rules, scoring, evaluation, tests, export
	@mkdir -p dashboard/data
	$(PSQL) -f sql/run_all.sql

rules:         ## re-run rules on already-loaded data (after changing fraud.rule_config)
	$(PSQL) -v skip_load=1 -f sql/run_all.sql

tune:          ## R02 before/after tuning experiment
	$(PSQL) -f sql/60_analyst_toolkit/01_rule_tuning_r02.sql

investigate:   ## case file for the riskiest account (or: make investigate ACCOUNT=123)
	$(PSQL) $(if $(ACCOUNT),-v account_id=$(ACCOUNT)) -f sql/60_analyst_toolkit/02_investigate_account.sql

perf:          ## EXPLAIN ANALYZE with vs without index
	$(PSQL) -f sql/60_analyst_toolkit/03_query_performance.sql

dashboard:     ## launch the Streamlit dashboard
	streamlit run dashboard/app.py

charts:        ## re-render the README charts
	$(PYTHON) scripts/make_readme_charts.py

docker-up:     ## start PostgreSQL in Docker
	docker compose up -d --wait

docker-run: docker-up data  ## run the whole pipeline inside the Docker container
	docker compose exec -w /workspace db psql -U postgres -d upi_fraud -q -f sql/run_all.sql

clean:         ## delete generated raw data (keeps dashboard/data)
	rm -rf data/
