# terraform-aws-state-backend

Module tái sử dụng để tạo **S3 remote backend** cho Terraform. Mỗi lần gọi module sẽ tạo một backend tách biệt cho một dự án, gồm bucket, KMS key và IAM policy.

## Tài nguyên tạo ra

| Tài nguyên | Ghi chú |
|---|---|
| S3 bucket | Tên mặc định `<project>-tfstate-<account_id>-<region>` |
| Versioning | Luôn bật, để khôi phục state khi bị hỏng hoặc ghi đè |
| SSE-KMS + bucket key | Dùng KMS key do module tạo (có rotation), hoặc key bạn truyền vào |
| Public Access Block | Chặn cả 4 tuỳ chọn |
| Ownership controls | `BucketOwnerEnforced` (tắt ACL) |
| Bucket policy | Từ chối mọi request không dùng TLS |
| Lifecycle | Xoá version cũ sau `noncurrent_version_expiration_days` ngày (vẫn giữ `noncurrent_versions_to_keep` bản mới nhất), huỷ multipart upload dở sau 7 ngày |
| Access logging | Tuỳ chọn, bật khi truyền `access_log_bucket` |
| DynamoDB lock table | Tuỳ chọn (`create_dynamodb_table`), chỉ cần khi Terraform < 1.10 |
| IAM managed policy | Quyền đọc/ghi state + dùng KMS, giới hạn theo `access_prefixes`. Gắn policy này vào role của CI hoặc developer |

## Cách dùng

### 1 dự án

```hcl
module "state_backend" {
  source = "git::ssh://git@github.com/Hymeno-Ran/AWS-remote-backend.git?ref=v1.0.0"

  project = "tf-module"
}
```

### Nhiều dự án trong một stack bootstrap

```hcl
module "state_backend" {
  source   = "git::ssh://git@github.com/Hymeno-Ran/AWS-remote-backend.git?ref=v1.0.0"
  for_each = toset(["tf-module", "other-app"])

  project = each.key
}
```

Code chạy được có sẵn trong [examples/single-project](examples/single-project/main.tf) và [examples/multi-project](examples/multi-project/main.tf).

### Policy chỉ cho phép một số prefix

```hcl
module "state_backend" {
  source          = "..."
  project         = "tf-module"
  access_prefixes = ["dev"]   # role gắn policy này chỉ đụng được dev/*
}
```

Nếu cần nhiều mức quyền khác nhau (ví dụ CI prod và dev tách riêng), đặt `create_access_policy = false` rồi tự viết policy dựa trên output `bucket_arn` và `kms_key_arn`.

## Quy trình bootstrap

Stack dùng module này phải có backend trước khi chính nó có chỗ lưu state, nên cần làm theo 2 bước:

1. Apply lần đầu với **local state**:
   ```bash
   terraform init
   terraform apply
   ```
2. Thêm khối `backend "s3"` trỏ vào chính bucket vừa tạo (key gợi ý: `_bootstrap/terraform.tfstate`), rồi migrate state lên:
   ```bash
   terraform init -migrate-state
   ```

Sau bước 2, bạn có thể xoá file `terraform.tfstate` ở máy.

## Dùng backend trong các dự án

Lấy cấu hình có sẵn từ output:

```bash
terraform output -raw backend_config
```

```hcl
bucket       = "tf-module-tfstate-123456789012-us-east-1"
key          = "<KEY>"
region       = "us-east-1"
encrypt      = true
kms_key_id   = "arn:aws:kms:us-east-1:123456789012:key/..."
use_lockfile = true
```

Lưu thành file trong dự án, ví dụ `backends/dev.s3.tfbackend`, rồi thay `<KEY>` bằng đường dẫn state. Trong code dự án chỉ để khung backend:

```hcl
terraform {
  required_version = ">= 1.10.0"   # bắt buộc nếu dùng use_lockfile
  backend "s3" {}
}
```

Init bằng:

```bash
terraform init -backend-config=backends/dev.s3.tfbackend
```

### Quy ước đặt key

```
<env>/<component>/terraform.tfstate
dev/network/terraform.tfstate
prod/eks/terraform.tfstate
```

Mỗi dự án đã có bucket riêng nên key không cần chứa tên dự án. Chỉ cần đảm bảo các component trong cùng một dự án không dùng trùng key.

## Inputs

