# n8n AWS Infra Template

A production‑shaped, low‑cost, **n8n on AWS** stack using modern AWS and Terraform best practices:

- [Terraform 1.14.x](https://developer.hashicorp.com/terraform/downloads) + [AWS provider 6.x](https://registry.terraform.io/providers/hashicorp/aws/latest/docs) for IaC.
- Single‑AZ [VPC](https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html), [ALB](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html) + [ACM](https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html) + [Route 53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/Welcome.html), [EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/concepts.html) + [Docker](https://docs.docker.com/).
- [AWS Systems Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/what-is-systems-manager.html):
  - [Parameter Store](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html) for per‑environment config/secrets.
  - [Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) for SSH‑free EC2 access.
  - [Patch Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/patch-manager.html) / [State Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-state.html) for automated patching and drift control.
- [CodePipeline](https://docs.aws.amazon.com/codepipeline/latest/userguide/welcome.html) + [CodeBuild](https://docs.aws.amazon.com/codebuild/latest/userguide/welcome.html) + [CodeDeploy](https://docs.aws.amazon.com/codedeploy/latest/userguide/welcome.html) CI/CD wiring (skeleton).

It is designed as a **template** and a solid starting point for real deployments.

---

## Features

- **Environment‑aware Terraform layout**  
  - `infra/terraform/modules` for reusable components and `infra/terraform/envs/*` for env stacks, matching [AWS/HashiCorp guidance](https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/structure.html).

- **Networking and ingress**
  - Single‑AZ VPC and public subnet.
  - ALB (HTTPS) with an ACM certificate.
  - Route 53 DNS routing:
    - `n8n-test.<domain>` → test ALB.
    - `n8n.<domain>` → prod ALB.  

- **Compute**
  - EC2 instance running Docker and `docker-compose` stack (n8n + Postgres).  
  - No SSH exposure. Administration is handled via AWS SSM Session Manager.

- **Config / secrets (per env)**
  - AWS SSM Parameter Store hierarchy:
    - `/n8n/<env>/app/...`
    - `/n8n/<env>/db/postgres/...`
    - `/n8n/<env>/network/allowed-ips-admin`  
  - App is **env‑agnostic**; config is injected via environment variables at runtime, mirroring [12-Factor App](https://12factor.net/config) methodology.

- **Management & patching**
  - SSM Patch Manager association for regular OS patching.
  - SSM State Manager association to ensure Docker and the n8n stack stay in the desired state.

- **CI/CD (skeleton)**
  - CodeBuild project to build and push Docker images to ECR.  
  - CodeDeploy deployment group targeting the n8n EC2 instance.  
  - CodePipeline wiring Source → Build → Deploy stages.  

---

## Repository structure

```text
n8n-aws-infra-template/
  Makefile
  README.md
  .gitignore
  docker-compose.yml
  docker-compose.local.yml
  docker-compose.aws.yml

  scripts/
    fetch_ssm_env.sh       # Pulls /n8n/<env>/... params into .env.<env>
    deploy.sh              # Used by CodeDeploy to restart docker stack on EC2

  infra/
    terraform/
      modules/
        vpc/
        ec2_n8n/
        alb/
        acm/
        route53/
        ssm_params/
        iam/
        codebuild/
        codedeploy/
        codepipeline/
        ssm_automation/

      envs/
        test/
          backend.tf
          main.tf
          variables.tf
          outputs.tf
        prod/
          backend.tf
          main.tf
          variables.tf
          outputs.tf
```

You extend the modules as your needs grow.

---

## Getting started

### AWS Authentication

Add a login alias to your `~/.zshrc` (or `~/.bashrc`) so credentials and profile are set in one step:

```bash
awslogin() { export AWS_PROFILE=<your-profile>; aws sso login; }
```

Then just run `awslogin` before any AWS work. All `make` and `aws` commands will pick up the profile automatically.

> [!TIP]
> For multiple accounts, create one alias per profile:
> ```bash
> awslogin-dev()  { export AWS_PROFILE=my-dev;  aws sso login; }
> awslogin-prod() { export AWS_PROFILE=my-prod; aws sso login; }
> ```

Or, without an alias:

```bash
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>
```

### Bootstrap

After cloning this template, run `make bootstrap` once per environment. It handles every one-time AWS setup step automatically:

```bash
awslogin
make bootstrap env=test
```

`make bootstrap` will:
1. **Check** that `aws` CLI and `docker` are available and your credentials work.
2. **Create** an S3 bucket + DynamoDB table for Terraform remote state (versioned, encrypted).
3. **Create** an ECR repository for the n8n Docker image (scan-on-push enabled).
4. **Create** all required SSM Parameter Store entries — auto-generates the n8n encryption key and Postgres password for you, prompts only for your domain.
5. **Enable** the S3 backend block in `infra/terraform/envs/<env>/main.tf`.
6. **Write** a complete `terraform.tfvars` for the environment.

> [!IMPORTANT]
> One step cannot be automated via CLI: the **GitHub CodeStar Connection**. The script will pause and give you the direct console link. Takes ~60 seconds to complete in your browser.

After bootstrap, deploy with:

```bash
make tf-init env=test
make tf-plan env=test
make tf-apply env=test ARGS=-auto-approve
```

---

## Prerequisites

Local tools required to run the bootstrap script and Makefile:

- AWS account with:
  - S3 bucket + DynamoDB table for [Terraform remote state and locking](https://developer.hashicorp.com/terraform/language/state/remote).
  - Route 53 hosted zone for your domain.

- Local tools:
  - [Terraform 1.14.x](https://developer.hashicorp.com/terraform/downloads)  
  - [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (v2 required for SSO support)
  - [Docker](https://docs.docker.com/engine/install/) + docker-compose

- IAM permissions to manage VPC, EC2, ALB, ACM, Route 53, SSM, IAM, CodeBuild, CodeDeploy, CodePipeline.

---

## Config: SSM Parameter Store hierarchy

Use AWS SSM Parameter Store per env. 
For each env (`local`, `test`, `prod`), create parameters like:

```text
/n8n/local/N8N_ENCRYPTION_KEY   (SecureString)
/n8n/local/N8N_HOST             (String)   # localhost
/n8n/local/N8N_PROTOCOL         (String)   # http
/n8n/local/N8N_PORT             (String)   # 5678
/n8n/local/POSTGRES_USER        (SecureString)
/n8n/local/POSTGRES_PASSWORD    (SecureString)
/n8n/local/POSTGRES_DB          (String)
```

Repeat the pattern for `test` and `prod` (with appropriate values — `https`, real domain, etc.).
The leaf segment of each path becomes the env var name injected into the container.

---

## Local development

Local dev runs via Docker Compose, but loads config from SSM so it mirrors AWS.
*Note: Terraform commands run inside Docker; credentials come from your configured AWS SSO profile via the `~/.aws` mount.*

1. Log in (see [AWS Authentication](#aws-authentication) above):

```bash
awslogin
```

2. Create `/n8n/local/...` SSM parameters:

```bash
make setup-local
```

This runs SSM setup and starts the stack in one step. Or run them separately:

```bash
make setup-ssm env=local   # just SSM params
make up-local              # just start the stack
```

This runs `scripts/fetch_ssm_env.sh local` to pull config from SSM, then starts `docker compose` with the local overrides.

To tear down:

```bash
make down-local
```

---

## Terraform environments

`make bootstrap env=<env>` handles all setup automatically. To deploy manually or understand what's happening under the hood:

```bash
# 1. Bootstrap once per env (creates state bucket, ECR, SSM params, writes tfvars)
make bootstrap env=test

# 2. Initialize the Terraform workspace
make tf-init env=test

# 3. Review the plan
make tf-plan env=test

# 4. Apply
make tf-apply env=test ARGS=-auto-approve
```

Repeat with `env=prod` when ready. Terraform will create networking, ALB+ACM, Route 53 records, EC2, IAM, SSM, and the full CI/CD pipeline.

To update SSM parameters at any time without re-running the full bootstrap:

```bash
make setup-ssm env=test
```

---

## EC2 access (Session Manager, no SSH)

No SSH port is exposed. Use AWS Systems Manager Session Manager instead.

CLI example:

```bash
aws ssm start-session --target <instance-id>
```

---

## CI/CD (skeleton)

The template includes modules and scripts for:

- **CodeBuild**: Build and push Docker images to ECR (you add the buildspec).  
- **CodeDeploy**: Deployment group for EC2 instance (tagged `role=n8n`), running `scripts/deploy.sh` to restart Docker Compose.  
- **CodePipeline**: Source → Build → Deploy stages wired together (you configure repo, branches, and ECR).  

You provide:
- GitHub/CodeCommit repo details.
- ECR repo name.
- Your `buildspec.yml` and CodeDeploy `appspec.yml` if you want fully automated deployments.

---

## Security and best practices

This template is intentionally opinionated to show strong defaults:

- **No plaintext secrets in repo**: use SSM SecureString.
- **Environment‑specific paths**: `/n8n/<env>/...` per environment.
- **Least privilege IAM**:
  - EC2 role can read only its env’s parameters.
  - SSM/logs permissions are limited to what Session Manager and CloudWatch need.
- **No inbound SSH**: Session Manager only.
- **Automated patching**: SSM Patch Manager keeps OS patched.
- **Modern Terraform**: 1.14.x and AWS provider 6.x pinned.
