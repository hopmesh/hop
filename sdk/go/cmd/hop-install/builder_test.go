package main

import "testing"

// The canonical builder moved when hopmesh/monorepo was archived and hopmesh/hop became the source.
// These cases exist because the tempting shape for that migration is an accepted-builder SET, which
// silently keeps the archived repository authorized for every future release. Both directions are
// asserted: a pre-migration tag must still verify against the old builder, and a post-migration tag
// must REFUSE it. A test that only checked the happy direction would pass on the permissive design.
func TestBuilderForPinsEachTagToOneBuilder(t *testing.T) {
	for _, c := range []struct {
		tag        string
		repository string
		builder    string
	}{
		// Published, immutable, signed by the now-archived repository.
		{"v0.0.1", legacyRepository, legacyBuilder},
		{"v0.0.2", legacyRepository, legacyBuilder},
		// Everything from the migration forward.
		{"v0.0.3", canonicalRepository, canonicalBuilder},
		{"v0.1.0", canonicalRepository, canonicalBuilder},
		{"v1.0.0", canonicalRepository, canonicalBuilder},
	} {
		repository, builder := builderFor(c.tag)
		if repository != c.repository || builder != c.builder {
			t.Errorf("builderFor(%q) = (%q, %q), want (%q, %q)",
				c.tag, repository, builder, c.repository, c.builder)
		}
	}
}

// The negative case is the one that matters: the archived repository must not be able to authorize a
// release cut after the migration. If builderFor ever degrades into returning a permissive set, or
// into returning the legacy pair by default, this fails.
func TestBuilderForRefusesArchivedBuilderForNewTags(t *testing.T) {
	for _, tag := range []string{"v0.0.3", "v0.2.0", "v9.9.9"} {
		repository, builder := builderFor(tag)
		if builder == legacyBuilder || repository == legacyRepository {
			t.Errorf("builderFor(%q) accepted the archived builder %q; an archived repository "+
				"cannot run workflows and must never authorize a post-migration release", tag, builder)
		}
	}
}

// A manifest naming the wrong builder for its tag must fail validation, not just differ from a
// constant. This exercises the real call path rather than the lookup in isolation, because the
// defect worth catching is validateManifest reading a fixed constant instead of the tag's builder.
func TestValidateManifestRejectsCrossEraBuilder(t *testing.T) {
	// A post-migration tag whose builder attestation still names the archived repository.
	value := manifest{
		Schema:     manifestSchema,
		Version:    "0.0.3",
		Tag:        "v0.0.3",
		Repository: legacyRepository,
		SourceSHA:  "0123456789abcdef0123456789abcdef01234567",
	}
	value.Builder.Repository = legacyBuilder
	value.Builder.Workflow = canonicalWorkflow
	value.Builder.RunID = 1
	value.Builder.RunAttempt = 1
	value.Builder.Identity = "https://github.com/" + legacyBuilder + "/actions/runs/1"

	if err := validateManifest(value, "v0.0.3", ""); err == nil {
		t.Fatal("validateManifest accepted a v0.0.3 manifest built by the archived repository")
	}
}
