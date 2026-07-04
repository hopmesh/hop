# The durable per-node mailbox (DESIGN.md §19). The relay writes sealed bundles it
# can't read; a TTL field lets Firestore evict them after delivery/expiry so the
# store self-cleans and scale-to-zero stays cheap.
resource "google_firestore_database" "relay" {
  name        = "(default)"
  location_id = var.firestore_location
  type        = "FIRESTORE_NATIVE"

  # Guard the durable store against an accidental `terraform destroy`.
  deletion_policy = "ABANDON"

  depends_on = [google_project_service.this]
}

# TTL on the bundle collection group: documents expire at their `expireAt` time.
# hop-store-firestore stamps each bundle's expireAt from its bundle expiry.
resource "google_firestore_field" "bundle_ttl" {
  database   = google_firestore_database.relay.name
  collection = "bundles"
  field      = "expireAt"

  ttl_config {}

  # Don't fight Firestore's default index settings on this field.
  index_config {}
}

# F-20: TTL on `presence` (device address → last-seen region + heartbeat) and `registry`. Without
# these, these collections are an INDEFINITELY-retained, queryable per-address→region timeline — the
# dataset DESIGN §33 calls the most sensitive in the system and claims is storage-limited by design.
# The read path already ignores presence older than PRESENCE_TTL_MS, so deleting stale docs cannot
# regress routing. hop-store-firestore must stamp `expireAt` on presence/registry writes for this to
# sweep (see the matching hop-store-firestore F-20 change).
resource "google_firestore_field" "presence_ttl" {
  database   = google_firestore_database.relay.name
  collection = "presence"
  field      = "expireAt"

  ttl_config {}
  index_config {}
}

resource "google_firestore_field" "registry_ttl" {
  database   = google_firestore_database.relay.name
  collection = "registry"
  field      = "expireAt"

  ttl_config {}
  index_config {}
}
