# terraform-aws-state-backend

Module tái sử dụng để tạo **S3 remote backend** cho Terraform. Mỗi lần gọi module sẽ tạo một backend tách biệt cho một dự án, gồm bucket, KMS key (tuỳ chọn) và IAM policy.

## Tài nguyên tạo ra

| Tài nguyên | Ghi chú |
|---|---|
| S3 bucket | Tên mặc định `<project>-tfstate-<account_id>-<region>` |
| Versioning | Luôn bật, để khôi phục state khi bị hỏng hoặc ghi đè |
| Mã hoá mặc định | Chọn theo `encryption_type`. Xem [Chọn kiểu mã hoá](#chọn-kiểu-mã-hoá) |
| Public Access Block | Chặn cả 4 tuỳ chọn |
| Ownership controls | `BucketOwnerEnforced` (tắt ACL) |
| Bucket policy | Từ chối mọi request không dùng TLS |
| Lifecycle | Xoá version cũ sau `noncurrent_version_expiration_days` ngày (vẫn giữ `noncurrent_versions_to_keep` bản mới nhất), huỷ multipart upload dở sau 7 ngày |
| Access logging | Tuỳ chọn, bật khi truyền `access_log_bucket` |
| DynamoDB lock table | Tuỳ chọn (`create_dynamodb_table`), chỉ cần khi Terraform < 1.10 |
| IAM managed policy | Quyền đọc/ghi state (cộng quyền KMS nếu dùng `customer-kms`), giới hạn theo `access_prefixes`. Gắn policy này vào role của CI hoặc developer |

## Chọn kiểu mã hoá

| `encryption_type` | Mã hoá bằng | KMS key | Phí KMS | Ai đọc được state | Dùng cho |
|---|---|---|---|---|---|
| `customer-kms` (mặc định) | KMS key riêng | Module tự tạo, hoặc truyền `kms_key_arn` | ~1 USD/tháng mỗi key + phí request | Cần **cả** quyền S3 lẫn quyền KMS | prod |
| `aws-kms` | Key AWS managed `aws/s3` | Không tạo | Chỉ phí request (đã giảm nhờ bucket key) | Chỉ cần quyền S3 | staging/UAT |
| `sse-s3` | AES-256 do S3 quản lý | Không tạo | Không | Chỉ cần quyền S3 | SIT/dev |

Cả 3 chế độ **đều mã hoá state khi lưu trữ**. Khác nhau ở chỗ có thêm một lớp kiểm soát truy cập bằng KMS hay không, có CloudTrail log ghi lại ai giải mã hay không, và có thể "huỷ" dữ liệu bằng cách xoá key hay không.

Bảng lock DynamoDB (nếu bật) cũng đổi theo: `customer-kms` dùng KMS key riêng, `aws-kms` dùng `aws/dynamodb`, `sse-s3` dùng key AWS owned (miễn phí).

```hcl
# prod
module "state_backend_prod" {
  source  = "git::ssh://git@github.com/Hymeno-Ran/AWS-remote-backend.git?ref=v1.1.0"
  project = "tf-module-prod"
}

# SIT: không dùng KMS
module "state_backend_sit" {
  source          = "git::ssh://git@github.com/Hymeno-Ran/AWS-remote-backend.git?ref=v1.1.0"
  project         = "tf-module-sit"
  encryption_type = "sse-s3"
}
```

Output `backend_config` tự sinh cấu hình đúng với từng chế độ:
- `customer-kms`: `encrypt = true` kèm `kms_key_id`.
- `aws-kms`: `encrypt = false`. Nếu để `true` mà không có `kms_key_id`, S3 backend sẽ gửi header `AES256` và ghi đè `aws/s3`. Với `false`, bucket tự mã hoá bằng `aws/s3`.
- `sse-s3`: `encrypt = true`.

Khi đổi `encryption_type` trên một backend đã có dữ liệu, chỉ các object ghi **sau đó** mới dùng kiểu mã hoá mới. State hiện tại sẽ được mã hoá lại ở lần `terraform apply` kế tiếp của từng dự án. Các version cũ vẫn giữ kiểu mã hoá cũ cho tới khi hết hạn. Riêng khi chuyển khỏi `customer-kms`: **chưa được xoá KMS key** chừng nào còn version cũ cần đọc.

## Cách dùng

### 1 dự án

```hcl
module "state_backend" {
  source = "git::ssh://git@github.com/Hymeno-Ran/AWS-remote-backend.git?ref=v1.1.0"

  project = "tf-module"
}
```

### Nhiều dự án trong một stack bootstrap

```hcl
module "state_backend" {
  source   = "git::ssh://git@github.com/Hymeno-Ran/AWS-remote-backend.git?ref=v1.1.0"
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
| `encryption_type` | `string` | `"customer-kms"` | `customer-kms`, `aws-kms` hoặc `sse-s3` |
| `kms_key_arn` | `string` | `null` | Chỉ dùng với `customer-kms`: truyền KMS key có sẵn; để `null` thì module tự tạo key |
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
| `encryption_type` | Chế độ mã hoá đang dùng |
| `kms_key_arn` | ARN KMS key riêng (`null` với `aws-kms` / `sse-s3`) |
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
| `kms_key_arn` (BYO key) | Chỉ dùng với `customer-kms`. Symmetric key, **cùng region** với bucket. Key policy phải cho phép các role dùng backend `GenerateDataKey`/`Decrypt` |
| `aws-kms` | Key `aws/s3` không dùng chung được giữa các account, cũng không sửa được key policy. Nếu cần truy cập cross-account thì dùng `customer-kms` |
| `access_log_bucket` | Phải có sẵn, cùng account và region, dùng SSE-S3 (không hỗ trợ SSE-KMS), và bucket policy cho phép `logging.s3.amazonaws.com` ghi vào |
| DynamoDB table | Bật `deletion_protection`: muốn destroy thì phải tắt nó và apply trước |
| IAM policy | Module chỉ tạo policy, **bạn tự attach** vào role CI/developer. Nếu giới hạn prefix mà có dùng workspace thì thêm `env:` vào `access_prefixes` |

## Test

Test unit dùng mock provider, không cần AWS credentials:

```bash
terraform init -backend=false
terraform test
```

Các test case gồm: tên mặc định, giới hạn prefix, dùng KMS key có sẵn kèm DynamoDB, validate tên project, tên bucket vượt 63 ký tự, prefix sai định dạng ([backend.tftest.hcl](tests/backend.tftest.hcl)), và 3 chế độ mã hoá kèm các tổ hợp không hợp lệ ([encryption.tftest.hcl](tests/encryption.tftest.hcl)).

## Lưu ý

- Bucket không có `prevent_destroy`, vì Terraform không cho đặt giá trị này bằng biến. Thay vào đó, `force_destroy = false` khiến `destroy` thất bại khi bucket còn state, đóng vai trò lớp bảo vệ.
- State chứa thông tin nhạy cảm. Chỉ gắn `access_policy_arn` cho những role thật sự cần.
- Khi pin version, luôn dùng tag (`?ref=v1.1.0`) thay vì branch, để các dự án không bị ảnh hưởng khi module thay đổi.
