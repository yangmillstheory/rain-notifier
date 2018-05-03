# rain-notifier

> Get warned before it's going to rain

## Backround

See [this write-up](https://blog.yangmillstheory.com/posts/rain-notifier/).

## Requirements

* [terraform](https://www.terraform.io/)
* [go](https:/golang.org)

## What's inside

* Lambda written in Go, hooked up to a deadletter queue, and a CloudWatch alarm on that queue
* SNS topics to publish to (you need to attach subscriptions in the AWS console)

## Development

Make changes to `main.go`.

```
$ GOOS=linux go build main.go
```

This builds an executable `main` in the root of the repository.

## Deployment

```
$ terraform plan
$ terraform apply
```

You'll be prompted for your Dark Sky API key, and some other values required for the application. You'll
probably have to change some internals, like the remote state paths.

You can customize the latitude and longitude for the location whose weather you want to poll. It defaults
to Sunnyvale, CA :).

## FAQ

> Why isn't this a Terraform module?

I haven't had the time! It's pretty easy to convert it to one (pull requests welcome!).
