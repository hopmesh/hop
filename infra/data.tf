locals {
  relay_service_account   = "hop-relay@${var.project_id}.iam.gserviceaccount.com"
  example_service_account = "hop-example@${var.project_id}.iam.gserviceaccount.com"
  # The console backend (hop-accountd) and the Next.js front (hop-console) each run as their own
  # dedicated runtime identity, created in infra/bootstrap. The authority guard pins these exact
  # strings, so keep them byte-identical to the bootstrap service-account ids.
  accountd_service_account = "hop-accountd@${var.project_id}.iam.gserviceaccount.com"
  console_service_account  = "hop-console@${var.project_id}.iam.gserviceaccount.com"
}
