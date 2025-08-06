# Terraform Docker Build Module

A Terraform module for building and pushing Docker images to Amazon ECR using Docker Buildx. This module eliminates the need for Docker socket access during Terraform operations, making it ideal for CI/CD pipelines like Spacelift that don't support Docker-in-Docker on their public runners. It serves as a drop-in replacement for `terraform-aws-modules/lambda/aws//modules/docker-build` and provides a socket-free alternative to the [kreuzwerker/docker](https://github.com/kreuzwerker/terraform-provider-docker) provider.

## Features

- Build Docker images using Docker Buildx
- Push images to Amazon ECR
- Support for multi-platform builds (linux/amd64, linux/arm64)
- Content-based image tagging with SHA256 hashing
- Build argument support
- Custom build targets
- Docker Build Cloud support
- Configurable triggers for rebuilds
- Attestation control (provenance, SBOM)

## Usage

### Basic Example

```hcl
module "docker_build" {
  source = "github.com/METR/terraform-docker-build"

  ecr_repo     = "my-app"
  source_path  = "${path.module}/app"
  source_files = ["**/*.py", "requirements.txt", "Dockerfile"]
}
```

### Advanced Example

```hcl
module "docker_build" {
  source = "github.com/METR/terraform-docker-build"

  ecr_repo      = "my-app"
  source_path   = "${path.module}/app"
  source_files  = ["src/**/*", "package.json", "Dockerfile"]
  
  platform         = "linux/arm64"
  build_target     = "production"
  image_tag_prefix = "v1"
  
  build_args = {
    NODE_ENV = "production"
    VERSION  = "1.0.0"
  }
  
  disable_attestations = false
}
```

### Docker Build Cloud Example

First, create your Docker Build Cloud builder:
```bash
docker buildx create --driver=cloud yourorg/yourbuilder --use
```

Then use it in your Terraform configuration:
```hcl
module "docker_build" {
  source = "github.com/METR/terraform-docker-build"

  ecr_repo     = "my-app"
  source_path  = "${path.module}/app"
  source_files = ["**/*"]
  
  builder      = "yourorg/yourbuilder"
  platform     = "linux/amd64,linux/arm64"
}
```

## Migration Guide

### Migrating from terraform-aws-modules/lambda/aws//modules/docker-build

This module serves as a drop-in replacement for the AWS Lambda docker-build module. Update your module source:

```hcl
# Before
module "docker_build" {
  source  = "terraform-aws-modules/lambda/aws//modules/docker-build"
  version = "~> 7.21"
  
  providers = {
    docker = docker
  }
  
  # Your existing configuration
  source_path = "./src"
  # ... other variables
}

# After
module "docker_build" {
  source = "github.com/METR/terraform-docker-build"
  
  # Same configuration, but remove the providers block
  ecr_repo     = "your-repo-name"  # This replaces any ECR setup
  source_path  = "./src"
  source_files = ["**/*"]          # Add this for file tracking
  # ... other compatible variables
}
```

### Migrating from kreuzwerker/docker Provider

If you're currently using the [kreuzwerker/docker](https://github.com/kreuzwerker/terraform-provider-docker) provider with `docker_registry_image` resources, follow these steps:

**Note**: If you're running in an environment without Docker daemon access (like Spacelift's public runners), you'll need to add `disable_docker_daemon_check = true` to your docker provider configuration during the migration process.

1. **Update your configuration** to use this module:
   ```hcl
   # Before (using docker provider)
   terraform {
     required_providers {
       docker = {
         source  = "kreuzwerker/docker"
         version = "~> 3.0"
       }
     }
   }

   provider "docker" {
     registry_auth {
       address  = data.aws_ecr_authorization_token.token.proxy_endpoint
       username = data.aws_ecr_authorization_token.token.user_name
       password = data.aws_ecr_authorization_token.token.password
     }
   }

   resource "docker_image" "this" {
     name = "my-app:latest"
     build {
       context = "./src"
     }
   }

   resource "docker_registry_image" "this" {
     name = docker_image.this.name
     triggers = {
       dir_sha1 = sha1(join("", [for f in fileset("./src", "**") : filesha1("./src/${f}")]))
     }
   }

   # After (using this module)
   module "docker_build" {
     source = "github.com/METR/terraform-docker-build"
     
     ecr_repo     = "my-app"
     source_path  = "./src"
     source_files = ["**/*"]
   }
   ```

2. **Authenticate with ECR** (replace region and account ID with your values):
   ```bash
   aws ecr get-login-password --region us-west-1 | docker login --username AWS --password-stdin YOUR_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com
   ```

3. **Remove existing Docker provider resources from state**:
   ```bash
   # Remove docker_registry_image resources
   terraform state rm 'module.your_module.docker_registry_image.this'
   
   # Untaint any existing null_resource.docker_build resources
   terraform untaint module.your_module.null_resource.docker_build
   ```

   **Note** Without removing these resources from state, Terraform will attempt to recreate the images with the same tags. If your ECR repositories are configured as **immutable**, pushing an image with the same tag will fail. 

4. **Apply the changes**:
   ```bash
   terraform apply
   ```

5. **Remove docker provider** from your configuration once migration is complete.

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.9.1 |
| aws | ~> 5.99 |
| null | ~> 3.2.4 |

## Providers

| Name | Version |
|------|---------|
| aws | ~> 5.99 |
| null | ~> 3.2.4 |

## Prerequisites

1. **Docker**: Docker must be installed and running
2. **AWS CLI**: Configured with appropriate permissions for ECR
3. **ECR Repository**: The target ECR repository must exist
4. **Docker Buildx**: For multi-platform builds (usually included with Docker Desktop)

### Required AWS Permissions

The AWS credentials used must have the following permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "*"
    }
  ]
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| ecr_repo | ECR repository name | `string` | n/a | yes |
| source_path | Path to the source code directory (build context) | `string` | n/a | yes |
| source_files | List of file patterns to track for changes (triggers rebuilds) | `list(string)` | n/a | yes |
| platform | Target platform for the build (e.g., 'linux/amd64', 'linux/arm64') | `string` | `"linux/amd64"` | no |
| builder | Builder name ('default' for local, anything else for Docker Build Cloud) | `string` | `""` | no |
| docker_file_path | Path to Dockerfile | `string` | `"Dockerfile"` | no |
| build_target | Docker build target (--target flag) | `string` | `""` | no |
| build_args | Build arguments to pass to docker build | `map(string)` | `{}` | no |
| image_tag | Specific image tag to use (if not provided, will use content-based SHA) | `string` | `null` | no |
| disable_attestations | Disable attestations | `bool` | `true` | no |

## Outputs

| Name | Description |
|------|-------------|
| repository_url | URL of the ECR repository |
| repository_name | Name of the ECR repository |
| repository_arn | ARN of the ECR repository |
| image_uri | Full URI of the built image |
| image_tag | Tag of the built image |
| source_sha | SHA256 hash of the source files |

## How It Works

1. **Source Tracking**: The module calculates SHA256 hashes of all specified source files and the Dockerfile
2. **Image Tagging**: Images are tagged based on content hash, ensuring consistent rebuilds only when source changes
3. **ECR Authentication**: Automatically handles ECR authentication using AWS provider credentials
4. **Docker Build**: Uses `docker buildx build` with configurable arguments for maximum flexibility
5. **Platform Support**: Supports single and multi-platform builds

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Authors

- **METR** - [https://github.com/METR](https://github.com/METR)
