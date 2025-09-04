# Swarm Cleanup

Công cụ nhỏ gọn giúp triển khai stack lên Docker Swarm và dọn dẹp các image không còn sử dụng.

## Yêu cầu

- Docker đã cài đặt và bật chế độ Swarm
- Có quyền chạy lệnh Docker
- Bash

## Cấu hình

1. **Tạo file stack**  
   Viết file mô tả stack của bạn, ví dụ: `/root/docker/app-stack.yml`.

2. **Khai báo biến môi trường**  
   Đặt thông tin cho stack và image sẽ triển khai:

   ```bash
   export IMAGE_REPO=myorg/myimage        # bắt buộc
   export STACK_NAME=my_stack             # bắt buộc
   export STACK_FILE=/root/docker/app-stack.yml  # bắt buộc
   export IMAGE_TAG=latest                # tùy chọn, mặc định latest
   ```

## Chạy deploy và cleanup

### Đã có repo local

Trong thư mục chứa repo, chạy:

```bash
IMAGE_REPO=$IMAGE_REPO \
STACK_NAME=$STACK_NAME \
STACK_FILE=$STACK_FILE \
IMAGE_TAG=${IMAGE_TAG:-latest} \
./deploy_and_cleanup.sh
```

### Chưa có repo local

`ensure_swarm_cleanup_and_deploy.sh` sẽ tự clone hoặc cập nhật repo rồi chạy deploy:

```bash
IMAGE_REPO=$IMAGE_REPO \
STACK_NAME=$STACK_NAME \
STACK_FILE=$STACK_FILE \
IMAGE_TAG=${IMAGE_TAG:-latest} \
./ensure_swarm_cleanup_and_deploy.sh /root/run/swarm_cleanup main
```

Script sẽ clone repo (nếu cần), triển khai stack, chờ 30 giây rồi dọn dẹp image cũ trên toàn cluster.

## Kiểm tra

Sau khi chỉnh sửa mã, chạy kiểm tra cú pháp:

```bash
bash -n deploy_and_cleanup.sh scripts/*.sh ensure_swarm_cleanup_and_deploy.sh
```

## Giấy phép

MIT License

