# Swarm Cleanup

Simple Bash utilities for managing Docker Swarm stacks and cleaning up unused images.

## Requirements

- Bash
- Docker CLI available in your `PATH`
- Access to a Docker daemon in Swarm mode

## Quick Start

1. **Clone the repo**

   ```bash
   git clone https://github.com/your-org/swarm_cleanup.git
   cd swarm_cleanup
   ```

2. **Prepare your stack file**

   Use an existing Docker Compose file or create one for the services you want to run.

3. **Set environment variables**

   ```bash
   export IMAGE_REPO=myorg/myimage
   export STACK_NAME=my_stack
   export STACK_FILE=/path/to/stack.yml
   ```

   Alternatively, you can specify these variables inline when running the deployment command.

4. **Deploy the stack and clean up old images**

   ```bash
   IMAGE_REPO=myorg/myimage \
   STACK_NAME=my_stack \
   STACK_FILE=/path/to/stack.yml \
   bash ./deploy_and_cleanup.sh
   ```

   The script deploys or updates your stack, then removes unused images across the cluster.

## Additional Scripts

- **Clean images on the current node**
  ```bash
  IMAGE_REPO=myorg/myimage ./scripts/cleanup_docker_images.sh
  ```
  Set `DRY_RUN=1` to preview deletions.

- **Run cleanup on every Swarm node**
  ```bash
  IMAGE_REPO=myorg/myimage ./scripts/run_swarm_cleanup.sh
  ```
  Optional variables:
  - `STACK_FILE` path to stack file (default `docker/cleanup-stack.yml`)
  - `STACK_NAME` name for the temporary stack (default `swarm-cleanup`)

- **Roll back to a previous image digest**
  ```bash
  STACK_NAME=my_stack IMAGE_REPO=myorg/myimage ./scripts/manual_rollback.sh
  ```

- **Ensure repo and deploy**
  Clone or update this repo and run `deploy_and_cleanup.sh` in one step:
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
