# Binary Authorization Policy
resource "google_binary_authorization_policy" "policy" {
  admission_whitelist_patterns {
    name_pattern = "gcr.io/google_containers/*"
  }

  admission_whitelist_patterns {
    name_pattern = "gcr.io/google-containers/*"
  }

  admission_whitelist_patterns {
    name_pattern = "k8s.gcr.io/*"
  }

  admission_whitelist_patterns {
    name_pattern = "gke.gcr.io/*"
  }

  admission_whitelist_patterns {
    name_pattern = "quay.io/argoproj/*"
  }

  admission_whitelist_patterns {
    name_pattern = "docker.io/library/postgres:*"
  }

  admission_whitelist_patterns {
    name_pattern = "docker.io/curlimages/curl:*"
  }

  admission_whitelist_patterns {
    name_pattern = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:*"
  }

  admission_whitelist_patterns {
    name_pattern = "docker.io/openpolicyagent/*"
  }

  admission_whitelist_patterns {
    name_pattern = "openpolicyagent/gatekeeper:*"
  }

  admission_whitelist_patterns {
    name_pattern = "openpolicyagent/gatekeeper-crds:*"
  }

  default_admission_rule {
    evaluation_mode  = var.enable_binary_authorization ? "REQUIRE_ATTESTATION" : "ALWAYS_ALLOW"
    enforcement_mode = "ENFORCED_BLOCK_AND_AUDIT_LOG"
    require_attestations_by = var.enable_binary_authorization ? [
      google_binary_authorization_attestor.cosign_attestor.name
    ] : []
  }

  # Allow system images to run without attestation
  cluster_admission_rules {
    cluster                 = "${var.region}.${google_container_cluster.primary.name}"
    evaluation_mode         = var.enable_binary_authorization ? "REQUIRE_ATTESTATION" : "ALWAYS_ALLOW"
    enforcement_mode        = "ENFORCED_BLOCK_AND_AUDIT_LOG"
    require_attestations_by = var.enable_binary_authorization ? [
      google_binary_authorization_attestor.cosign_attestor.name
    ] : []
  }
}

# Attestor for Cosign signatures
resource "google_binary_authorization_attestor" "cosign_attestor" {
  name = "cosign-attestor"
  attestation_authority_note {
    note_reference = google_container_analysis_note.cosign_note.name
  }
}

# Container Analysis Note for attestations
resource "google_container_analysis_note" "cosign_note" {
  name = "cosign-attestor-note"
  attestation_authority {
    hint {
      human_readable_name = "Cosign keyless signatures from GitHub Actions"
    }
  }
}
