# Swarm Cleanup

This repository provides Bash utilities for deploying stacks and cleaning up unused Docker
images in Swarm environments.

`scripts/docker_image_cleanup.sh` removes unused Docker images and containers from a node.
It works on both standalone Docker hosts and Swarm nodes. When executed on a Swarm manager
it also protects images referenced by Swarm services.

## Requirements

- Bash
- Docker CLI available in `PATH`
- Docker daemon reachable (and Swarm mode if you want service protections)

## Usage

Run the script locally by providing the target repository via the `IMAGE_REPO`
environment variable:

```bash
IMAGE_REPO=myorg/myimage ./scripts/docker_image_cleanup.sh
```

Set `DRY_RUN=1` to preview deletions without removing anything:

```bash
IMAGE_REPO=myorg/myimage DRY_RUN=1 ./scripts/docker_image_cleanup.sh
```

`RM_TIMEOUT` configures a timeout for each `docker rmi`/untag command (default `20s`).
The script exits with an error if `IMAGE_REPO` is not specified.

## Deploying a stack

`scripts/deploy_stack_with_cleanup.sh` deploys or updates a Docker Swarm stack and then runs the cleanup
routine to remove unused images. It requires `IMAGE_REPO`, `STACK_NAME`, `STACK_FILE`,
`CLEANUP_STACK_FILE`, and `CLEANUP_STACK_NAME` environment variables.

```bash
IMAGE_REPO=myorg/myimage \\
STACK_NAME=feedmama \\
STACK_FILE=/path/to/stack.yml \\
CLEANUP_STACK_FILE=docker/docker-cleaner-stack.yml \\
CLEANUP_STACK_NAME=swarm-cleanup \\
./scripts/deploy_stack_with_cleanup.sh
```

The script pulls the specified image, deploys the stack (or updates existing services),
and invokes `swarm_cleanup.sh` once the deployment is complete.

## Running in Docker Swarm

The repository also includes tooling to clean every node in a Swarm cluster.

### Option 1: Convenience script

Use `swarm_cleanup.sh` to deploy a temporary stack, wait for all cleanup tasks to finish, and then remove the stack automatically. It requires `IMAGE_REPO`, `STACK_FILE`, and `STACK_NAME` environment variables:

```bash
IMAGE_REPO=myorg/myimage STACK_FILE=docker/docker-cleaner-stack.yml STACK_NAME=swarm-cleanup ./swarm_cleanup.sh
```

The stack file runs `scripts/docker_image_cleanup.sh` on each node.

### Option 2: Manual stack deployment

If you prefer manual control you can deploy the stack yourself:

```bash
IMAGE_REPO=myorg/myimage docker stack deploy \
  -c docker/docker-cleaner-stack.yml swarm-cleanup

# after the tasks are finished
docker stack rm swarm-cleanup
```

The stack file clones this repository on each node at run time so you do not need to pre-distribute the script.

## Development

Contributions are welcome. Please run `bash -n scripts/*.sh swarm_cleanup.sh` before submitting changes.

## License

This project is provided under the MIT License.
