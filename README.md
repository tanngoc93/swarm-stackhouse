# Swarm Stackhouse

Simple Bash utilities for managing Docker Swarm stacks and cleaning up unused images.

## Step-by-Step Setup

1. **Create a deployment script**

   On the Swarm manager node, create a shell script such as `deploy_swarm.sh` and copy the contents of `ensure_swarm_stackhouse_and_deploy.sh` from this repository into it. Make the script executable:

   ```bash
   chmod +x deploy_swarm.sh
   ```

2. **Configure required environment variables**

   The deployment script uses the following variables. Export them or specify them inline when running:

   - `IMAGE_TAG` – image tag to deploy (default: `latest`)
   - `IMAGE_REPO` – image repo (default: `myorg/myapp`)
   - `STACK_NAME` – stack name (default: `app_stack`)
   - `STACK_FILE` – stack file path (default: `/root/docker/app-stack.yml`)

3. **Optional: create a manual rollback script**

   To roll back manually, create another script (e.g. `rollback_swarm.sh`) containing:

   ```bash
   IMAGE_REPO=myorg/myapp STACK_NAME=app_stack bash /tmp/swarm-stackhouse/manual_rollback.sh
   ```

   Make it executable with `chmod +x rollback_swarm.sh`.

4. **Run the deployment**

   After everything is set up, run the deployment from the terminal:

   ```bash
   IMAGE_TAG=v1 ./deploy_swarm.sh
   ```

   The script clones or updates this repository at `/tmp/swarm-stackhouse`, deploys the specified stack, and removes unused images across the cluster.

## Requirements

- Bash
- Docker CLI available in your `PATH`
- Access to a Docker daemon in Swarm mode

## Development

Run basic syntax checks before submitting changes:

```bash
bash -n deploy_and_cleanup.sh manual_rollback.sh scripts/*.sh ensure_swarm_stackhouse_and_deploy.sh
```

## License

This project is provided under the MIT License.
