# Swarm Stackhouse

Simple Bash utilities for managing Docker Swarm stacks and cleaning up unused images.

## Step-by-Step Setup

1. **Generate a deployment script**

   Run `./setup.sh` and provide:

   - `IMAGE_REPO` – container image repository
   - `STACK_NAME` – stack name
   - `STACK_FILE` – path to the stack file

   A script named `deploy_<STACK_NAME>_<timestamp>.sh` will be created in the current directory with these values embedded.

2. **Optional: create a manual rollback script**

   To roll back manually, create another script (e.g. `rollback_swarm.sh`) containing:

   ```bash
   IMAGE_REPO=myorg/myapp STACK_NAME=app_stack bash /tmp/swarm-stackhouse/scripts/manual_rollback.sh
   ```

   Make it executable with `chmod +x rollback_swarm.sh`.

3. **Run the deployment**

   After everything is set up, run the deployment from the terminal:

   ```bash
   IMAGE_TAG=v1 ./deploy_<STACK_NAME>_<timestamp>.sh
   ```

   The script clones or updates this repository at `/tmp/swarm-stackhouse`, deploys the specified stack, and removes unused images across the cluster. You can override the `IMAGE_TAG` environment variable when running the script (default: `latest`).

## Requirements

- Bash
- Docker CLI available in your `PATH`
- Access to a Docker daemon in Swarm mode

## Development

Run basic syntax checks before submitting changes:

```bash
bash -n scripts/*.sh stackhouse_deploy_and_clean.sh setup.sh
```

## License

This project is provided under the MIT License.
