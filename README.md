# Swarm Cleanup

`cleanup.sh` is a small Bash utility that removes unused Docker images and containers from a node. It works on standalone Docker hosts and Swarm nodes. When run on a Swarm manager it protects images that are in use by services.

## Requirements

- Bash
- Docker CLI available in `PATH`
- Docker daemon reachable (and Swarm mode if you want service protections)

## Usage

Provide the target repository via positional argument or `IMAGE_REPO` environment variable:

```bash
# using positional argument
./cleanup.sh myorg/myimage

# or using environment variable
IMAGE_REPO=myorg/myimage ./cleanup.sh
```

Set `DRY_RUN=1` to preview deletions without removing anything:

```bash
IMAGE_REPO=myorg/myimage DRY_RUN=1 ./cleanup.sh
```

`RM_TIMEOUT` configures a timeout for each `docker rmi`/untag command (default `20s`).

The script exits with an error if `IMAGE_REPO` is not specified.

## Running in Docker Swarm

To clean up every node in a Swarm cluster you can deploy `cleanup.sh` as a
one-shot global service. A sample stack file is provided at
`docker/docker-cleaner-stack.yml`.

1. Set the image repository you want to purge and deploy the stack:

   ```bash
   IMAGE_REPO=myorg/myimage docker stack deploy \
     -c docker/docker-cleaner-stack.yml swarm-cleanup
   ```

   The service will run once on each node, remove unused images matching the
   repository and then exit.

2. After all tasks complete, remove the stack:

   ```bash
   docker stack rm swarm-cleanup
   ```

The stack file clones this repository on each node at run time so you do not
need to pre-distribute the script.

## Development

Contributions are welcome. Please run `bash -n cleanup.sh` before submitting changes.

## License

This project is provided under the MIT License.
