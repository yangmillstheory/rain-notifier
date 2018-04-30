# note that SMS topic subscriptions are unsupported in Terraform, so
# those are not included in this module.
#
#   https://www.terraform.io/docs/providers/aws/r/sns_topic_subscription.html
output "topic_arn" {
  value = "${aws_sns_topic.rain_notifier_notify.arn}"
}

output "error_arn" {
  value = "${aws_sns_topic.rain_notifier_error.arn}"
}

resource "aws_sns_topic" "rain_notifier_notify" {
  name         = "rain-notifier-update"
  display_name = "Rain Notifier Update"
}

resource "aws_sns_topic" "rain_notifier_error" {
  name         = "rain-notifier-error"
  display_name = "Rain Notifier Error"
}

data "aws_iam_policy_document" "rain_notifier_notify" {
  statement {
    sid = "1"

    actions = [
      "sns:Publish",
    ]

    resources = [
      "${aws_sns_topic.rain_notifier_notify.arn}",
    ]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "rain_notifier_notify" {
  arn    = "${aws_sns_topic.rain_notifier_notify.arn}"
  policy = "${data.aws_iam_policy_document.rain_notifier_notify.json}"
}

