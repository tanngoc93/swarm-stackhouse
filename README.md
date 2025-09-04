# Swarm Cleanup

Utilities for deploying Docker Swarm stacks and removing unused Docker images.
All scripts are written in Bash and include comments for easy maintenance.

## Requirements

- Bash
- Docker CLI available in `PATH`
- Access to a running Docker daemon (Swarm mode optional)

## Script overview

| Script | Description |
|-------|-------------|
| `scripts/cleanup_docker_images.sh` | Remove unused Docker images and containers on a node. |
| `scripts/run_swarm_cleanup.sh` | Deploy a temporary stack that runs the cleanup script on every Swarm node. |
| `deploy_and_cleanup.sh` | Deploy or update a Swarm stack, then trigger a cluster-wide cleanup. |
| `ensure_swarm_cleanup_and_deploy.sh` | Ensure this repo exists locally and run `deploy_and_cleanup.sh` with your configuration. |

## Usage

### 1. Clean images on the current node

```bash
IMAGE_REPO=myorg/myimage ./scripts/cleanup_docker_images.sh
```

Set `DRY_RUN=1` to preview deletions:

```bash
IMAGE_REPO=myorg/myimage DRY_RUN=1 ./scripts/cleanup_docker_images.sh
```

### 2. Run cleanup on every Swarm node

```bash
IMAGE_REPO=myorg/myimage ./scripts/run_swarm_cleanup.sh
```

Optional variables:
- `STACK_FILE` path to stack file (default `docker/cleanup-stack.yml`)
- `STACK_NAME` name for the temporary stack (default `swarm-cleanup`)

### 3. Deploy a stack and clean up old images

```bash
IMAGE_REPO=myorg/myimage \
STACK_NAME=my_stack \
STACK_FILE=/path/to/stack.yml \
./deploy_and_cleanup.sh
```

### 4. Ensure repo and deploy

`ensure_swarm_cleanup_and_deploy.sh` clones/updates this repository and runs `deploy_and_cleanup.sh`.
Provide your stack details via environment variables:

```bash
IMAGE_REPO=myorg/myimage \
STACK_NAME=my_stack \
STACK_FILE=/root/docker/app-stack.yml \
./ensure_swarm_cleanup_and_deploy.sh /root/run/swarm_cleanup main
```

## Development

Run basic syntax checks before submitting changes:

```bash
bash -n deploy_and_cleanup.sh scripts/*.sh ensure_swarm_cleanup_and_deploy.sh
```

## License

This project is provided under the MIT License.
