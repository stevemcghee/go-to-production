resource "google_billing_budget" "monthly_budget" {
  billing_account = var.billing_account_id
  display_name    = "go-to-production Monthly Budget"

  budget_filter {
    projects = ["projects/${var.project_id}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = "600" # ~$20/day * 30 days
    }
  }

  threshold_rules {
    threshold_percent = 0.5 # 50% — informational
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 0.8 # 80% — warning
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 1.0 # 100% — critical
    spend_basis       = "CURRENT_SPEND"
  }
}
