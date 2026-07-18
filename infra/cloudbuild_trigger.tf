# Cloud Build triggers, build and deploy identities, control-plane IAM, and the trusted
# inline build definitions live in infra/bootstrap. They are deliberately absent from
# this automatically applied runtime root. A candidate revision therefore cannot alter
# the active gate or grant itself authority through the runtime apply.
