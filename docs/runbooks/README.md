# Operational runbooks

These runbooks capture the operational knowledge needed to run the Hop relay
fleet and its supporting infra, so a second operator can act without reverse
engineering the Terraform.

| Runbook | When you need it |
|---------|------------------|
| [relay-enable-disable.md](relay-enable-disable.md) | Turn the ~42-region relay fleet on or off; understand the Terraform destroy-time cycle that makes teardown fragile. |
| [incident-response.md](incident-response.md) | A relay region is crash-looping, delivery is failing, or the fleet is misbehaving. |
| [quota-and-429.md](quota-and-429.md) | Regions return 429s, wake-churn, or you are tempted to raise `max_instances_per_region` (do not). |

Prerequisites shared by all runbooks:

- `gcloud` authenticated to project `hop-mesh` (`gcloud config set project hop-mesh`).
- OpenTofu `1.12.3` or newer (the version that wrote the GCS state).
- Access to the Terraform state bucket `gs://hop-mesh-tfstate`.
- The deploy path is GitOps: pushing to `main` triggers a Cloud Build run that
  builds both images and runs `tofu apply`. Prefer that over local applies.

Ground truth for what the fleet is doing right now:

```sh
curl -sN https://relay.hopme.sh/     # streaming relay activity log (see privacy note in incident-response)
```
