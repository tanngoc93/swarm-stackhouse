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

## Development

Contributions are welcome. Please run `bash -n cleanup.sh` before submitting changes.

## License

This project is provided under the MIT License.
