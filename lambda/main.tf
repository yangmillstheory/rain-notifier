variable "bucket" {
  type = "string"
}

variable "key" {
  type = "string"
}

variable "topic_arn" {
  type = "string"
}

variable "alarm_arn" {
  type = "string"
}

variable "email_to" {
  type = "string"
}

variable "lng" {
  type = "string"
}

variable "lat" {
  type = "string"
}

variable "api_key" {
  type = "string"
}

variable "api_url" {
  type = "string"
}

variable "lambda_name" {
  default = "rain-notifier"
}

output "lambda_arn" {
  value = "${aws_lambda_function.rain_notifier.arn}"
}

data "terraform_remote_state" "lambda" {
  backend = "s3"

  config {
    profile = "yangmillstheory"
    bucket  = "yangmillstheory-terraform-states"
    region  = "us-west-2"
    key     = "lambda.tfstate"
  }
}

# S3 bucket for entire application
resource "aws_s3_bucket" "app" {
  bucket = "${var.bucket}"
}

resource "aws_sqs_queue" "rain_notifier_deadletter" {
  name = "rain_notifier_deadletter"
}

resource "aws_sqs_queue_policy" "lambda_to_deadletter" {
  queue_url = "${aws_sqs_queue.rain_notifier_deadletter.id}"

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Id": "sqspolicy",
  "Statement": [
    {
      "Sid": "First",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "sqs:SendMessage",
      "Resource": "${aws_sqs_queue.rain_notifier_deadletter.arn}",
      "Condition": {
        "ArnEquals": {
          "aws:SourceArn": "${aws_sqs_queue.rain_notifier_deadletter.arn}"
        }
      }
    }
  ]
}
POLICY
}

resource "aws_cloudwatch_metric_alarm" "deadletter_queue_alarm" {
  alarm_name          = "rain-notifier failed!"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 120
  statistic           = "Sum"
  threshold           = 0

  dimensions = {
    QueueName = "${aws_sqs_queue.rain_notifier_deadletter.name}"
  }

  alarm_description         = "Triggers when number of messsages is greater than zero."
  alarm_actions             = ["${var.alarm_arn}"]
  ok_actions                = ["${var.alarm_arn}"]
  insufficient_data_actions = ["${var.alarm_arn}"]

  treat_missing_data = "notBreaching"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "main.go"
  output_path = "lambda/lambda.zip"
}

# annoying issue here: https://github.com/hashicorp/terraform/issues/15594
resource "aws_s3_bucket_object" "lambda" {
  bucket = "${var.bucket}"
  key    = "${var.key}"
  source = "${data.archive_file.lambda_zip.output_path}"
  etag   = "${data.archive_file.lambda_zip.output_base64sha256}"

  depends_on = ["aws_s3_bucket.app"]
}

resource "aws_lambda_function" "rain_notifier" {
  function_name     = "${var.lambda_name}"
  s3_bucket         = "${var.bucket}"
  s3_key            = "${var.key}"
  s3_object_version = "${aws_s3_bucket_object.lambda.version_id}"

  dead_letter_config {
    target_arn = "${aws_sqs_queue.rain_notifier_deadletter.arn}"
  }

  environment {
    variables = {
      API_URL = "${var.api_url}"
      API_KEY = "${var.api_key}"

      LAT = "${var.lat}"
      LNG = "${var.lng}"

      TOPIC_ARN = "${var.topic_arn}"
      EMAIL_TO  = "${var.email_to}"
    }
  }

  runtime          = "go1.x"
  role             = "${data.terraform_remote_state.lambda.basic_execution_role_arn}"
  handler          = "main.main"
  source_code_hash = "${data.archive_file.lambda_zip.output_base64sha256}"
  depends_on       = ["aws_s3_bucket.app"]

  timeout = 300
}

# note that I still had to manually enable the trigger. this isn't good.
#
# https://us-west-2.console.aws.amazon.com/lambda/home?region=us-west-2#/functions/rain-notifier?tab=triggers
resource "aws_lambda_permission" "allow_cloudwatch_invoke" {
  statement_id  = "AllowInvokeFromCloudWatch"
  principal     = "events.amazonaws.com"
  action        = "lambda:InvokeFunction"
  function_name = "${var.lambda_name}"
  source_arn    = "${aws_cloudwatch_event_rule.pre_weekday_8pm_pst.arn}"

  depends_on = [
    "aws_lambda_function.rain_notifier"
  ]
}

resource "aws_cloudwatch_event_rule" "pre_weekday_8pm_pst" {
  name                = "pre-weekday-8pm-pst"
  description         = "Every day before a weekday at 8PM PST"
  schedule_expression = "cron(0 2 ? * MON-SAT *)"
}

resource "aws_cloudwatch_event_target" "rain_notifier" {
  rule = "${aws_cloudwatch_event_rule.pre_weekday_8pm_pst.name}"
  arn  = "${aws_lambda_function.rain_notifier.arn}"
}


