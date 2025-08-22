# Swarm Cleanup

This repository provides Bash utilities for deploying stacks and cleaning up unused Docker
images in Swarm environments.

`scripts/cleanup.sh` removes unused Docker images and containers from a node. It works on
both standalone Docker hosts and Swarm nodes. When executed on a Swarm manager it also
protects images referenced by Swarm services.

## Requirements

- Bash
- Docker CLI available in `PATH`
- Docker daemon reachable (and Swarm mode if you want service protections)

## Usage

Run the script locally by providing the target repository via positional argument or the
`IMAGE_REPO` environment variable:

```bash
# using positional argument
./scripts/cleanup.sh myorg/myimage

# or using environment variable
IMAGE_REPO=myorg/myimage ./scripts/cleanup.sh
```

Set `DRY_RUN=1` to preview deletions without removing anything:

```bash
IMAGE_REPO=myorg/myimage DRY_RUN=1 ./scripts/cleanup.sh
```

`RM_TIMEOUT` configures a timeout for each `docker rmi`/untag command (default `20s`).
The script exits with an error if `IMAGE_REPO` is not specified.

## Deploying a stack

`scripts/deploy_stack.sh` deploys or updates a Docker Swarm stack and then runs the cleanup
routine to remove unused images.

```bash
IMAGE_REPO=myorg/myimage \\
STACK_NAME=feedmama \\
STACK_FILE=/path/to/stack.yml \\
./scripts/deploy_stack.sh
```

The script pulls the specified image, deploys the stack (or updates existing services),
and invokes `swarm_image_cleanup.sh` once the deployment is complete.

## Running in Docker Swarm

The repository also includes tooling to clean every node in a Swarm cluster.

### Option 1: Convenience script

Use `scripts/swarm_image_cleanup.sh` to deploy a temporary stack, wait for all cleanup tasks to finish, and then remove the stack automatically:

```bash
IMAGE_REPO=myorg/myimage ./scripts/swarm_image_cleanup.sh
```

The script uses `docker/docker-cleaner-stack.yml` to run a one-shot global service that executes `cleanup.sh` on each node.

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

Contributions are welcome. Please run `bash -n scripts/*.sh` before submitting changes.

## License

This project is provided under the MIT License.