| Tên | Kiểu | Mặc định | Mô tả |
|---|---|---|---|
| `project` | `string` | — (**bắt buộc**) | Tên dự án: 3–32 ký tự gồm chữ thường, số, `-` |
| `bucket_name` | `string` | `null` | Đặt tên bucket cụ thể thay cho tên mặc định |
| `force_destroy` | `bool` | `false` | Cho phép xoá bucket khi vẫn còn state bên trong |
| `kms_key_arn` | `string` | `null` | Dùng KMS key có sẵn; để `null` thì module tự tạo key |
| `kms_deletion_window_in_days` | `number` | `30` | Thời gian chờ trước khi KMS key bị xoá |
| `noncurrent_version_expiration_days` | `number` | `90` | Số ngày giữ version cũ |
| `noncurrent_versions_to_keep` | `number` | `10` | Số version cũ luôn được giữ lại |
| `access_log_bucket` | `string` | `null` | Bucket nhận access log |
| `create_dynamodb_table` | `bool` | `false` | Tạo bảng lock DynamoDB |
| `create_access_policy` | `bool` | `true` | Tạo IAM policy truy cập state |
| `access_prefixes` | `list(string)` | `[]` | Các prefix policy được truy cập; để rỗng là toàn bucket |
| `tags` | `map(string)` | `{}` | Tag bổ sung |

## Outputs

| Tên | Mô tả |
|---|---|
| `bucket_name` | Tên bucket |
| `bucket_arn` | ARN bucket |
| `kms_key_arn` | ARN KMS key |
| `dynamodb_table_name` | Tên bảng lock (`null` nếu không tạo) |
| `access_policy_arn` | ARN IAM policy (`null` nếu không tạo) |
| `region` | Region của backend |
| `backend_config` | Nội dung `.tfbackend` dùng được ngay (chỉ cần thay `<KEY>`) |

## Yêu cầu

- Module: Terraform `>= 1.5.0`, AWS provider `>= 6.0`
- Dự án dùng `use_lockfile = true`: Terraform `>= 1.10.0`
- Chạy test (`terraform test`): Terraform `>= 1.7.0`

### Điều kiện để build

Danh sách IAM permission đầy đủ và điều kiện riêng của từng resource được ghi ngay trong comment ở [main.tf](main.tf). Tóm tắt:

| Resource | Điều kiện |
|---|---|
| Toàn module | Principal chạy apply có quyền trên KMS, S3, IAM (và DynamoDB nếu bật); SCP của Organizations không chặn các action/region này |
| S3 bucket | Tên **duy nhất trên toàn AWS**, tối đa 63 ký tự. Nếu bị `BucketAlreadyExists` thì đặt `bucket_name` khác |
| KMS alias / IAM policy / DynamoDB table | Tên phải duy nhất. Không gọi module 2 lần cùng `project` trong cùng một region |
| `kms_key_arn` (BYO key) | Symmetric key, **cùng region** với bucket. Key policy phải cho phép các role dùng backend `GenerateDataKey`/`Decrypt` |
| `access_log_bucket` | Phải có sẵn, cùng account và region, dùng SSE-S3 (không hỗ trợ SSE-KMS), và bucket policy cho phép `logging.s3.amazonaws.com` ghi vào |
| DynamoDB table | Bật `deletion_protection`: muốn destroy thì phải tắt nó và apply trước |
| IAM policy | Module chỉ tạo policy, **bạn tự attach** vào role CI/developer. Nếu giới hạn prefix mà có dùng workspace thì thêm `env:` vào `access_prefixes` |

## Test

Test unit dùng mock provider, không cần AWS credentials:

```bash
terraform init -backend=false
terraform test
```

Các test case gồm: tên mặc định, giới hạn prefix, dùng KMS key có sẵn kèm DynamoDB, validate tên project, tên bucket vượt 63 ký tự, prefix sai định dạng.

## Lưu ý

- Bucket không có `prevent_destroy`, vì Terraform không cho đặt giá trị này bằng biến. Thay vào đó, `force_destroy = false` khiến `destroy` thất bại khi bucket còn state, đóng vai trò lớp bảo vệ.
- State chứa thông tin nhạy cảm. Chỉ gắn `access_policy_arn` cho những role thật sự cần.
- Khi pin version, luôn dùng tag (`?ref=v1.0.0`) thay vì branch, để các dự án không bị ảnh hưởng khi module thay đổi.
