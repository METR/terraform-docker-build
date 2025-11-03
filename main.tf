data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_ecr_authorization_token" "token" {}

locals {
  repository_url = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com/${var.ecr_repo}"

  files          = setunion([for pattern in var.source_files : fileset(var.source_path, pattern)]...)
  files_sha      = [for f in local.files : filesha256("${var.source_path}/${f}")]
  dockerfile_sha = filesha256(var.docker_file_path)
  src_sha        = sha256(join("", concat(local.files_sha, [local.dockerfile_sha])))

  image_tag = coalesce(
    var.use_image_tag ? var.image_tag : null,
    var.image_tag_prefix != "" ? "${var.image_tag_prefix}.${local.src_sha}" : null,
    local.src_sha
  )

  image_uri = "${local.repository_url}:${local.image_tag}"

  build_platform = var.platform

  effective_triggers = coalesce(var.triggers, {
    src_sha         = local.src_sha
    build_args_hash = sha256(jsonencode(var.build_args))
  })

  build_args = concat(
    [
      "--platform='${local.build_platform}'",
      "--file='${var.docker_file_path}'",
      "--tag='${local.image_uri}'",
      "--push",
    ],
    [
      for context_name, context_path in var.build_contexts : "--build-context='${context_name}=${context_path}'"
    ],
    [
      for k, v in var.build_args : "--build-arg='${k}=${v}'"
    ],
    var.builder == "" ? [] : ["--builder='${var.builder}'"],
    var.build_target == "" ? [] : ["--target='${var.build_target}'"],
    var.disable_attestations ? ["--provenance=false", "--sbom=false"] : [],
    var.build_command_args,
  )
}

resource "null_resource" "docker_build" {
  triggers = local.effective_triggers
  depends_on = [
    data.aws_ecr_authorization_token.token
  ]

  provisioner "local-exec" {
    command = <<-CMD
      if aws ecr describe-images --repository-name ${var.ecr_repo} \
           --image-ids imageTag=${local.image_tag} \
           --region ${data.aws_region.current.region} >/dev/null 2>&1; then
        echo "Image ${local.image_uri} already in ECR. Skipping build."
      else
        aws ecr get-login-password --region ${data.aws_region.current.region} \
          | docker login --username AWS --password-stdin ${local.repository_url}
        docker buildx build ${join(" ", local.build_args)} ${var.source_path} && echo 'Built and pushed ${local.image_uri}'
      fi
    CMD
  }
}
