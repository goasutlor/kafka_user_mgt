# Source from ~/.bashrc (adjust paths + container name):
#
#   source /path/to/kafka_user_mgt/scripts/gen-cli-aliases.example.sh
#
# Or copy the alias lines only.

export KGEN_REPO="${KGEN_REPO:-$HOME/kafka_user_mgt}"   # clone path on host
export CONTAINER_NAME="${CONTAINER_NAME:-kafka-user-mgmt}"

# Single entry: menu + optional env as first arg (see scripts/gen-cli.sh --help)
alias kgen='bash "$KGEN_REPO/scripts/gen-cli.sh"'

# One alias per env — same engine, zero chance of mixing OCP/Kafka targets
alias kgen-dev='bash "$KGEN_REPO/scripts/gen-cli.sh" dev'
alias kgen-sit='bash "$KGEN_REPO/scripts/gen-cli.sh" sit'
alias kgen-uat='bash "$KGEN_REPO/scripts/gen-cli.sh" uat'

# If your master.config uses full ids (e.g. esb-dev-cwdc), add matching aliases:
# alias kgen-dev='bash "$KGEN_REPO/scripts/gen-cli.sh" esb-dev-cwdc'
