locals {
  # Actual cost at 50, 80 and 100 percent, and forecast cost at 100 percent, as the budget of aws/bootstrap: a session
  # left running is caught by the forecast before the month's actual cost reaches the limit.
  budget_alerts = [
    { type = "ACTUAL", threshold = 50 },
    { type = "ACTUAL", threshold = 80 },
    { type = "ACTUAL", threshold = 100 },
    { type = "FORECASTED", threshold = 100 },
  ]
}

# Cost of this account alone; the budget of the management account covers the whole organization.
resource "aws_budgets_budget" "monthly" {
  name         = "svp-${var.env}-monthly"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = local.budget_alerts

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = var.budget_emails
    }
  }
}
