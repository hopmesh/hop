# Secret containers, secret IAM, and the relay-seed deny policy are managed in
# infra/bootstrap. The runtime root can reference the secret name but cannot change
# its policy or read a version.
