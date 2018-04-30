provider "aws" {
  region  = "us-west-2"
  profile = "yangmillstheory"
}

variable "email_to" {
  type = "string"
}

variable "lat" {
  type    = "string"
  default = "37.368832"
}

variable "lng" {
  type    = "string"
  default = "-122.036346"
}

variable "api_key" {
  type = "string"
}

variable "api_url" {
  type    = "string"
  default = "https://api.darksky.net/forecast"
}

# this bucket was created outside of Terraform
terraform {
  backend "s3" {
    profile = "yangmillstheory"
    bucket  = "yangmillstheory-terraform-states"
    region  = "us-west-2"
    key     = "rain-notifier.tfstate"
  }
}

variable "bucket" {
  default = "yangmillstheory-rain-notifier"
}

module "rain_notifier" {
  source           = "./lambda"
  bucket           = "${var.bucket}"
  key              = "rain_notifier.zip"
  email_to         = "${var.email_to}"
  topic_arn        = "${module.sns.topic_arn}"
  alarm_arn        = "${module.sns.error_arn}"
  api_key          = "${var.api_key}"
  api_url          = "${var.api_url}"
  lat              = "${var.lat}"
  lng              = "${var.lng}"
}

module "sns" {
  source = "./sns"
}
