terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # aws_xray_trace_segment_destination and aws_xray_indexing_rule first shipped in 6.46.0.
      version = "~> 6.46"
    }
  }
}
