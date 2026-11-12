# Cost Explorer is a global service: the provider sends these calls to us-east-1 whatever the region of the root.

# One monitor over every AWS service of the consolidated bill: the management account sees the cost of every member.
resource "aws_ce_anomaly_monitor" "services" {
  name              = "svp-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

# A session raises the cost of each service by less than the threshold; an environment left up for a day goes past it
# on EC2 and EKS.
resource "aws_ce_anomaly_subscription" "daily" {
  name             = "svp-daily"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  dynamic "subscriber" {
    for_each = var.budget_emails

    content {
      type    = "EMAIL"
      address = subscriber.value
    }
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = ["10"]
    }
  }
}

# A key can be activated only once it appears in the billing data (aws/bootstrap/README.md).
resource "aws_ce_cost_allocation_tag" "this" {
  for_each = toset(["Project", "Env", "Stack"])

  tag_key = each.value
  status  = "Active"
}
